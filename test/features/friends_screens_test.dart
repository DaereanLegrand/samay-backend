import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/friend_request_summary.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../support/fake_supabase_http.dart' as support;

const _userId1 = '11111111-1111-1111-1111-111111111111';

/// Records every query the provider is asked to resolve, so tests can assert
/// that keystrokes were debounced into a single search.
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<UserSearchResult>> build(String arg) async {
    queries.add(arg);
    return const [];
  }
}

class _FakeGroupInvitesNotifier extends GroupInvitesNotifier {
  final List<Map<String, dynamic>> data;
  _FakeGroupInvitesNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

/// Counting variant for the group-invites reload assertion (TST-07/M-14).
class _CountingGroupInvitesNotifier extends GroupInvitesNotifier {
  _CountingGroupInvitesNotifier(this.data);

  final List<Map<String, dynamic>> data;
  int builds = 0;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    return data;
  }
}

/// Counts provider rebuilds so tests can assert the screen reloaded after an
/// accept/decline action (the `ref.invalidate` contract, TST-07/M-14).
class _CountingFriendRequestsNotifier extends FriendRequestsNotifier {
  _CountingFriendRequestsNotifier(this.data);

  final FriendRequestsData data;
  int builds = 0;

  @override
  Future<FriendRequestsData> build() async {
    builds++;
    return data;
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  return container;
}

void main() {
  setUpAll(() async {
    // Seeded session + deterministic HTTP layer: the accept/decline buttons
    // reach `SupabaseService.instance.*` (PostgREST calls served hermetically
    // and recorded for assertions, I-45).
    await support.initSupabaseHarness(sessionEmail: 'a@b.com');
  });

  group('RequestsScreen', () {
    testWidgets('accept calls the service (accept_friend_request RPC) and '
        'reloads the provider (TST-07/M-14)', (tester) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(
          requests: [
            FriendRequestSummary(
              type: 'received',
              friendshipId: 'f1',
              userId: _userId1,
            ),
          ],
          names: {_userId1: 'ana'},
        ),
      );
      await _pump(tester, const RequestsScreen(), [
        friendRequestsProvider.overrideWith(() => requests),
        groupInvitesProvider.overrideWith(_FakeGroupInvitesNotifier.new),
      ]);
      await tester.pumpAndSettle();
      expect(requests.builds, 1);

      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();

      expect(
        requests.builds,
        2,
        reason: 'accepting must invalidate (reload) the requests provider',
      );
      expect(
        support.harnessHttp.sentRpc(
          'accept_friend_request',
          '"p_friendship_id":"f1"',
        ),
        isTrue,
        reason:
            'acceptFriendRequest must call the accept_friend_request RPC '
            '(server-side addressee-only consent, migration 20260817000004)',
      );
      // The direct UPDATE seam is gone — acceptance is server-verified.
      expect(
        support.harnessHttp.sent('PATCH', 'id=eq.f1'),
        isFalse,
        reason: 'acceptance no longer patches the friendship row directly',
      );
    });

    testWidgets('decline calls the service (DELETE friendships) and reloads '
        'the provider (TST-07/M-14)', (tester) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(
          requests: [
            FriendRequestSummary(
              type: 'received',
              friendshipId: 'f1',
              userId: _userId1,
            ),
          ],
          names: {_userId1: 'ana'},
        ),
      );
      await _pump(tester, const RequestsScreen(), [
        friendRequestsProvider.overrideWith(() => requests),
        groupInvitesProvider.overrideWith(_FakeGroupInvitesNotifier.new),
      ]);
      await tester.pumpAndSettle();
      expect(requests.builds, 1);

      await tester.tap(find.text('Rechazar'));
      await tester.pumpAndSettle();

      expect(
        requests.builds,
        2,
        reason: 'declining must invalidate (reload) the requests provider',
      );
      expect(
        support.harnessHttp.sent('DELETE', 'id=eq.f1'),
        isTrue,
        reason: 'declineFriendRequest must delete the friendship row',
      );
    });

    testWidgets('group invite accept calls the service (PATCH group_members) '
        'and reloads the invites provider (TST-07/M-14)', (tester) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(requests: [], names: {}),
      );
      final invites = _CountingGroupInvitesNotifier(const [
        {
          'id': 'm1',
          'groups': {'name': 'Disco Crew'},
          'role': 'member',
        },
      ]);
      await _pump(tester, const RequestsScreen(), [
        friendRequestsProvider.overrideWith(() => requests),
        groupInvitesProvider.overrideWith(() => invites),
      ]);
      await tester.pumpAndSettle();
      expect(invites.builds, 1);

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();

      expect(
        invites.builds,
        2,
        reason: 'accepting an invite must invalidate (reload) the provider',
      );
      expect(
        support.harnessHttp.sent('PATCH', 'id=eq.m1'),
        isTrue,
        reason: 'acceptGroupInvite must activate the membership row',
      );
    });
  });

  group('SearchScreen', () {
    testWidgets('debounces rapid keystrokes into a single provider query', (
      tester,
    ) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(tester, const SearchScreen(), [
        searchResultsProvider.overrideWith(() => recording),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, [
        'analia',
      ], reason: 'intermediate keystrokes must not fire a query');
    });
  });
}
