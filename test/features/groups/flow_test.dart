import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/widgets/chat_thread_view.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/screens/group_members_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/shared/widgets/v_display_text.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../../support/fake_supabase_http.dart' as support;

/// U-16 groups FLOW ledger tests (R16-R17, 2026-08-11).
///
/// Pins the Juega-flow-alignment changes from U-13 §5.3 (the ledger in
/// `docs/history/phase-04-ui/2026-08-11_U16-friends-groups-flow.md`):
/// the inline leave-group row (R16) and the admin member-actions sheet
/// (R17). R11-R15 (friends) live in `test/features/friends/flow_test.dart`.

const _groupId = '33333333-3333-3333-3333-333333333333';
const _myUserId = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';
const _userId3 = '44444444-4444-4444-4444-444444444444';

class _MockGroupsRepository extends Mock implements GroupsRepository {}

class _MockChatRepository extends Mock implements ChatRepository {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState(user: {'id': _myUserId});
}

/// ISSUE 4: the group detail Chat tab resolves the group's chat id through
/// [groupChatIdProvider]; the stub pins the resolved id.
class _StubGroupChatIdNotifier extends GroupChatIdNotifier {
  final String? data;
  _StubGroupChatIdNotifier(this.data);

  @override
  Future<String?> build(String arg) async => data;
}

/// Empty-thread fake so the Chat tab renders without the real E2EE stack.
class _FakeChatMessagesNotifier extends ChatMessagesNotifier {
  final List<Map<String, dynamic>> data;
  _FakeChatMessagesNotifier(this.data);

  @override
  Future<ChatMessagesState> build(String arg) async =>
      ChatMessagesState(messages: data, hasMore: false);
}

/// Stubs every repository seam ChatThreadView touches (realtime channels,
/// read receipts, inbox watermark) so the group detail Chat tab renders
/// hermetically.
_MockChatRepository _stubbedChatRepository() {
  final repo = _MockChatRepository();
  final channel = _MockRealtimeChannel();
  when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
  when(() => repo.subscribe(any(), any())).thenReturn(channel);
  when(() => repo.subscribeToMessageReads(any(), any())).thenReturn(channel);
  when(() => repo.subscribeToMessageDeletes(any(), any())).thenReturn(channel);
  when(() => repo.getReadReceiptsEnabled()).thenAnswer((_) async => true);
  when(() => repo.fetchInbox()).thenAnswer((_) async => const []);
  when(() => repo.markChatRead(any())).thenAnswer((_) async {});
  when(() => repo.markMessagesRead(any())).thenAnswer((_) async {});
  when(() => repo.peerNeedsRekey(any())).thenAnswer((_) async => false);
  return repo;
}

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

/// ISSUE 2: static my-membership stub (the active-state default renders the
/// normal detail; `data` carries the caller's own group_members row).
class _StubMyMembershipNotifier extends MyMembershipNotifier {
  final Map<String, dynamic>? data;
  _StubMyMembershipNotifier({this.data});

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
}

/// ISSUE 2: mutable my-membership stub — [data] can be swapped between
/// builds so the accept-invite flip (invited → active) can be asserted.
class _LiveMyMembershipNotifier extends MyMembershipNotifier {
  _LiveMyMembershipNotifier(this.data);

  Map<String, dynamic>? data;

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
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
  Map<String, dynamic>? membership,
  MyMembershipNotifier Function()? membershipOverride,
  _MockGroupsRepository? repo,
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
  if (repo != null) groupsRepositoryProvider.overrideWithValue(repo),
  myMembershipProvider.overrideWith(
    membershipOverride ??
        () => _StubMyMembershipNotifier(data: membership),
  ),
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
      // LUXE: bounded pumps instead of pumpAndSettle — the members screen's
      // VAurora drift would advance the fake clock past the snackbar's 4s
      // auto-dismiss before the assertion runs.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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

