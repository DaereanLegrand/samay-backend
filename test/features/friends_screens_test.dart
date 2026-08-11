import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/friends/screens/blocked_users_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';

import '../support/fake_supabase_http.dart' as support;

const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

Map<String, dynamic> _user(String id, String username) =>
    {'id': id, 'username': username, 'avatar_url': null};

class _FakeFriendsListNotifier extends FriendsListNotifier {
  final List<Map<String, dynamic>> data;
  final Object? error;
  _FakeFriendsListNotifier({this.data = const [], this.error});

  @override
  Future<List<Map<String, dynamic>>> build() async {
    if (error != null) throw error!;
    return data;
  }
}

class _PendingFriendsListNotifier extends FriendsListNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    return Completer<List<Map<String, dynamic>>>().future;
  }
}

class _FakeFriendRequestsNotifier extends FriendRequestsNotifier {
  final FriendRequestsData data;
  _FakeFriendRequestsNotifier({this.data = const FriendRequestsData(requests: [], names: {})});

  @override
  Future<FriendRequestsData> build() async => data;
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

class _FakeBlockedUsersNotifier extends BlockedUsersNotifier {
  final List<Map<String, dynamic>> data;
  _FakeBlockedUsersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

class _FakeSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _FakeSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

/// Search provider pinned to a failure — the error-state rendering under test.
class _ErrorSearchResultsNotifier extends SearchResultsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    throw Exception('search down');
  }
}

