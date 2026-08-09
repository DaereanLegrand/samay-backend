import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/event.dart';

void main() {
  const id = 'e001e002-4003-4f04-8a05-6b07c08d09e0';
  final startsAt = '2026-09-15T22:00:00.000Z';
  final endsAt = '2026-09-16T04:00:00.000Z';

  final fixture = <String, dynamic>{
    'id': id,
    'name': 'Tono en Barranco',
    'type': 'tono',
    'status': 'upcoming',
    'starts_at': startsAt,
    'ends_at': endsAt,
    'group_id': null,
    'location_name': 'Barranco, Lima',
    'preshards_pool': 500,
  };

  group('Event', () {
    test('fromJson maps an events row', () {
      final event = Event.fromJson(fixture);
      expect(event.id, id);
      expect(event.name, 'Tono en Barranco');
      expect(event.type, 'tono');
      expect(event.status, 'upcoming');
      expect(event.startsAt, DateTime.parse(startsAt));
      expect(event.endsAt, DateTime.parse(endsAt));
      expect(event.groupId, isNull);
      expect(event.locationName, 'Barranco, Lima');
      expect(event.preshardsPool, 500);
    });

    test('fromJson applies preshards_pool default and nulls', () {
      final event = Event.fromJson({
        'id': id,
        'name': 'Juerga',
        'type': 'juerga',
        'status': 'draft',
        'starts_at': startsAt,
        'ends_at': endsAt,
      });
      expect(event.preshardsPool, 0);
      expect(event.groupId, isNull);
      expect(event.locationName, isNull);
    });

    test('fromJson parses date timestamps', () {
      final event = Event.fromJson(fixture);
      expect(event.startsAt, DateTime.parse('2026-09-15T22:00:00.000Z'));
      expect(event.endsAt, DateTime.parse('2026-09-16T04:00:00.000Z'));
    });

    test('toJson emits snake_case DB column names', () {
      final json = Event.fromJson(fixture).toJson();
      expect(json['id'], id);
      expect(json['name'], 'Tono en Barranco');
      expect(json['type'], 'tono');
      expect(json['status'], 'upcoming');
      expect(json['starts_at'], startsAt);
      expect(json['ends_at'], endsAt);
      expect(json['group_id'], isNull);
      expect(json['location_name'], 'Barranco, Lima');
      expect(json['preshards_pool'], 500);
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = Event.fromJson(fixture);
      expect(Event.fromJson(original.toJson()), original);
    });

    test('copyWith updates only the given field', () {
      final event = Event.fromJson(fixture);
      final updated = event.copyWith(status: 'live');
      expect(updated.status, 'live');
      expect(updated.name, 'Tono en Barranco');
      expect(updated.preshardsPool, 500);
    });

    test('copyWith can clear nullable fields', () {
      final event = Event.fromJson(fixture);
      expect(event.copyWith(locationName: null).locationName, isNull);
    });

    test('equality compares all fields', () {
      expect(Event.fromJson(fixture), Event.fromJson(fixture));
      expect(
        Event.fromJson(fixture).copyWith(preshardsPool: 999),
        isNot(Event.fromJson(fixture)),
      );
    });
  });
}
