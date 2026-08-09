import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/friends/friends_providers.dart';
import 'package:samay/features/groups/create_group_screen.dart';
import 'package:samay/features/groups/group_detail_screen.dart';
import 'package:samay/features/groups/group_members_screen.dart';
import 'package:samay/features/groups/groups_providers.dart';
import 'package:samay/features/groups/donate_shards_screen.dart';
import 'package:samay/features/groups/invite_screen.dart';
import 'package:samay/features/groups/leaderboard_screen.dart';
import 'package:samay/features/groups/my_groups_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';

const _groupId = '33333333-3333-3333-3333-333333333333';
const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

Map<String, dynamic> _group(String id, String name, {String? myRole}) => {
      'id': id,
      'name': name,
      'group_shards': 100,
      'rank_bracket': 'b0_20',
      'my_role': myRole,
    };

class _FakeMyGroupsNotifier extends MyGroupsNotifier {
  final List<Map<String, dynamic>> data;
  final Object? error;
  _FakeMyGroupsNotifier({this.data = const [], this.error});

  @override
  Future<List<Map<String, dynamic>>> build() async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeGroupDetailNotifier extends GroupDetailNotifier {
  final Map<String, dynamic>? data;
  final Object? error;
  _FakeGroupDetailNotifier({this.data, this.error});

  @override
  Future<Map<String, dynamic>?> build(String arg) async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeGroupMembersNotifier extends GroupMembersNotifier {
  final List<Map<String, dynamic>> data;
  _FakeGroupMembersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _FakeContributionsNotifier extends GroupContributionsNotifier {
  final GroupContributionsData data;
  _FakeContributionsNotifier({this.data = const GroupContributionsData(contributors: [], myContribution: 0)});

  @override
  Future<GroupContributionsData> build(String arg) async => data;
}

class _FakeLeaderboardNotifier extends LeaderboardNotifier {
  final List<Map<String, dynamic>> data;
  final Object? error;
  _FakeLeaderboardNotifier({this.data = const [], this.error});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _FakeSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

/// Records every query the provider is asked to resolve, so tests can assert
/// that keystrokes were debounced into a single search (finding PERF-05).
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    queries.add(arg);
    return const [];
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
  group('CreateGroupScreen', () {
    testWidgets('renders create group form', (tester) async {
      await _pump(tester, const CreateGroupScreen(), []);
      expect(find.text('Crear grupo'), findsOneWidget);
      expect(find.text('Nombre del grupo'), findsOneWidget);
      expect(find.text('Descripción (opcional)'), findsOneWidget);
      expect(find.text('Crear'), findsOneWidget);
    });
  });

  group('MyGroupsScreen', () {
    testWidgets('shows empty state when the provider returns no groups',
        (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [myGroupsProvider.overrideWith(_FakeMyGroupsNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('No perteneces a ningún grupo'), findsOneWidget);
      expect(find.text('Crea un grupo o únete a uno existente'), findsOneWidget);
    });

    testWidgets('renders group rows from the provider', (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [
          myGroupsProvider.overrideWith(
            () => _FakeMyGroupsNotifier(
              data: [
                _group(_groupId, 'Disco Crew', myRole: 'promotor'),
                _group('44444444-4444-4444-4444-444444444444', 'Vinyl Lovers',
                    myRole: 'member'),
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Vinyl Lovers'), findsOneWidget);
      expect(find.text('PROMOTOR · '), findsOneWidget);
    });

    testWidgets('renders ErrorView with retry when the provider fails',
        (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [
          myGroupsProvider.overrideWith(
            () => _FakeMyGroupsNotifier(error: Exception('grupos caídos')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('GroupDetailScreen', () {
    testWidgets('renders group header and tabs when data is loaded',
        (tester) async {
      await _pump(
        tester,
        const GroupDetailScreen(groupId: _groupId),
        [
          groupDetailProvider.overrideWith(
            () => _FakeGroupDetailNotifier(
              data: {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
            ),
          ),
          groupMembersProvider.overrideWith(
            () => _FakeGroupMembersNotifier(
              data: [
                {'user_id': _userId1, 'role': 'promotor', 'users': {'username': 'ana'}},
                {'user_id': _userId2, 'role': 'member', 'users': {'username': 'lucas'}},
              ],
            ),
          ),
          contributionsProvider.overrideWith(
            () => _FakeContributionsNotifier(
              data: GroupContributionsData(
                contributors: [
                  {'user_id': _userId1, 'shards_contributed': 50, 'users': {'username': 'ana'}},
                ],
                myContribution: 30,
              ),
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Miembros'), findsOneWidget);
      expect(find.text('Eventos'), findsOneWidget);
      expect(find.textContaining('2 / 14 miembros'), findsOneWidget);
      expect(find.textContaining('Mi contribuci\u00f3n: 30'), findsOneWidget);
    });

    testWidgets('renders ErrorView when the group provider fails',
        (tester) async {
      await _pump(
        tester,
        const GroupDetailScreen(groupId: _groupId),
        [
          groupDetailProvider.overrideWith(
            () => _FakeGroupDetailNotifier(error: Exception('grupo perdido')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('DonateShardsScreen', () {
    testWidgets('renders donation form', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.text('Donar shards'), findsOneWidget);
      expect(find.textContaining('Test Group'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows boost info text', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.textContaining('impulsarán el ranking'), findsOneWidget);
    });

    testWidgets('shows donation button', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.text('Donar'), findsOneWidget);
    });
  });

  group('InviteScreen', () {
    testWidgets('renders search bar and hint text', (tester) async {
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
          searchResultsProvider.overrideWith(_FakeSearchResultsNotifier.new),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Buscar usuarios'), findsOneWidget);
      expect(find.textContaining('Escribe al menos 2 caracteres'), findsOneWidget);
    });

    testWidgets('excludes existing members from search results', (tester) async {
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(
            () => _FakeGroupMembersNotifier(
              data: [
                {'user_id': _userId1, 'role': 'member'},
              ],
            ),
          ),
          searchResultsProvider.overrideWith(
            () => _FakeSearchResultsNotifier(
              data: [
                {'id': _userId1, 'username': 'ana', 'avatar_url': null},
                {'id': _userId2, 'username': 'lucas', 'avatar_url': null},
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pumpAndSettle();
      expect(find.text('@lucas'), findsOneWidget);
      expect(find.text('@ana'), findsNothing);
    });

    testWidgets('debounces rapid keystrokes into a single query after 300ms',
        (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
          searchResultsProvider.overrideWith(() => recording),
        ],
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'l');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, ['lu'],
          reason: 'intermediate keystrokes must not fire a query');
    });
  });

  group('GroupMembersScreen', () {
    testWidgets('renders loading state first', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No hay miembros'), findsNothing);
    });

    testWidgets('renders empty state when no members', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      await tester.pumpAndSettle();
      expect(find.text('No hay miembros'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders screen with members title', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      await tester.pumpAndSettle();
      expect(find.text('Miembros'), findsOneWidget);
    });
  });

  group('LeaderboardScreen', () {
    testWidgets('renders leaderboard title and size tier chips', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [leaderboardProvider.overrideWith(_FakeLeaderboardNotifier.new)],
      );
      expect(find.text('Ranking de grupos'), findsOneWidget);
      expect(find.text('micro'), findsOneWidget);
      expect(find.text('small'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.text('large'), findsOneWidget);
    });

    testWidgets('renders rankings from the provider', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [
          leaderboardProvider.overrideWith(
            () => _FakeLeaderboardNotifier(
              data: [
                {
                  ..._group('44444444-4444-4444-4444-444444444444', 'Disco Crew'),
                  'rank_position': 1,
                  'score': 500,
                  'member_count': 12,
                },
                {
                  ..._group('55555555-5555-5555-5555-555555555555', 'Vinyl Lovers'),
                  'rank_position': 2,
                  'score': 300,
                  'member_count': 8,
                },
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Vinyl Lovers'), findsOneWidget);
      expect(find.textContaining('12 miembros'), findsOneWidget);
      expect(find.textContaining('500 shards'), findsOneWidget);
    });

    testWidgets('shows empty ranking state', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [leaderboardProvider.overrideWith(_FakeLeaderboardNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin datos de ranking'), findsOneWidget);
    });

    testWidgets('renders ErrorView when the provider fails', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [
          leaderboardProvider.overrideWith(
            () => _FakeLeaderboardNotifier(error: Exception('ranking caído')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });
}
