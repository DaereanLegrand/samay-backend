import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/screens/group_members_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/core/theme/app_theme.dart';

import '../../support/fake_supabase_http.dart' as support;

/// U-16 groups FLOW ledger tests (R16-R17, 2026-08-11).
///
/// Pins the Juega-flow-alignment changes from U-13 §5.3 (the ledger in
/// `docs/development/phase-04-ui/2026-08-11_U16-friends-groups-flow.md`):
/// the inline leave-group row (R16) and the admin member-actions sheet
/// (R17). R11-R15 (friends) live in `test/features/friends/flow_test.dart`.

const _groupId = '33333333-3333-3333-3333-333333333333';
const _myUserId = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';
const _userId3 = '44444444-4444-4444-4444-444444444444';

class _MockGroupsRepository extends Mock implements GroupsRepository {}

class _StubGroupDetailNotifier extends GroupDetailNotifier {
  final Map<String, dynamic>? data;
  _StubGroupDetailNotifier({this.data});

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
}

class _StubGroupMembersNotifier extends GroupMembersNotifier {
  final List<Map<String, dynamic>> data;
  _StubGroupMembersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _StubContributionsNotifier extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      const GroupContributionsData(contributors: [], myContribution: 0);
}

class _GroupDetailHarness {
  _GroupDetailHarness(this.container, this.router);

  final ProviderContainer container;
  final GoRouter router;
}

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SamayTheme.dark,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// Pumps GroupDetailScreen as a pushed route over a `/home` parent, so the
/// leave-group pop can be asserted against the real router stack.
Future<_GroupDetailHarness> _pumpGroupDetail(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('home-marker')),
      ),
      GoRoute(
        path: '/group/:groupId',
        builder: (_, state) =>
            GroupDetailScreen(groupId: state.pathParameters['groupId']!),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  router.push(RoutePaths.groupDetail(_groupId));
  await tester.pumpAndSettle();
  return _GroupDetailHarness(container, router);
}

