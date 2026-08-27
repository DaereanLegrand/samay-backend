import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/widgets/user_picker_view.dart';
import 'package:samay/l10n/app_localizations.dart';

/// UserPickerView tests (2026-08-26): the reusable user multi-select picker
/// reuses the `searchResultsProvider` plumbing; the friends-first sort and
/// the excluded-ids filter are the two minigame-invite rules.
class _StubSearchResultsNotifier extends SearchResultsNotifier {
  _StubSearchResultsNotifier(this.data);

  final List<UserSearchResult> data;

  @override
  Future<List<UserSearchResult>> build(String arg) async => data;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<UserSearchResult> users,
  Set<String> excludedIds = const {},
  bool sortFriendsFirst = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      searchResultsProvider.overrideWith(
        () => _StubSearchResultsNotifier(users),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: UserPickerView(
            excludedIds: excludedIds,
            sortFriendsFirst: sortFriendsFirst,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('UserPickerView', () {
    testWidgets('short queries show the min-chars hint', (tester) async {
      await _pump(tester, users: const []);

      expect(find.text('Escribe al menos 2 caracteres para buscar'), findsOneWidget);
    });

    testWidgets('sorts accepted friends first (prioritize friends)',
        (tester) async {
      await _pump(
        tester,
        users: const [
          UserSearchResult(
            id: 'aaaa',
            username: 'stranger',
            friendshipStatus: null,
          ),
          UserSearchResult(
            id: 'bbbb',
            username: 'friend',
            friendshipStatus: 'accepted',
          ),
        ],
      );

      // Both rows render after a qualifying query is entered.
      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      final friend = tester.getTopLeft(find.text('@friend'));
      final stranger = tester.getTopLeft(find.text('@stranger'));
      expect(friend.dy, lessThan(stranger.dy));
    });

    testWidgets('excluded ids never render', (tester) async {
      await _pump(
        tester,
        users: const [
          UserSearchResult(id: 'aaaa', username: 'zoe'),
          UserSearchResult(id: 'bbbb', username: 'ana'),
        ],
        excludedIds: const {'aaaa'},
      );

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('@zoe'), findsNothing);
      expect(find.text('@ana'), findsOneWidget);
    });

    testWidgets('toggling a row reports the selection', (tester) async {
      final selection = <Set<String>>[];
      final container = ProviderContainer(
        overrides: [
          searchResultsProvider.overrideWith(
            () => _StubSearchResultsNotifier(const [
              UserSearchResult(id: 'aaaa', username: 'zoe'),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UserPickerView(
                onSelectionChanged: selection.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('@zoe'));
      await tester.pumpAndSettle();
      expect(selection.last, {'aaaa'});

      await tester.tap(find.text('@zoe'));
      await tester.pumpAndSettle();
      expect(selection.last, isEmpty);
    });
  });
}