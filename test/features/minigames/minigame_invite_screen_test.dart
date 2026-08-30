import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/core/utils/input_sanitizer.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/providers/recent_friends_provider.dart';
import 'package:samay/features/minigames/screens/minigame_invite_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

const _friendA = '11111111-1111-1111-1111-111111111111';
const _friendB = '22222222-2222-2222-2222-222222222222';
const _stranger = '33333333-3333-3333-3333-333333333333';

/// Records every query the shared search provider is asked to resolve, so the
/// widget tests can assert that sub-5-char queries NEVER reach the backend
/// (the `search_users` RPC rejects them with `invalid_query_length`).
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];
  final List<UserSearchResult> data;

  _RecordingSearchResultsNotifier(this.data);

  @override
  Future<List<UserSearchResult>> build(String arg) async {
    queries.add(arg);
    return data;
  }
}

/// Stubbed recent-friends list. Since [recentFriendsProvider] is derived from
/// `friendsListProvider` + `chatInboxProvider` + `myMinigameSessionsProvider`,
/// this override replaces the whole derivation with a fixed ordering so the
/// widget tests focus on picker behavior, not recency scoring (the scoring
/// itself is covered by `recent_friends_provider_test.dart`).
class _FakeRecentFriendsNotifier extends RecentFriendsNotifier {
  final List<UserSearchResult> friends;

  _FakeRecentFriendsNotifier(this.friends);

  @override
  Future<List<UserSearchResult>> build() async => friends;
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<UserSearchResult> friends, {
  _RecordingSearchResultsNotifier? search,
}) async {
  final container = ProviderContainer(
    overrides: [
      recentFriendsProvider.overrideWith(
        () => _FakeRecentFriendsNotifier(friends),
      ),
      if (search != null) searchResultsProvider.overrideWith(() => search),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MinigameInviteScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('InputSanitizer.searchQueryMinLength', () {
    test('is 5, mirroring the search_users RPC guard (SR002)', () {
      expect(InputSanitizer.searchQueryMinLength, 5);
    });
  });

  group('MinigameInviteScreen picker', () {
    testWidgets('query 0: shows friends immediately, no backend call', (
      tester,
    ) async {
      final search = _RecordingSearchResultsNotifier(const []);
      final friends = [
        const UserSearchResult(id: _friendA, username: 'ana'),
        const UserSearchResult(id: _friendB, username: 'lucas'),
      ];
      await _pump(tester, friends, search: search);

      expect(find.text('@ana'), findsOneWidget);
      expect(find.text('@lucas'), findsOneWidget);
      expect(search.queries, isEmpty);
    });

    testWidgets('query 0-4: friends are filtered by the partial query, no '
        'backend call', (tester) async {
      final search = _RecordingSearchResultsNotifier(const []);
      final friends = [
        const UserSearchResult(id: _friendA, username: 'analia'),
        const UserSearchResult(id: _friendB, username: 'lucas'),
      ];
      await _pump(tester, friends, search: search);

      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('@analia'), findsOneWidget);
      expect(find.text('@lucas'), findsNothing,
          reason: 'a 2-char query must filter the on-device friends');
      expect(search.queries, isEmpty,
          reason: 'sub-5-char queries must never reach the backend');
    });

    testWidgets('query >= 5: backend results merged with friends, friends '
        'first, no duplicates', (tester) async {
      final search = _RecordingSearchResultsNotifier(const [
        UserSearchResult(id: _friendA, username: 'analia'),
        UserSearchResult(id: _stranger, username: 'andres'),
      ]);
      final friends = [
        const UserSearchResult(id: _friendB, username: 'beta'),
        const UserSearchResult(id: _friendA, username: 'analia'),
      ];
      await _pump(tester, friends, search: search);

      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(search.queries, ['analia']);
      expect(find.text('@analia'), findsOneWidget,
          reason: 'a friend returned by the backend must not be duplicated');
      expect(find.text('@andres'), findsOneWidget);

      final friendsOnTop = tester.getTopLeft(find.text('@analia'));
      final strangersBelow = tester.getTopLeft(find.text('@andres'));
      expect(friendsOnTop.dy < strangersBelow.dy, isTrue,
          reason: 'friends sort above non-friend backend results');
    });

    testWidgets('a sub-5-char query that matches no friend renders the '
        'no-results empty state, not an error', (tester) async {
      final search = _RecordingSearchResultsNotifier(const []);
      final friends = [
        const UserSearchResult(id: _friendA, username: 'analia'),
      ];
      await _pump(tester, friends, search: search);

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('@analia'), findsNothing);
      expect(search.queries, isEmpty);
    });

    testWidgets('selection + confirm pops the selected user ids', (
      tester,
    ) async {
      final search = _RecordingSearchResultsNotifier(const []);
      final friends = [
        const UserSearchResult(id: _friendA, username: 'ana'),
        const UserSearchResult(id: _friendB, username: 'lucas'),
      ];
      final container = ProviderContainer(
        overrides: [
          recentFriendsProvider.overrideWith(
            () => _FakeRecentFriendsNotifier(friends),
          ),
          searchResultsProvider.overrideWith(() => search),
        ],
      );
      addTearDown(container.dispose);

      List<String>? popped;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      popped = await Navigator.of(context).push<List<String>>(
                        MaterialPageRoute(
                          builder: (_) => const MinigameInviteScreen(),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('@ana'), findsOneWidget);

      await tester.tap(find.text('@ana'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@lucas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invitar (2)'));
      await tester.pumpAndSettle();

      expect(popped, [ _friendA, _friendB ]);
    });
  });
}
