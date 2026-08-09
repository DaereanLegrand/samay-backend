import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/services/group_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

class _MockGroupService extends Mock implements GroupService {}

class _MockShardsService extends Mock implements ShardsService {}

const _groupId = '33333333-3333-3333-3333-333333333333';
const _otherGroupId = '44444444-4444-4444-4444-444444444444';
const _userId = '11111111-1111-1111-1111-111111111111';
const _membershipId = '55555555-5555-5555-5555-555555555555';

void main() {
  late _MockGroupService groups;
  late _MockShardsService shards;
  late GroupsRepository repo;

  setUp(() {
    groups = _MockGroupService();
    shards = _MockShardsService();
    repo = GroupsRepository(groups: groups, shards: shards);
  });

  group('GroupsRepository.getMyGroups', () {
    test('delegates and maps rows (my_role preserved) to Group', () async {
      when(() => groups.getMyGroups()).thenAnswer((_) async => [
            {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100,
             'my_role': 'promotor'},
            {'id': _otherGroupId, 'name': 'Vinyl Lovers', 'my_role': 'member'},
          ]);

      final rows = await repo.getMyGroups();

      verify(() => groups.getMyGroups()).called(1);
      expect(rows, hasLength(2));
      expect(rows, isA<List<Group>>());
      expect(rows.first.id, _groupId);
      expect(rows.first.name, 'Disco Crew');
      expect(rows.first.groupShards, 100);
      expect(rows.first.myRole, 'promotor');
    });
  });

  group('GroupsRepository.getGroup', () {
    test('returns a typed Group', () async {
      when(() => groups.getGroup(_groupId)).thenAnswer(
        (_) async => {'id': _groupId, 'name': 'Disco Crew', 'size_tier': 'small'},
      );

      final group = await repo.getGroup(_groupId);

      verify(() => groups.getGroup(_groupId)).called(1);
      expect(group, isA<Group>());
      expect(group!.sizeTier, 'small');
    });

    test('returns null when the group does not exist', () async {
      when(() => groups.getGroup(_groupId)).thenAnswer((_) async => null);

      expect(await repo.getGroup(_groupId), isNull);
    });

    test('propagates service errors', () async {
      when(() => groups.getGroup(_groupId)).thenThrow(
        const PostgrestException(message: 'forbidden', code: '42501'),
      );

      final err = await captureError(() => repo.getGroup(_groupId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('GroupsRepository.getGroupMembers', () {
    test('delegates and maps rows to GroupMember (users join preserved)',
        () async {
      when(() => groups.getGroupMembers(_groupId)).thenAnswer((_) async => [
            {'id': _membershipId, 'group_id': _groupId, 'user_id': _userId,
             'role': 'promotor', 'status': 'active',
             'joined_at': '2026-08-01T00:00:00Z',
             'users': {'username': 'ana'}},
          ]);

      final members = await repo.getGroupMembers(_groupId);

      verify(() => groups.getGroupMembers(_groupId)).called(1);
      expect(members, isA<List<GroupMember>>());
      expect(members.first.role, 'promotor');
      expect(members.first.username, 'ana');
    });
  });

  group('GroupsRepository getGroupInvites (map passthrough — joins groups)',
      () {
    test('forwards the invites rows untouched', () async {
      when(() => groups.getGroupInvites()).thenAnswer((_) async => [
            {'id': _membershipId, 'group_id': _groupId, 'role': 'member',
             'groups': {'name': 'Disco Crew'}},
          ]);

      final invites = await repo.getGroupInvites();

      verify(() => groups.getGroupInvites()).called(1);
      expect((invites.single['groups'] as Map)['name'], 'Disco Crew');
    });

    test('accept/decline forward the membership id', () async {
      when(() => groups.acceptGroupInvite(_membershipId))
          .thenAnswer((_) async {});
      when(() => groups.declineGroupInvite(_membershipId))
          .thenAnswer((_) async {});

      await repo.acceptInvite(_membershipId);
      await repo.declineInvite(_membershipId);

      verify(() => groups.acceptGroupInvite(_membershipId)).called(1);
      verify(() => groups.declineGroupInvite(_membershipId)).called(1);
    });
  });

  group('GroupsRepository leaderboard + contributions', () {
    test('getLeaderboard passes rank snapshots through', () async {
      when(() => shards.getLeaderboard('small')).thenAnswer((_) async => const [
            {'group_id': _groupId, 'rank_position': 1, 'score': 500,
             'member_count': 12},
          ]);

      final rows = await repo.getLeaderboard('small');

      verify(() => shards.getLeaderboard('small')).called(1);
      expect(rows.single['score'], 500);
    });

    test('getGroupContributions passes aggregation rows through', () async {
      when(() => shards.getGroupContributions(_groupId)).thenAnswer(
        (_) async => const [
          {'user_id': _userId, 'shards_contributed': 50,
           'users': {'username': 'ana'}},
        ],
      );

      final rows = await repo.getGroupContributions(_groupId);

      verify(() => shards.getGroupContributions(_groupId)).called(1);
      expect(rows.single['shards_contributed'], 50);
    });

    test('getUserContributionToGroup forwards the group id', () async {
      when(() => shards.getUserContributionToGroup(_groupId))
          .thenAnswer((_) async => 30);

      expect(await repo.getUserContributionToGroup(_groupId), 30);

      verify(() => shards.getUserContributionToGroup(_groupId)).called(1);
    });
  });

  group('GroupsRepository mutations', () {
    test('donateToGroup forwards group + amount', () async {
      when(() => shards.donateToGroup(_groupId, 100))
          .thenAnswer((_) async {});

      await repo.donateToGroup(_groupId, 100);

      verify(() => shards.donateToGroup(_groupId, 100)).called(1);
    });

    test('donateToGroup propagates insufficient-shards errors', () async {
      when(() => shards.donateToGroup(_groupId, 100))
          .thenThrow(Exception('No tienes suficientes shards'));

      final err = await captureError(() => repo.donateToGroup(_groupId, 100));
      expect(err, isA<Exception>());
    });

    test('leaveGroup / joinGroup / inviteMembers forward their args', () async {
      when(() => groups.leaveGroup(_groupId)).thenAnswer((_) async {});
      when(() => groups.joinGroup(_groupId)).thenAnswer((_) async {});
      when(() => groups.inviteMembers(_groupId, [_userId]))
          .thenAnswer((_) async {});

      await repo.leaveGroup(_groupId);
      await repo.joinGroup(_groupId);
      await repo.inviteMembers(_groupId, [_userId]);

      verify(() => groups.leaveGroup(_groupId)).called(1);
      verify(() => groups.joinGroup(_groupId)).called(1);
      verify(() => groups.inviteMembers(_groupId, [_userId])).called(1);
    });

    test('management mutations forward their args', () async {
      when(() => groups.createGroup(any())).thenAnswer((_) async => const {
            'id': _groupId, 'name': 'Disco Crew'});
      when(() => groups.updateGroup(_groupId, any())).thenAnswer((_) async {});
      when(() => groups.kickMember(_groupId, _userId)).thenAnswer((_) async {});
      when(() => groups.transferPromotor(_groupId, _userId))
          .thenAnswer((_) async {});
      when(() => groups.setMemberRole(_groupId, _userId, 'co_promotor'))
          .thenAnswer((_) async {});
      when(() => groups.getUserGroupCount()).thenAnswer((_) async => 1);

      await repo.createGroup(const {'name': 'Disco Crew'});
      await repo.updateGroup(_groupId, const {'description': 'x'});
      await repo.kickMember(_groupId, _userId);
      await repo.transferPromotor(_groupId, _userId);
      await repo.setMemberRole(_groupId, _userId, 'co_promotor');
      expect(await repo.getUserGroupCount(), 1);

      verify(() => groups.createGroup(const {'name': 'Disco Crew'})).called(1);
      verify(() => groups.updateGroup(_groupId, const {'description': 'x'}))
          .called(1);
      verify(() => groups.kickMember(_groupId, _userId)).called(1);
      verify(() => groups.transferPromotor(_groupId, _userId)).called(1);
      verify(() => groups.setMemberRole(_groupId, _userId, 'co_promotor'))
          .called(1);
      verify(() => groups.getUserGroupCount()).called(1);
    });
  });
}
