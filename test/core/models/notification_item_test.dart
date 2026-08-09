import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/notification_item.dart';

void main() {
  const id = 'n001e002-4003-4f04-8a05-6b07c08d09e0';
  final createdAt = '2026-08-02T09:00:00.000Z';

  final fixture = <String, dynamic>{
    'id': id,
    'type': 'friend_request',
    'title': 'Nueva solicitud',
    'body': 'luna quiere ser tu amiga',
    'data': {'user_id': '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60'},
    'read': false,
    'created_at': createdAt,
  };

  group('NotificationItem', () {
    test('fromJson maps a notifications row', () {
      final notification = NotificationItem.fromJson(fixture);
      expect(notification.id, id);
      expect(notification.type, 'friend_request');
      expect(notification.title, 'Nueva solicitud');
      expect(notification.body, 'luna quiere ser tu amiga');
      expect(
        notification.data,
        {'user_id': '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60'},
      );
      expect(notification.read, isFalse);
      expect(notification.createdAt, DateTime.parse(createdAt));
    });

    test('fromJson applies read default and handles null data', () {
      final notification = NotificationItem.fromJson({
        'id': id,
        'type': 'event',
        'title': 'Empieza pronto',
        'body': 'Tu evento comienza en 30 min',
        'created_at': createdAt,
      });
      expect(notification.read, isFalse);
      expect(notification.data, isNull);
    });

    test('toJson emits snake_case DB column names', () {
      final json = NotificationItem.fromJson(fixture).toJson();
      expect(json['id'], id);
      expect(json['type'], 'friend_request');
      expect(json['title'], 'Nueva solicitud');
      expect(json['body'], fixture['body']);
      expect(json['data'], fixture['data']);
      expect(json['read'], isFalse);
      expect(json['created_at'], createdAt);
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = NotificationItem.fromJson(fixture);
      final roundtrip = NotificationItem.fromJson(original.toJson());
      expect(roundtrip, original);
    });

    test('copyWith updates only the given field', () {
      final notification = NotificationItem.fromJson(fixture);
      final updated = notification.copyWith(read: true);
      expect(updated.read, isTrue);
      expect(updated.type, 'friend_request');
      expect(updated.createdAt, DateTime.parse(createdAt));
    });

    test('equality compares all fields', () {
      expect(
        NotificationItem.fromJson(fixture),
        NotificationItem.fromJson(fixture),
      );
      expect(
        NotificationItem.fromJson(fixture).copyWith(read: true),
        isNot(NotificationItem.fromJson(fixture)),
      );
    });
  });
}
