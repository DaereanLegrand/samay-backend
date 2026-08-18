import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../../support/fake_supabase_http.dart' as support;

/// ISSUE: the iPhone group-detail member list is STUCK at 4 members while
/// Android/waydroid update (2026-08-17 user report).
///
/// Root cause (diagnosed): `groupMembersProvider` (and the other detail
/// providers) are keep-alive FAMILY providers — a re-opened detail screen
/// serves the STALE cached state forever. Only the shell-mounted realtime
/// listener refreshes the remote side, and only when (a) the build ships
/// it and (b) the channel actually delivered the event (missed events are
/// never replayed). The members tab additionally has NO pull-to-refresh, so
/// there is no non-realtime path to fresh data.
///
/// Fix contract pinned here:
///   1. every group-detail MOUNT refetches the group/members/contributions
///      providers (screen-open freshness — works on every build, no realtime
///      dependency);
///   2. the Miembros tab gains a pull-to-refresh gesture.
const _groupId = '33333333-3333-3333-3333-333333333333';
const _myUserId = '11111111-1111-1111-1111-111111111111';

GroupMember _member(String id, String username) => GroupMember(
      id: 'gm-$id',
      groupId: _groupId,
      userId: id,
      role: 'member',
      status: 'active',
      joinedAt: DateTime(2026),
      users: {'username': username},
    );

List<GroupMember> _fourMembers() => [
      _member('11111111-1111-1111-1111-111111111111', 'tester1'),
      _member('22222222-2222-2222-2222-222222222222', 'tester2'),
      _member('33333333-4444-4444-4444-444444444444', 'tester3'),
      _member('55555555-6666-6666-6666-666666666666', 'tester4'),
    ];

class _StubGroupDetailNotifier extends GroupDetailNotifier {
  final Group? _data;
  _StubGroupDetailNotifier({Group? data}) : _data = data;

  @override
  Future<Group?> build(String arg) async => _data ?? const Group(
        id: _groupId,
        name: 'Disco Crew',
        groupShards: 100,
        sizeTier: 'micro',
        rankBracket: 'b0_20',
      );
}

class _StubContributionsNotifier extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      const GroupContributionsData(contributors: [], myContribution: 0);
}

class _StubGroupMembersNotifier extends GroupMembersNotifier {
  final List<GroupMember> data;
  _StubGroupMembersNotifier({this.data = const []});

  @override
  Future<List<GroupMember>> build(String arg) async => data;
}

class _StubMyMembershipNotifier extends MyMembershipNotifier {
  final Map<String, dynamic>? _data;
  _StubMyMembershipNotifier({Map<String, dynamic>? data}) : _data = data;

  @override
  Future<Map<String, dynamic>?> build(String arg) async => _data ?? {
        'id': 'm-1',
        'group_id': _groupId,
        'user_id': _myUserId,
        'role': 'promotor',
        'status': 'active',
      };
}

class _StubGroupChatIdNotifier extends GroupChatIdNotifier {
  @override
  Future<String?> build(String arg) async => null;
}

/// MUTABLE combined provider stub: mirrors the members-list mutation pattern
/// so the screen's refresh/re-mount tests work (M5).
class _MutableGroupDetailCombinedNotifier extends GroupDetailCombinedNotifier {
  _MutableGroupDetailCombinedNotifier(this._data);

  GroupDetailData _data;

  set data(GroupDetailData value) => _data = value;