/// Records every query the provider is asked to resolve, so tests can assert
/// that keystrokes were debounced into a single search.
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    queries.add(arg);
    return const [];
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

  group('FriendsListScreen', () {
    testWidgets('shows loading spinner while the provider is pending',
        (tester) async {
      await _pump(
        tester,
        const FriendsListScreen(),
        [friendsListProvider.overrideWith(_PendingFriendsListNotifier.new)],
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows empty state when the provider returns no friends',
        (tester) async {
      await _pump(
        tester,
        const FriendsListScreen(),
        [friendsListProvider.overrideWith(_FakeFriendsListNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin amigos aún'), findsOneWidget);
      expect(find.text('Busca usuarios para agregar amigos'), findsOneWidget);
    });

    testWidgets('renders friend rows from the provider', (tester) async {
      await _pump(
        tester,
        const FriendsListScreen(),
        [
          friendsListProvider.overrideWith(
            () => _FakeFriendsListNotifier(
              data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('@ana'), findsNWidgets(2));
      expect(find.text('@lucas'), findsNWidgets(2));
      expect(find.text('Sin amigos aún'), findsNothing);
    });

    testWidgets('renders ErrorView with retry when the provider fails',
        (tester) async {
      await _pump(
        tester,
        const FriendsListScreen(),
        [
          friendsListProvider.overrideWith(
            () => _FakeFriendsListNotifier(error: Exception('boom')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('RequestsScreen', () {
    testWidgets('renders received, sent and invites tabs from providers',
        (tester) async {
      await _pump(
        tester,
        const RequestsScreen(),
        [
          friendRequestsProvider.overrideWith(
            () => _FakeFriendRequestsNotifier(
              data: const FriendRequestsData(
                requests: [
                  {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
                  {'type': 'sent', 'friendship_id': 'f2', 'user_id': _userId2},
                ],
                names: {_userId1: 'ana', _userId2: 'lucas'},
              ),
            ),
          ),
          groupInvitesProvider.overrideWith(
            () => _FakeGroupInvitesNotifier(
              data: [
                {'id': 'm1', 'groups': {'name': 'Disco Crew'}, 'role': 'member'},
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Recibidas'), findsOneWidget);
      expect(find.text('Enviadas'), findsOneWidget);
      expect(find.text('Invitaciones'), findsOneWidget);
      expect(find.text('ana'), findsOneWidget);
      expect(find.text('Aceptar'), findsWidgets);

      await tester.tap(find.text('Enviadas'));
      await tester.pumpAndSettle();
      expect(find.text('lucas'), findsOneWidget);
      expect(find.text('Solicitud enviada'), findsOneWidget);
    });

    testWidgets('shows empty states when there is nothing to show',
        (tester) async {
      await _pump(
        tester,
        const RequestsScreen(),
        [
          friendRequestsProvider.overrideWith(_FakeFriendRequestsNotifier.new),
          groupInvitesProvider.overrideWith(_FakeGroupInvitesNotifier.new),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin solicitudes recibidas'), findsOneWidget);

      await tester.tap(find.text('Enviadas'));
      await tester.pumpAndSettle();
      expect(find.text('Sin solicitudes enviadas'), findsOneWidget);

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      expect(find.text('Sin invitaciones'), findsOneWidget);
    });

    testWidgets('accept calls the service (PATCH friendships) and reloads the '
        'provider (TST-07/M-14)', (tester) async {
      final requests = _CountingFriendRequestsNotifier(const FriendRequestsData(
        requests: [
          {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
        ],
        names: {_userId1: 'ana'},
      ));
      await _pump(
        tester,
        const RequestsScreen(),
        [
          friendRequestsProvider.overrideWith(() => requests),
          groupInvitesProvider.overrideWith(_FakeGroupInvitesNotifier.new),
        ],
      );
      await tester.pumpAndSettle();
      expect(requests.builds, 1);

      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();

      expect(requests.builds, 2,
          reason: 'accepting must invalidate (reload) the requests provider');
      expect(
        support.harnessHttp.sent('PATCH', 'id=eq.f1'),
        isTrue,
        reason: 'acceptFriendRequest must update the friendship row',
      );
    });

    testWidgets('decline calls the service (DELETE friendships) and reloads '
        'the provider (TST-07/M-14)', (tester) async {
      final requests = _CountingFriendRequestsNotifier(const FriendRequestsData(
        requests: [
          {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
        ],
        names: {_userId1: 'ana'},
      ));
      await _pump(
        tester,
        const RequestsScreen(),
        [
          friendRequestsProvider.overrideWith(() => requests),
          groupInvitesProvider.overrideWith(_FakeGroupInvitesNotifier.new),
        ],
      );
      await tester.pumpAndSettle();
      expect(requests.builds, 1);

      await tester.tap(find.text('Rechazar'));
      await tester.pumpAndSettle();

      expect(requests.builds, 2,
          reason: 'declining must invalidate (reload) the requests provider');
      expect(
        support.harnessHttp.sent('DELETE', 'id=eq.f1'),
        isTrue,
        reason: 'declineFriendRequest must delete the friendship row',
      );
    });

    testWidgets('group invite accept calls the service (PATCH group_members) '
        'and reloads the invites provider (TST-07/M-14)', (tester) async {
      final requests =
          _CountingFriendRequestsNotifier(const FriendRequestsData(requests: [], names: {}));
      final invites = _CountingGroupInvitesNotifier(const [
        {'id': 'm1', 'groups': {'name': 'Disco Crew'}, 'role': 'member'},
      ]);
      await _pump(
        tester,
        const RequestsScreen(),
        [
          friendRequestsProvider.overrideWith(() => requests),
          groupInvitesProvider.overrideWith(() => invites),
        ],
      );
      await tester.pumpAndSettle();
      expect(invites.builds, 1);

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();

      expect(invites.builds, 2,
          reason: 'accepting an invite must invalidate (reload) the provider');
      expect(
        support.harnessHttp.sent('PATCH', 'id=eq.m1'),
        isTrue,
        reason: 'acceptGroupInvite must activate the membership row',
      );
    });
  });

  group('BlockedUsersScreen', () {
    testWidgets('shows empty state when no users are blocked', (tester) async {
      await _pump(
        tester,
        const BlockedUsersScreen(),
        [blockedUsersProvider.overrideWith(_FakeBlockedUsersNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);
    });

    testWidgets('renders blocked users with unblock button', (tester) async {
      await _pump(
        tester,
        const BlockedUsersScreen(),
        [
          blockedUsersProvider.overrideWith(
            () => _FakeBlockedUsersNotifier(data: [_user(_userId1, 'ana')]),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('@ana'), findsNWidgets(2));
      expect(find.text('Desbloquear'), findsOneWidget);
    });
  });

  group('SearchScreen', () {
    testWidgets('shows hint until the user types a query', (tester) async {
      await _pump(
        tester,
        const SearchScreen(),
        [searchResultsProvider.overrideWith(_FakeSearchResultsNotifier.new)],
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('No se encontraron usuarios'), findsNothing);
    });

    testWidgets('renders search results from the provider after debounce',
        (tester) async {
      await _pump(
        tester,
        const SearchScreen(),
        [
          searchResultsProvider.overrideWith(
            () => _FakeSearchResultsNotifier(
              data: [
                _user(_userId1, 'ana'),
                {
                  ..._user(_userId2, 'lucas'),
                  'friendship_status': 'pending',
                },
              ],
            ),
          ),
        ],
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('@ana'), findsOneWidget);
      expect(find.text('@lucas'), findsOneWidget);
      expect(find.text('Solicitado'), findsOneWidget);
      expect(find.text('Agregar'), findsOneWidget);
    });

    testWidgets('debounces rapid keystrokes into a single provider query',
        (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(
        tester,
        const SearchScreen(),
        [searchResultsProvider.overrideWith(() => recording)],
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, ['an'],
          reason: 'intermediate keystrokes must not fire a query');
    });

    testWidgets('renders ErrorView with retry when the search provider fails '
        '(TST-07/M-14)', (tester) async {
      await _pump(
        tester,
        const SearchScreen(),
        [searchResultsProvider.overrideWith(_ErrorSearchResultsNotifier.new)],
      );
      await tester.enterText(find.byType(TextField), 'ana');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('No se encontraron usuarios'), findsNothing);
    });
  });
}