  group('ISSUE 2 — invited membership (pending) detail state', () {
    const invitedRow = {
      'id': 'm-invited',
      'group_id': _groupId,
      'role': 'member',
      'status': 'invited',
    };

    testWidgets('an invited membership shows ONLY Aceptar + Rechazar — no '
        'tabs, no hero CTAs, no leave', (tester) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(membership: invitedRow),
      );

      expect(
        find.text('Aceptar'),
        findsOneWidget,
        reason: 'the primary action is a single Aceptar (ISSUE 2)',
      );
      expect(
        find.text('Rechazar'),
        findsOneWidget,
        reason: 'the secondary action is a Rechazar text button (ISSUE 2)',
      );
      expect(
        find.textContaining('Has sido invitado a este grupo'),
        findsOneWidget,
        reason: 'the pending panel explains the invitation',
      );
      expect(
        find.byType(TabBar),
        findsNothing,
        reason: 'an invited user sees no tab bar at all (ISSUE 2)',
      );
      for (final cta in [
        'Donar shards',
        'Crear evento',
        'Invitar',
        'Juegos',
        'Abandonar grupo',
      ]) {
        expect(
          find.text(cta),
          findsNothing,
          reason: 'no "$cta" for an invited user (ISSUE 2)',
        );
      }
    });