  @override
  Future<GroupDetailData> build(String arg) async => _data;
}

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  Widget app(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SamayTheme.dark,
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GroupDetailScreen(groupId: _groupId),
        ),
      );

  ({ProviderContainer container, _MutableGroupDetailCombinedNotifier combined})
  containerWith({
    List<GroupMember> members = const [],
  }) {
    final group = const Group(
      id: _groupId,
      name: 'Disco Crew',
      groupShards: 100,
      sizeTier: 'micro',
      rankBracket: 'b0_20',
    );
    final contributions =
        const GroupContributionsData(contributors: [], myContribution: 0);
    final membership = {
      'id': 'm-1',
      'group_id': _groupId,
      'user_id': _myUserId,
      'role': 'promotor',
      'status': 'active',
    };
    final combinedNotifier = _MutableGroupDetailCombinedNotifier(
      GroupDetailData(
        group: group,
        members: members,
        contributions: contributions,
        membership: membership,
      ),
    );
    final container = ProviderContainer(overrides: [
      groupDetailProvider.overrideWith(
        () => _StubGroupDetailNotifier(data: group),
      ),
      groupMembersProvider.overrideWith(
        () => _StubGroupMembersNotifier(data: members),
      ),
      contributionsProvider.overrideWith(_StubContributionsNotifier.new),
      myMembershipProvider.overrideWith(
        () => _StubMyMembershipNotifier(data: membership),
      ),
      groupChatIdProvider.overrideWith(_StubGroupChatIdNotifier.new),
      groupDetailCombinedProvider.overrideWith(() => combinedNotifier),
    ]);
    addTearDown(container.dispose);
    return (container: container, combined: combinedNotifier);
  }

  testWidgets('re-mounting the group detail refetches the members list — a '
      'member who joined on another device appears without restart or pull '
      '(the iPhone stuck-at-4 class)', (tester) async {
    final (:container, :combined) = containerWith(members: _fourMembers());
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    // First mount: 4 members ("4 / 14 miembros" on the Info tab).
    expect(find.text('4 / 14 miembros'), findsOneWidget);

    // The remote side changed while the screen was closed: tester5 joined.
    final newMembers = [
      ..._fourMembers(),
      _member('77777777-8888-8888-8888-888888888888', 'tester5'),
    ];
    combined.data = GroupDetailData(
      group: const Group(
        id: _groupId,
        name: 'Disco Crew',
        groupShards: 100,
        sizeTier: 'micro',
        rankBracket: 'b0_20',
      ),
      members: newMembers,
      contributions:
          const GroupContributionsData(contributors: [], myContribution: 0),
      membership: {
        'id': 'm-1',
        'group_id': _groupId,
        'user_id': _myUserId,
        'role': 'promotor',
        'status': 'active',
      },
    );

    // Re-mount the screen (navigate away and back).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    // The refetched list must include the new member (5 / 14 miembros).
    expect(
      find.text('5 / 14 miembros'),
      findsOneWidget,
      reason: 'a re-opened group detail must REFETCH its members — the '
          'keep-alive family cache serves the stale 4-member state '
          'otherwise (the reported stuck-at-4 bug)',
    );
  });

  testWidgets('pull-to-refresh on the Miembros tab refetches the members '
      'list', (tester) async {
    final (:container, :combined) = containerWith(members: _fourMembers());
    await tester.pumpWidget(app(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Miembros'));
    await tester.pumpAndSettle();
    expect(find.text('tester4'), findsOneWidget);

    // tester5 joined on another device since the last fetch.
    final newMembers = [
      ..._fourMembers(),
      _member('77777777-8888-8888-8888-888888888888', 'tester5'),
    ];
    combined.data = GroupDetailData(
      group: const Group(
        id: _groupId,
        name: 'Disco Crew',
        groupShards: 100,
        sizeTier: 'micro',
        rankBracket: 'b0_20',
      ),
      members: newMembers,
      contributions:
          const GroupContributionsData(contributors: [], myContribution: 0),
      membership: {
        'id': 'm-1',
        'group_id': _groupId,
        'user_id': _myUserId,
        'role': 'promotor',
        'status': 'active',
      },
    );

    // Pull down on the members list.
    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text('tester5'),
      findsOneWidget,
      reason: 'pull-to-refresh on the Miembros tab must refetch the members '
          'list (there is no other non-realtime path to fresh data)',
    );
  });
}
