import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group_member.dart';

void main() {
  const id = 'c001d002-e003-4f04-8a05-6b07c08d09e0';
  final fixture = <String, dynamic>{
    'id': id,
    'group_id': 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
    'user_id': '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60',
    'role': 'co_promotor',
    'joined_at': '2026-05-01T12:00:00.000Z',
    'status': 'active',
    'users': {'username': 'luna'},
  };

  group('GroupMember', () {
    test('fromJson maps a group_members row with embedded users', () {
      final member = GroupMember.fromJson(fixture);
      expect(member.id, id);
      expect(member.groupId, fixture['group_id']);
      expect(member.userId, fixture['user_id']);
      expect(member.role, 'co_promotor');
      expect(member.joinedAt, DateTime.parse('2026-05-01T12:00:00.000Z'));
      expect(member.status, 'active');
      expect(member.username, 'luna');
    });

    test('fromJson applies role/status defaults', () {
      final member = GroupMember.fromJson({
        'id': id,
        'group_id': fixture['group_id'],
        'user_id': fixture['user_id'],
        'joined_at': '2026-05-01T12:00:00.000Z',
      });
      expect(member.role, 'member');
      expect(member.status, 'active');
      expect(member.username, isNull);
    });

    test('fromJson tolerates a missing users embed', () {
      final member = GroupMember.fromJson({
        'id': id,
        'group_id': fixture['group_id'],
        'user_id': fixture['user_id'],
        'role': 'member',
        'joined_at': '2026-05-01T12:00:00.000Z',
        'status': 'active',
      });
      expect(member.username, isNull);
    });

    test('username getter reads the embedded users.username', () {
      final member = GroupMember.fromJson(fixture);
      expect(member.username, 'luna');
      expect(
        GroupMember.fromJson({...fixture, 'users': null}).username,
        isNull,
      );
    });

    test('toJson emits snake_case DB column names and keeps the embed', () {
      final json = GroupMember.fromJson(fixture).toJson();
      expect(json['id'], id);
      expect(json['group_id'], fixture['group_id']);
      expect(json['user_id'], fixture['user_id']);
      expect(json['role'], 'co_promotor');
      expect(json['joined_at'], '2026-05-01T12:00:00.000Z');
      expect(json['status'], 'active');
      expect(json['users'], {'username': 'luna'});
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = GroupMember.fromJson(fixture);
      final roundtrip = GroupMember.fromJson(original.toJson());
      expect(roundtrip, original);
    });

    test('copyWith updates only the given field', () {
      final member = GroupMember.fromJson(fixture);
      final updated = member.copyWith(role: 'promotor');
      expect(updated.role, 'promotor');
      expect(updated.userId, fixture['user_id']);
      expect(updated.joinedAt, DateTime.parse('2026-05-01T12:00:00.000Z'));
    });

    test('equality compares all fields', () {
      expect(GroupMember.fromJson(fixture), GroupMember.fromJson(fixture));
      expect(
        GroupMember.fromJson(fixture).copyWith(status: 'invited'),
        isNot(GroupMember.fromJson(fixture)),
      );
    });
  });
}
