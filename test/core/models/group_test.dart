import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group.dart';

void main() {
  const id = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
  final fixture = <String, dynamic>{
    'id': id,
    'name': 'Crew Lima Norte',
    'description': 'Salidas cada finde',
    'cover_url': 'https://cdn.example.test/covers/crew.png',
    'created_by_user_id': '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60',
    'group_shards': 1500,
    'size_tier': 'small',
    'rank_bracket': 'b20_40',
    'frozen_at': null,
    'created_at': '2026-05-01T12:00:00.000Z',
    'updated_at': '2026-05-01T12:00:00.000Z',
  };

  group('Group', () {
    test('fromJson maps a Supabase groups row', () {
      final group = Group.fromJson(fixture);
      expect(group.id, id);
      expect(group.name, 'Crew Lima Norte');
      expect(group.description, 'Salidas cada finde');
      expect(group.coverUrl, 'https://cdn.example.test/covers/crew.png');
      expect(group.groupShards, 1500);
      expect(group.sizeTier, 'small');
      expect(group.rankBracket, 'b20_40');
      expect(group.frozenAt, isNull);
      expect(group.myRole, isNull);
    });

    test('fromJson applies group_shards default', () {
      final group = Group.fromJson({'id': id, 'name': 'Grupo'});
      expect(group.groupShards, 0);
    });

    test('fromJson reads injected my_role from getMyGroups', () {
      final group = Group.fromJson({...fixture, 'my_role': 'promotor'});
      expect(group.myRole, 'promotor');
    });

    test('fromJson parses frozen_at timestamps', () {
      final group = Group.fromJson({
        ...fixture,
        'frozen_at': '2026-07-20T00:00:00.000Z',
      });
      expect(group.frozenAt, DateTime.parse('2026-07-20T00:00:00.000Z'));
    });

    test('toJson emits snake_case DB column names', () {
      final json = Group.fromJson({...fixture, 'my_role': 'member'}).toJson();
      expect(json['id'], id);
      expect(json['name'], 'Crew Lima Norte');
      expect(json['description'], fixture['description']);
      expect(json['cover_url'], fixture['cover_url']);
      expect(json['group_shards'], 1500);
      expect(json['size_tier'], 'small');
      expect(json['rank_bracket'], 'b20_40');
      expect(json['my_role'], 'member');
      expect(json.containsKey('frozen_at'), isTrue);
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = Group.fromJson({...fixture, 'my_role': 'co_promotor'});
      expect(Group.fromJson(original.toJson()), original);
    });

    test('copyWith updates only the given field', () {
      final group = Group.fromJson(fixture);
      final updated = group.copyWith(name: 'Crew Sur');
      expect(updated.name, 'Crew Sur');
      expect(updated.groupShards, 1500);
      expect(updated.rankBracket, 'b20_40');
    });

    test('copyWith can clear nullable fields', () {
      final group = Group.fromJson(fixture);
      expect(group.copyWith(coverUrl: null).coverUrl, isNull);
    });

    test('equality compares all fields', () {
      expect(Group.fromJson(fixture), Group.fromJson(fixture));
      expect(
        Group.fromJson(fixture).copyWith(sizeTier: 'large'),
        isNot(Group.fromJson(fixture)),
      );
    });
  });
}
