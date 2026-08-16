
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/group_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// GroupService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// the 3-table createGroup shape, leaveGroup orphan deletion, invites and
/// membership queries, plus error propagation through the real error_mapper.
const _userId = '11111111-1111-1111-1111-111111111111';
const _memberId = '22222222-2222-2222-2222-222222222222';
const _groupId = '33333333-3333-3333-3333-333333333333';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  GroupService service() => GroupService(client: client);

  group('GroupService.createGroup (3-table transaction shape)', () {
    test('inserts groups + group_members(promotor) + chats in one shape',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final groups = MockQueryBuilder();
      final members = MockQueryBuilder();
      final chats = MockQueryBuilder();
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => groups.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => members.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => chats.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      final created = await service().createGroup({
        'name': '  Fiesta Club  ',
        'description': '  Para los que bailan  ',
        'cover_url': 'https://cdn.example/covers/1.png',
      });

      final groupPayload = verify(() => groups.insert(captureAny()))
          .captured
          .single as Map;
      final memberPayload = verify(() => members.insert(captureAny()))
          .captured
          .single as Map;
      final chatPayload = verify(() => chats.insert(captureAny()))
          .captured
          .single as Map;

      // groups row: sanitized fields + the generated id + promotor.
      expect(groupPayload['id'], isNotEmpty);
      expect(groupPayload['name'], 'Fiesta Club');
      expect(groupPayload['description'], 'Para los que bailan');
      expect(groupPayload['created_by_user_id'], _userId);
      expect(groupPayload['rank_bracket'], 'b0_20');
      expect(created['id'], groupPayload['id']);
      expect(created['name'], 'Fiesta Club');
      expect(created['description'], 'Para los que bailan');

      // group_members row: creator is the promotor of the new group.
      expect(memberPayload['group_id'], groupPayload['id']);
      expect(memberPayload['user_id'], _userId);
      expect(memberPayload['role'], 'promotor');

      // chats row: a group chat attached to the new group.
      expect(chatPayload['type'], 'group');
      expect(chatPayload['reference_id'], groupPayload['id']);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().createGroup({'name': 'X'}),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => client.from('groups'));
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final groups = MockQueryBuilder();
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => groups.insert(any())).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      final err =
          await captureError(() => service().createGroup({'name': 'X'}));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('GroupService.leaveGroup (orphan deletion)', () {
    test('keeps the group when other members remain', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      final groups = MockQueryBuilder();
      final chats = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => client.from('chats')).thenAnswer((_) => chats);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => members.delete()).thenAnswer((_) => del);
      when(() => members.select('id')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': 'still-there'},
        ]),
      );

      await service().leaveGroup(_groupId);

      // The member row is deleted…
      expect(del.filters, containsAllInOrder([
        const RecordedFilter('group_id', _groupId),
        const RecordedFilter('user_id', _userId),
      ]));
      // …but the group is NOT (a member remains).
      verifyNever(() => groups.delete());
      verifyNever(() => chats.delete());
    });

    test('deletes the group and its chat when the last member leaves',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      final groups = MockQueryBuilder();
      final chats = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => members.delete())
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => members.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));
      final groupsDel = ResolvingBuilder<dynamic>(null);
      when(() => groups.delete()).thenAnswer((_) => groupsDel);
      final chatsDel = ResolvingBuilder<dynamic>(null);
      when(() => chats.delete()).thenAnswer((_) => chatsDel);

      await service().leaveGroup(_groupId);

      expect(groupsDel.filters.single.value, _groupId);
      expect(chatsDel.filters, containsAllInOrder([
        const RecordedFilter('reference_id', _groupId),
        const RecordedFilter('type', 'group'),
      ]));
    });
  });

  group('GroupService.inviteMembers', () {
    test('inserts one invited membership per user', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => members.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service()
          .inviteMembers(_groupId, [_memberId, _userId]);

      verify(() => members.insert({
        'group_id': _groupId,
        'user_id': _memberId,
        'role': 'member',
        'status': 'invited',
      })).called(1);
      verify(() => members.insert({
        'group_id': _groupId,
        'user_id': _userId,
        'role': 'member',
        'status': 'invited',
      })).called(1);
    });

    test('propagates an insert failure', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => members.insert(any())).thenThrow(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint',
          code: '23505',
        ),
      );

      final err = await captureError(
        () => service().inviteMembers(_groupId, [_memberId]),
      );
      expect(err, isA<PostgrestException>());
      expectMapped(err, ValidationError);
    });
  });

  group('GroupService.joinGroup / acceptGroupInvite / declineGroupInvite', () {
    test('joinGroup inserts the caller as a member', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => members.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().joinGroup(_groupId);

      verify(() => members.insert({
        'group_id': _groupId,
        'user_id': _userId,
        'role': 'member',
      })).called(1);
    });

    test('acceptGroupInvite flips the membership to active', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => members.update(any())).thenAnswer((_) => update);

      await service().acceptGroupInvite('membership-1');

      verify(() => members.update({'status': 'active'})).called(1);
      expect(update.filters.single.value, 'membership-1');
    });

    test('declineGroupInvite deletes the membership', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => members.delete()).thenAnswer((_) => del);

      await service().declineGroupInvite('membership-1');

      expect(del.filters.single.value, 'membership-1');
    });
  });

  group('GroupService.getGroup / getGroupMembers / getGroupInvites', () {
    test('getGroup returns the mapped row or null', () async {
      final groups = MockQueryBuilder();
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => groups.select()).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'id': _groupId,
          'name': 'Fiesta Club',
        }),
      );

      final group = await service().getGroup(_groupId);
      expect(group?['name'], 'Fiesta Club');

      when(() => groups.select())
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));
      expect(await service().getGroup(_groupId), isNull);
    });

    test('getGroupMembers selects active members with usernames', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'm-1',
          'user_id': _memberId,
          'role': 'promotor',
          'status': 'active',
          'users': {'username': 'dana'},
        },
      ]);
      when(() => members.select(any())).thenAnswer((_) => rows);

      final result = await service().getGroupMembers(_groupId);

      expect(result, hasLength(1));
      expect(result.single['users'], {'username': 'dana'});
      expect(rows.filters, contains(
        const RecordedFilter('group_id', _groupId),
      ));
      expect(rows.filters, contains(
        const RecordedFilter('status', 'active'),
      ));
      // OPT-009 regression: the select must carry `group_id` (the freezed
      // GroupMember.fromJson requires it — a missing key TypeError'd the
      // whole group detail screen into "Error del servidor") and must join
      // through the security-barrier `user_search_view` (the raw `users`
      // join is own-row-only under RLS, so co-members' usernames were
      // silently dropped from the member list).
      verify(() => members.select(
        'id, group_id, user_id, role, joined_at, status, '
        'users:user_search_view!inner(username)',
      )).called(1);
    });

    test('getGroupInvites returns invited memberships', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'm-1',
          'group_id': _groupId,
          'role': 'member',
          'groups': {'name': 'Fiesta Club'},
        },
      ]);
      when(() => members.select(any())).thenAnswer((_) => rows);

      final invites = await service().getGroupInvites();

      expect(invites, hasLength(1));
      expect(invites.single['groups'], {'name': 'Fiesta Club'});
    });
  });

  group('GroupService.getMyGroups (my_role + my_status enrichment)', () {
    test('merges the membership role and status into every group row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      final groups = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => client.from('groups')).thenAnswer((_) => groups);
      when(() => members.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'group_id': 'g-1', 'role': 'promotor', 'status': 'active'},
          {'group_id': 'g-2', 'role': 'member', 'status': 'invited'},
        ]),
      );
      when(() => groups.select()).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': 'g-1', 'name': 'Club A'},
          {'id': 'g-2', 'name': 'Club B'},
        ]),
      );

      final mine = await service().getMyGroups();

      expect(mine, hasLength(2));
      expect(mine.firstWhere((g) => g['id'] == 'g-1')['my_role'], 'promotor');
      expect(mine.firstWhere((g) => g['id'] == 'g-1')['my_status'], 'active');
      expect(mine.firstWhere((g) => g['id'] == 'g-2')['my_role'], 'member');
      expect(mine.firstWhere((g) => g['id'] == 'g-2')['my_status'], 'invited');
      // ISSUE 2: the select must carry `status` or invited memberships lose
      // their pending marker (they appeared in the list without one).
      verify(() => members.select('group_id, role, status')).called(1);
    });

    test('returns an empty list when there are no memberships', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => members.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      expect(await service().getMyGroups(), isEmpty);
      verifyNever(() => client.from('groups'));
    });
  });

  group('GroupService.getMyMembership (ISSUE 2)', () {
    test('returns the caller\'s own membership row for the group', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final rows = ResolvingBuilder<PostgrestList>({
        'id': 'm-1',
        'group_id': _groupId,
        'role': 'member',
        'status': 'invited',
      });
      when(() => members.select(any())).thenAnswer((_) => rows);

      final membership = await service().getMyMembership(_groupId);

      expect(membership, isNotNull);
      expect(membership!['id'], 'm-1');
      expect(membership['group_id'], _groupId);
      expect(membership['role'], 'member');
      expect(membership['status'], 'invited');
      // The select carries id/group_id/role/status — the detail screen needs
      // the membership id to accept/decline the invite.
      verify(() => members.select('id, group_id, role, status')).called(1);
      expect(rows.filters, contains(const RecordedFilter('group_id', _groupId)));
    });

    test('returns null when the caller has no membership row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      when(() => members.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getMyMembership(_groupId), isNull);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().getMyMembership(_groupId),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => client.from('group_members'));
    });
  });

  group('GroupService.getUserGroupCount', () {
    test('counts the rows where the caller is promotor', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final rows = ResolvingBuilder<PostgrestList>([
        {'id': 'm-1'},
        {'id': 'm-2'},
        {'id': 'm-3'},
      ]);
      when(() => members.select('id')).thenAnswer((_) => rows);

      expect(await service().getUserGroupCount(), 3);
      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('user_id', _userId),
        const RecordedFilter('role', 'promotor'),
      ]));
    });
  });

  group('GroupService.getGroupChatId (ISSUE 4 / D3d)', () {
    test('returns the chats.id of the group chat (type=group, reference_id)',
        () async {
      final chats = MockQueryBuilder();
      when(() => client.from('chats')).thenAnswer((_) => chats);
      final rows = ResolvingBuilder<PostgrestList>({'id': 'chat-1'});
      when(() => chats.select(any())).thenAnswer((_) => rows);

      final chatId = await service().getGroupChatId(_groupId);

      expect(chatId, 'chat-1');
      verify(() => chats.select('id')).called(1);
      // The lookup is scoped to the group chat row of THIS group.
      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('type', 'group'),
        const RecordedFilter('reference_id', _groupId),
      ]));
    });

    test('returns null when the group has no chat row', () async {
      final chats = MockQueryBuilder();
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => chats.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getGroupChatId(_groupId), isNull);
    });

    test('propagates a permission-denied PostgrestException', () async {
      final chats = MockQueryBuilder();
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => chats.select(any())).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      final err =
          await captureError(() => service().getGroupChatId(_groupId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('GroupService.transferPromotor / setMemberRole / kickMember', () {
    test('transferPromotor runs the transfer_promotor RPC (OPT-009 chain: '
        'promotor-only, atomic — the old two-PATCH dance let co_promotors '
        'interleave and broke under the role-hierarchy RLS)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({'status': 'ok'});
      when(
        () => client.rpc(
          'transfer_promotor',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => rpc);

      await service().transferPromotor(_groupId, _memberId);

      verify(() => client.rpc('transfer_promotor', params: {
        'p_group_id': _groupId,
        'p_new_promotor_id': _memberId,
      })).called(1);
      verifyNever(() => client.from('group_members'));
    });

    test('setMemberRole updates the role for the target member', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => members.update(any())).thenAnswer((_) => update);

      await service().setMemberRole(_groupId, _memberId, 'co_promotor');

      verify(() => members.update({'role': 'co_promotor'})).called(1);
      expect(update.filters, containsAllInOrder([
        const RecordedFilter('group_id', _groupId),
        const RecordedFilter('user_id', _memberId),
      ]));
    });

    test('kickMember deletes the membership scoped to group+user', () async {
      final members = MockQueryBuilder();
      when(() => client.from('group_members')).thenAnswer((_) => members);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => members.delete()).thenAnswer((_) => del);

      await service().kickMember(_groupId, _memberId);

      expect(del.filters, containsAllInOrder([
        const RecordedFilter('group_id', _groupId),
        const RecordedFilter('user_id', _memberId),
      ]));
    });
  });
}
