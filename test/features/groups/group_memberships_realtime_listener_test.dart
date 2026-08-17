import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/groups/providers/group_memberships_realtime_listener.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';

import '../../support/resolving_builder.dart';

class MockRealtimeService extends Mock implements RealtimeService {}

/// GroupMembershipsRealtimeListener (2026-08-17): the shell-mounted listener
/// keeps the group invites / my-groups lists fresh on the REMOTE side — any
/// group_members row event for the user invalidates both providers, so an
/// invite lands without an app restart.
const _userId = '11111111-1111-1111-1111-111111111111';
const _otherUserId = '22222222-2222-2222-2222-222222222222';

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, user: {'id': _userId});
}

class _CountingGroupInvitesNotifier extends GroupInvitesNotifier {
  final List<int> onBuild;

  _CountingGroupInvitesNotifier(this.onBuild);

  @override
  Future<List<Map<String, dynamic>>> build() async {
    onBuild.add(1);
    return <Map<String, dynamic>>[];
  }
}

class _CountingMyGroupsNotifier extends MyGroupsNotifier {
  final List<int> onBuild;

  _CountingMyGroupsNotifier(this.onBuild);

  @override
  Future<List<Group>> build() async {
    onBuild.add(1);
    return const <Group>[];
  }
}

class _CountingGroupMembersNotifier extends GroupMembersNotifier {
  final List<int> onBuild;

  _CountingGroupMembersNotifier(this.onBuild);

  @override
  Future<List<GroupMember>> build(String arg) async {
    onBuild.add(1);
    return const <GroupMember>[];
  }
}