    testWidgets('Aceptar calls acceptInvite with the membership id and the '
        'screen flips to the normal state', (tester) async {
      final groups = _MockGroupsRepository();
      when(() => groups.acceptInvite('m-invited')).thenAnswer((_) async {});
      final membership = _LiveMyMembershipNotifier(invitedRow);
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(
          membershipOverride: () => membership,
          repo: groups,
        ),
      );
      expect(find.text('Aceptar'), findsOneWidget);

      await tester.tap(find.text('Aceptar'));
      // The DB flip lands before the reload — the membership is now active.
      membership.data = null;
      await tester.pumpAndSettle();

      verify(() => groups.acceptInvite('m-invited')).called(1);
      expect(
        find.byType(TabBar),
        findsOneWidget,
        reason: 'the accepted membership reloads into the normal detail',
      );
      expect(find.text('Aceptar'), findsNothing);
    });

    testWidgets('a membership row missing (null) renders the normal active '
        'state (graceful fallback)', (tester) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(membership: null),
      );

      expect(
        find.byType(TabBar),
        findsOneWidget,
        reason: 'no membership row falls back to the active detail',
      );
      expect(find.text('Donar shards'), findsOneWidget);
    });
  });

  group('ISSUE 3 — 4-tab group detail (Info | Chat | Miembros | Eventos)', () {
    testWidgets('active membership renders the four tabs and the Info tab '
        'carries the description + donate CTA', (tester) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(
          group: {
            'id': _groupId,
            'name': 'Disco Crew',
            'group_shards': 100,
            'description': 'Para los que bailan',
          },
        ),
      );

      expect(find.text('Información'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Miembros'), findsOneWidget);
      expect(find.text('Eventos'), findsOneWidget);
      expect(
        find.byType(TabBar),
        findsOneWidget,
        reason: 'the active detail owns a 4-tab TabBar (ISSUE 3)',
      );
      // The Info tab is the default (first) tab — its content renders
      // immediately.
      expect(
        find.text('Para los que bailan'),
        findsOneWidget,
        reason: 'the description lives on the Info tab (ISSUE 3)',
      );
      expect(
        find.text('Donar shards'),
        findsOneWidget,
        reason: 'the CTA row lives on the Info tab (ISSUE 3)',
      );
    });

    testWidgets('the Chat tab hosts the group ChatThreadView once the group '
        'chat id resolves (ISSUE 4)', (tester) async {
      await _pumpGroupDetail(
        tester,
        [
          ..._loadedGroupDetailOverrides(),
          // ISSUE 4: the group's E2EE chat row resolves via groupChatIdProvider.
          groupChatIdProvider.overrideWith(
            () => _StubGroupChatIdNotifier('chat-g-1'),
          ),
          chatE2eeRepositoryProvider.overrideWithValue(
            _stubbedChatRepository(),
          ),
          chatMessagesProvider.overrideWith(
            () => _FakeChatMessagesNotifier(const []),
          ),
          authStateProvider.overrideWith(_StubAuthNotifier.new),
        ],
      );

      // ISSUE 3: the placeholder is gone — the tab hosts the SAME thread
      // widget the 1:1 chat screen uses.
      expect(find.byType(ChatThreadView), findsNothing);
      expect(find.text('Los chats son 1:1 por ahora'), findsNothing);

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();

      expect(
        find.byType(ChatThreadView),
        findsOneWidget,
        reason:
            'the active-member Chat tab renders ChatThreadView instead of '
            'the ISSUE 3 placeholder (ISSUE 4)',
      );
      expect(
        find.text('No hay mensajes todavía'),
        findsOneWidget,
        reason: 'the group thread renders its empty state (chatEmpty)',
      );
      expect(find.text('Enviar'), findsOneWidget);
    });
  });

  group('USER FIX 4 — the group name lives in the AppBar only (no hero '
      'banner)', () {
    testWidgets('active state: the name appears exactly once — in the AppBar '
        'next to the back arrow — and no cover banner renders above the Chat '
        'tab', (tester) async {
      await _pumpGroupDetail(
        tester,
        [
          ..._loadedGroupDetailOverrides(
            group: {
              'id': _groupId,
              'name': 'Disco Crew',
              'group_shards': 100,
              'cover_url': 'https://example.com/cover.png',
            },
          ),
          // The group chat row does not exist in this fixture — the Chat tab
          // renders the honest placeholder (no ChatThreadView to pin down).
          groupChatIdProvider.overrideWith(
            () => _StubGroupChatIdNotifier(null),
          ),
        ],
      );

      final appBarName = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Disco Crew'),
      );
      expect(
        appBarName,
        findsOneWidget,
        reason: 'the name renders next to the back arrow in the AppBar '
            '(USER FIX 4)',
      );
      expect(
        find.text('Disco Crew'),
        findsOneWidget,
        reason: 'the name appears exactly once in the whole tree (USER FIX 4)',
      );
      expect(
        find.byType(VDisplayText),
        findsNothing,
        reason: 'the hero display voice above the tabs is gone (USER FIX 4)',
      );
      expect(
        find.byType(VNetworkImage),
        findsOneWidget,
        reason: 'the cover lives on the Info tab as its first block '
            '(USER FIX 4)',
      );

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();

      expect(
        find.byType(VNetworkImage),
        findsNothing,
        reason: 'no cover banner renders above the Chat thread (USER FIX 4)',
      );
      expect(
        find.text('Disco Crew'),
        findsOneWidget,
        reason: 'the name stays in the AppBar on every tab (USER FIX 4)',
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Disco Crew'),
        ),
        findsOneWidget,
        reason: 'still exactly one name, in the AppBar (USER FIX 4)',
      );
    });

    testWidgets('invited state: the name is in the AppBar only — no in-body '
        'name, no tabs', (tester) async {
      await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(
          membership: {
            'id': 'm-invited',
            'group_id': _groupId,
            'role': 'member',
            'status': 'invited',
          },
        ),
      );

      expect(find.text('Aceptar'), findsOneWidget);
      expect(find.text('Rechazar'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Disco Crew'),
        ),
        findsOneWidget,
        reason: 'the invited panel owns the name in its AppBar title '
            '(USER FIX 4)',
      );
      expect(
        find.text('Disco Crew'),
        findsOneWidget,
        reason:
            'exactly one name on the invited panel — next to the back arrow '
            '(USER FIX 4)',
      );
      expect(
        find.byType(VDisplayText),
        findsNothing,
        reason: 'the in-body display name is gone from the invited panel '
            '(USER FIX 4)',
      );
    });
  });
}