List<Override> _loadedGroupDetailOverrides({
  Map<String, dynamic>? group,
  List<Map<String, dynamic>> members = const [],
}) => [
  groupDetailProvider.overrideWith(
    () => _StubGroupDetailNotifier(
      data:
          group ?? {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
    ),
  ),
  groupMembersProvider.overrideWith(
    () => _StubGroupMembersNotifier(data: members),
  ),
  contributionsProvider.overrideWith(_StubContributionsNotifier.new),
];

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('R16 — inline leave-group row', () {
    testWidgets('the leave action is an inline row beside the member count '
        'and the overflow menu is gone when not frozen', (tester) async {
      await _pumpGroupDetail(tester, _loadedGroupDetailOverrides());

      expect(
        find.text('Abandonar grupo'),
        findsOneWidget,
        reason: 'the leave trigger lives inline in the header (R16)',
      );
      expect(
        find.byType(PopupMenuButton<String>),
        findsNothing,
        reason: 'no overflow menu when the group is not frozen (R16)',
      );
    });

    testWidgets('leave flow: inline row → confirm dialog → leaveGroup call → '
        'pops back (repointed from the menu)', (tester) async {
      await _pumpGroupDetail(tester, _loadedGroupDetailOverrides());

      await tester.tap(find.text('Abandonar grupo'));
      await tester.pumpAndSettle();
      expect(find.text('¿Estás seguro?'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(
        find.byType(GroupDetailScreen),
        findsOneWidget,
        reason: 'cancelling keeps the screen',
      );

      await tester.tap(find.text('Abandonar grupo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abandonar'));
      await tester.pumpAndSettle();

      expect(
        support.harnessHttp.sent('DELETE', 'group_id=eq.$_groupId'),
        isTrue,
        reason: 'leaveGroup must delete the membership row',
      );
      expect(find.text('home-marker'), findsOneWidget);
      expect(find.byType(GroupDetailScreen), findsNothing);
    });

    testWidgets('frozen groups keep the disabled frozen menu item (with no '
        'leave item)', (tester) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(
          group: {
            'id': _groupId,
            'name': 'Disco Crew',
            'group_shards': 100,
            'frozen_at': '2026-08-01T00:00:00Z',
          },
        ),
      );

      expect(
        find.byType(PopupMenuButton<String>),
        findsOneWidget,
        reason: 'the frozen marker lives in the overflow menu (R16)',
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Grupo congelado'), findsOneWidget);
      expect(
        find.text('Abandonar grupo'),
        findsOneWidget,
        reason:
            'the only "Abandonar grupo" is the inline row — the menu '
            'offers no leave item',
      );
    });
  });

  group('R17 — admin member-actions sheet', () {
    GroupMember memberModel(String id, String username, String role) =>
        GroupMember(
          id: 'm-$id',
          groupId: _groupId,
          userId: id,
          role: role,
          joinedAt: DateTime(2026, 1, 1),
          users: {'username': username},
        );

    List<GroupMember> membersWithMe(String myRole) => [
      memberModel(_myUserId, 'yo', myRole),
      memberModel(_userId2, 'lucas', 'member'),
      memberModel(_userId3, 'marta', 'co_promotor'),
    ];

    Widget membersScreen(
      WidgetTester tester, {
      required GroupsRepository groups,
    }) {
      return _wrap(
        const GroupMembersScreen(groupId: _groupId),
        overrides: [groupsRepositoryProvider.overrideWithValue(groups)],
      );
    }

    testWidgets('admin (promotor) rows open the sheet with role-fitting '
        'options', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.getGroupMembers(_groupId),
      ).thenAnswer((_) async => membersWithMe('promotor'));
      await tester.pumpWidget(membersScreen(tester, groups: groups));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lucas'));
      await tester.pumpAndSettle();

      expect(
        find.text('Hacer co-promotor'),
        findsOneWidget,
        reason: 'member rows offer the promote option (R17)',
      );
      expect(
        find.text('Expulsar del grupo'),
        findsOneWidget,
        reason: 'member rows offer the kick option (R17)',
      );
      expect(
        find.text('Hacer miembro'),
        findsNothing,
        reason: 'the demote option fits co_promotor rows only',
      );

      Navigator.of(tester.element(find.text('Hacer co-promotor'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('marta'));
      await tester.pumpAndSettle();
      expect(
        find.text('Hacer miembro'),
        findsOneWidget,
        reason: 'co_promotor rows offer the demote option (R17)',
      );
    });

    testWidgets('non-admin (member) rows never open the sheet', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.getGroupMembers(_groupId),
      ).thenAnswer((_) async => membersWithMe('member'));
      await tester.pumpWidget(membersScreen(tester, groups: groups));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lucas'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(
        find.text('Hacer co-promotor'),
        findsNothing,
        reason: 'non-admins see no member actions (R17)',
      );
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('kick requires confirmation, then calls kickMember and '
        'reloads the list', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.getGroupMembers(_groupId),
      ).thenAnswer((_) async => membersWithMe('promotor'));
      when(
        () => groups.kickMember(_groupId, _userId2),
      ).thenAnswer((_) async {});
      await tester.pumpWidget(membersScreen(tester, groups: groups));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lucas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expulsar del grupo'));
      await tester.pumpAndSettle();

      expect(
        find.text('¿Expulsar a lucas?'),
        findsOneWidget,
        reason: 'kick is confirmed via a dialog first (R17/F8)',
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      verifyNever(() => groups.kickMember(_groupId, _userId2));
      expect(
        find.text('Hacer co-promotor'),
        findsOneWidget,
        reason: 'cancelling the confirm keeps the sheet open',
      );

      await tester.tap(find.text('Expulsar del grupo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expulsar'));
      await tester.pumpAndSettle();

      verify(() => groups.kickMember(_groupId, _userId2)).called(1);
      verify(() => groups.getGroupMembers(_groupId)).called(2);
    });

    testWidgets('promote calls setMemberRole with co_promotor', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.getGroupMembers(_groupId),
      ).thenAnswer((_) async => membersWithMe('promotor'));
      when(
        () => groups.setMemberRole(_groupId, _userId2, 'co_promotor'),
      ).thenAnswer((_) async {});
      await tester.pumpWidget(membersScreen(tester, groups: groups));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lucas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hacer co-promotor'));
      await tester.pumpAndSettle();

      verify(
        () => groups.setMemberRole(_groupId, _userId2, 'co_promotor'),
      ).called(1);
    });

    testWidgets('a failed kick surfaces the transient error snackbar and '
        'keeps the sheet open (F7, U-28 pin)', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.getGroupMembers(_groupId),
      ).thenAnswer((_) async => membersWithMe('promotor'));
      when(
        () => groups.kickMember(_groupId, _userId2),
      ).thenThrow(Exception('kick failed'));
      await tester.pumpWidget(membersScreen(tester, groups: groups));
      await tester.pumpAndSettle();

      await tester.tap(find.text('lucas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expulsar del grupo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expulsar'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Error del servidor'),
        findsOneWidget,
        reason: 'a kicked-RPC failure must surface the mapped F7 snackbar',
      );
      expect(
        find.text('Hacer co-promotor'),
        findsOneWidget,
        reason: 'the failure keeps the sheet open for a retry',
      );
      verify(() => groups.getGroupMembers(_groupId)).called(1);
    });

    testWidgets('group-detail members tab rows open the sheet for admins', (
      tester,
    ) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(
          members: [
            {
              'user_id': _myUserId,
              'role': 'promotor',
              'users': {'username': 'yo'},
            },
            {
              'user_id': _userId2,
              'role': 'member',
              'users': {'username': 'lucas'},
            },
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Miembros'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lucas'));
      await tester.pumpAndSettle();

      expect(
        find.text('Expulsar del grupo'),
        findsOneWidget,
        reason: 'the detail members tab honors the sheet too (R17)',
      );
    });
  });
}