void main() {
  setUpAll(() {
    // mocktail cannot synthesize function-typed fallback values for `any()`.
    registerFallbackValue((Map<String, dynamic> _) {});
  });

  testWidgets('invalidates invites + my-groups providers on a remote '
      'group_members event for the user', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    late void Function(Map<String, dynamic>) onChange;
    when(() => realtime.subscribeToGroupMemberships(any())).thenAnswer((
      inv,
    ) async {
      onChange =
          inv.positionalArguments[0] as void Function(Map<String, dynamic>);
      return channel;
    });

    final invitesBuilds = <int>[];
    final myGroupsBuilds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
        groupInvitesProvider.overrideWith(
          () => _CountingGroupInvitesNotifier(invitesBuilds),
        ),
        myGroupsProvider.overrideWith(
          () => _CountingMyGroupsNotifier(myGroupsBuilds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The listener subscribes once the auth state resolves.
    expect(
      onChange,
      isNotNull,
      reason: 'the listener subscribes after the auth user resolves',
    );

    // Warm both providers so invalidation is observable as a re-build.
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);
    final buildsBefore = invitesBuilds.length + myGroupsBuilds.length;

    // Remote side invites the user → group_members INSERT row.
    onChange({
      'id': 'gm-1',
      'group_id': 'g-1',
      'user_id': _userId,
      'status': 'invited',
    });
    await tester.pump();

    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);

    expect(
      invitesBuilds.length + myGroupsBuilds.length,
      greaterThan(buildsBefore),
      reason: 'the event invalidated both providers',
    );
  });

  testWidgets('ignores rows for other users', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    late void Function(Map<String, dynamic>) onChange;
    when(() => realtime.subscribeToGroupMemberships(any())).thenAnswer((
      inv,
    ) async {
      onChange =
          inv.positionalArguments[0] as void Function(Map<String, dynamic>);
      return channel;
    });

    final invitesBuilds = <int>[];
    final myGroupsBuilds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
        groupInvitesProvider.overrideWith(
          () => _CountingGroupInvitesNotifier(invitesBuilds),
        ),
        myGroupsProvider.overrideWith(
          () => _CountingMyGroupsNotifier(myGroupsBuilds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);
    final buildsBefore = invitesBuilds.length + myGroupsBuilds.length;

    // A membership row for ANOTHER user must not trigger rebuilds.
    onChange({
      'id': 'gm-2',
      'group_id': 'g-1',
      'user_id': _otherUserId,
      'status': 'invited',
    });
    await tester.pump();

    expect(
      invitesBuilds.length + myGroupsBuilds.length,
      buildsBefore,
      reason: 'a row for another user must not invalidate the providers',
    );
  });

  testWidgets('invalidates the group members provider on any event, and '
      'invites + my-groups only for the user\u2019s own rows', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    late void Function(Map<String, dynamic>) onChange;
    when(() => realtime.subscribeToGroupMemberships(any())).thenAnswer((
      inv,
    ) async {
      onChange =
          inv.positionalArguments[0] as void Function(Map<String, dynamic>);
      return channel;
    });

    final invitesBuilds = <int>[];
    final myGroupsBuilds = <int>[];
    final membersBuilds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
        groupInvitesProvider.overrideWith(
          () => _CountingGroupInvitesNotifier(invitesBuilds),
        ),
        myGroupsProvider.overrideWith(
          () => _CountingMyGroupsNotifier(myGroupsBuilds),
        ),
        groupMembersProvider.overrideWith(
          () => _CountingGroupMembersNotifier(membersBuilds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The listener subscribes once the auth state resolves.
    expect(
      onChange,
      isNotNull,
      reason: 'the listener subscribes after the auth user resolves',
    );

    // Warm the providers so invalidation is observable as a re-build.
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);
    await container.read(groupMembersProvider('g-1').future);
    final invitesBefore = invitesBuilds.length;
    final myGroupsBefore = myGroupsBuilds.length;
    final membersBefore = membersBuilds.length;

    // A co-member accepts/joins/gets kicked → only that group's members
    // provider rebuilds (the open detail screen refreshes its members tab).
    onChange({
      'id': 'gm-2',
      'group_id': 'g-1',
      'user_id': _otherUserId,
      'status': 'active',
    });
    await tester.pump();

    await container.read(groupMembersProvider('g-1').future);
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);

    expect(
      membersBuilds.length,
      greaterThan(membersBefore),
      reason: 'a co-member event invalidates the group members provider',
    );
    expect(
      invitesBuilds.length,
      invitesBefore,
      reason: 'a row for another user must not invalidate the invites provider',
    );
    expect(
      myGroupsBuilds.length,
      myGroupsBefore,
      reason: 'a row for another user must not invalidate my-groups',
    );

    // The user's OWN row → invites, my-groups AND members all rebuild.
    final invitesBefore2 = invitesBuilds.length;
    final myGroupsBefore2 = myGroupsBuilds.length;
    final membersBefore2 = membersBuilds.length;

    onChange({
      'id': 'gm-1',
      'group_id': 'g-1',
      'user_id': _userId,
      'status': 'active',
    });
    await tester.pump();

    await container.read(groupMembersProvider('g-1').future);
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);

    expect(
      membersBuilds.length,
      greaterThan(membersBefore2),
      reason: 'an own-row event invalidates the group members provider too',
    );
    expect(
      invitesBuilds.length,
      greaterThan(invitesBefore2),
      reason: 'an own-row event invalidates the invites provider',
    );
    expect(
      myGroupsBuilds.length,
      greaterThan(myGroupsBefore2),
      reason: 'an own-row event invalidates my-groups',
    );
  });

  testWidgets('tolerates a row without a group_id', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    late void Function(Map<String, dynamic>) onChange;
    when(() => realtime.subscribeToGroupMemberships(any())).thenAnswer((
      inv,
    ) async {
      onChange =
          inv.positionalArguments[0] as void Function(Map<String, dynamic>);
      return channel;
    });

    final invitesBuilds = <int>[];
    final myGroupsBuilds = <int>[];
    final membersBuilds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
        groupInvitesProvider.overrideWith(
          () => _CountingGroupInvitesNotifier(invitesBuilds),
        ),
        myGroupsProvider.overrideWith(
          () => _CountingMyGroupsNotifier(myGroupsBuilds),
        ),
        groupMembersProvider.overrideWith(
          () => _CountingGroupMembersNotifier(membersBuilds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);
    await container.read(groupMembersProvider('g-1').future);
    final invitesBefore = invitesBuilds.length;
    final myGroupsBefore = myGroupsBuilds.length;
    final membersBefore = membersBuilds.length;

    // A row with a missing group_id (unexpected payload) must not crash and
    // must not invalidate anything.
    onChange({
      'id': 'gm-3',
      'user_id': _otherUserId,
      'status': 'active',
    });
    await tester.pump();

    await container.read(groupMembersProvider('g-1').future);
    await container.read(groupInvitesProvider.future);
    await container.read(myGroupsProvider.future);

    expect(membersBuilds.length, membersBefore);
    expect(invitesBuilds.length, invitesBefore);
    expect(myGroupsBuilds.length, myGroupsBefore);
  });

  testWidgets('re-subscribes when the authenticated user changes', (
    tester,
  ) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    var subscribeCalls = 0;
    when(() => realtime.subscribeToGroupMemberships(any())).thenAnswer((
      inv,
    ) async {
      subscribeCalls++;
      return channel;
    });

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(subscribeCalls, 1);

    // A different user signs in → the listener drops the old channel and
    // subscribes again for the new uid.
    container.read(authStateProvider.notifier).state = const AsyncData(
      AuthState(authenticated: true, user: {'id': _otherUserId}),
    );
    await tester.pumpAndSettle();

    expect(
      subscribeCalls,
      2,
      reason: 'the listener re-subscribes on a user change',
    );
    verify(() => channel.unsubscribe()).called(1);
  });

  testWidgets('unsubscribes on dispose', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    when(
      () => realtime.subscribeToGroupMemberships(any()),
    ).thenAnswer((inv) async => channel);

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: GroupMembershipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    verify(() => channel.unsubscribe()).called(1);
  });
}
