import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/core/services/rest_client.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/notifications/providers/notifications_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Notification center functional tests (I-53, NOTI): provider list/refresh/
/// markRead against a fake [NotificationService] injected via
/// [notificationServiceProvider], derived unread count, and the pure deep-link
/// and relative-time helpers.
Map<String, dynamic> _row(
  String id, {
  String type = 'event_invite',
  String title = 'Invitación a evento',
  String body = 'Ana te invitó a Fiesta',
  Map<String, dynamic>? data,
  bool read = false,
  DateTime? createdAt,
}) {
  return {
    'id': id,
    'type': type,
    'title': title,
    'body': body,
    'data': data,
    'read': read,
    'created_at': (createdAt ?? DateTime.now().toUtc()).toIso8601String(),
  };
}

/// Fake service standing in for [notificationServiceProvider]: in-memory
/// rows, a record of marked ids, and captured realtime insert callbacks.
class _FakeNotificationService implements NotificationService {
  _FakeNotificationService(this.rows, {this.error});

  final List<Map<String, dynamic>> rows;
  final Object? error;
  final List<String> markedRead = [];

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  RestClient get rest => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getNotifications() async {
    if (error != null) throw error!;
    return List.of(rows);
  }

  @override
  Future<void> markNotificationRead(String id) async {
    markedRead.add(id);
    for (final row in rows) {
      if (row['id'] == id) row['read'] = true;
    }
  }

  @override
  Future<RealtimeChannel> subscribeToNotifications(
    void Function(Map<String, dynamic>) onInsert,
  ) async =>
      throw UnimplementedError();
}

ProviderContainer _container(_FakeNotificationService service) {
  final container = ProviderContainer(
    overrides: [notificationServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('NotificationsNotifier', () {
    test('build maps service rows to NotificationItem models', () async {
      final fake = _FakeNotificationService([
        _row('n-1'),
        _row('n-2', read: true),
      ]);
      final container = _container(fake);

      final items = await container.read(notificationsProvider.future);

      expect(items, hasLength(2));
      expect(items[0].id, 'n-1');
      expect(items[0].read, isFalse);
      expect(items[0].data, isNull);
      expect(items[1].read, isTrue);
      expect(items[0].createdAt, isA<DateTime>());
    });

    test('refresh reloads from the service', () async {
      final fake = _FakeNotificationService([_row('n-1')]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);

      fake.rows.add(_row('n-2'));
      await container.read(notificationsProvider.notifier).refresh();

      final items = await container.read(notificationsProvider.future);
      expect(items, hasLength(2));
      expect(items.map((n) => n.id), contains('n-2'));
    });

    test('markRead calls the service and flips the local item', () async {
      final fake = _FakeNotificationService([
        _row('n-1'),
        _row('n-2', read: true),
      ]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);

      await container.read(notificationsProvider.notifier).markRead('n-1');

      expect(fake.markedRead, ['n-1']);
      final items = container.read(notificationsProvider).valueOrNull!;
      expect(items.every((n) => n.read), isTrue);
    });

    test('markRead skips already-read items', () async {
      final fake = _FakeNotificationService([_row('n-2', read: true)]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);

      await container.read(notificationsProvider.notifier).markRead('n-2');

      expect(fake.markedRead, isEmpty);
    });

    test('markAllRead marks every unread item', () async {
      final fake = _FakeNotificationService([
        _row('n-1'),
        _row('n-2'),
        _row('n-3', read: true),
      ]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);

      await container.read(notificationsProvider.notifier).markAllRead();

      expect(fake.markedRead.toSet(), {'n-1', 'n-2'});
      final items = container.read(notificationsProvider).valueOrNull!;
      expect(items.every((n) => n.read), isTrue);
    });

    test('addNotification prepends realtime rows and dedupes by id', () async {
      final fake = _FakeNotificationService([_row('n-1')]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);
      final notifier = container.read(notificationsProvider.notifier);

      notifier.addNotification(_row('n-live', type: 'chat_message'));
      final items = container.read(notificationsProvider).valueOrNull!;
      expect(items.first.id, 'n-live');
      final count = items.length;

      notifier.addNotification(_row('n-live'));
      expect(container.read(notificationsProvider).valueOrNull!.length, count);
    });

    test('surfaces AsyncError when the service fails', () async {
      final fake = _FakeNotificationService([
        _row('n-1'),
      ], error: Exception('boom'));
      final container = _container(fake);

      await expectLater(
        container.read(notificationsProvider.future),
        throwsException,
      );
      expect(container.read(notificationsProvider), isA<AsyncError>());
      expect(container.read(unreadCountProvider), 0);
    });
  });

  group('unreadCountProvider', () {
    test('counts only unread notifications', () async {
      final fake = _FakeNotificationService([
        _row('n-1'),
        _row('n-2', read: true),
      ]);
      final container = _container(fake);
      await container.read(notificationsProvider.future);

      expect(container.read(unreadCountProvider), 1);

      await container.read(notificationsProvider.notifier).markRead('n-1');
      expect(container.read(unreadCountProvider), 0);
    });
  });

  group('notificationTimeSpan', () {
    final now = DateTime(2026, 8, 9, 12, 0, 0);

    test('buckets sub-minute deltas as now', () {
      final span = notificationTimeSpan(
        now.subtract(const Duration(seconds: 30)),
        now,
      );
      expect(span.age, NotificationAge.now);
    });

    test('buckets future timestamps as now (clock skew)', () {
      final span = notificationTimeSpan(
        now.add(const Duration(minutes: 2)),
        now,
      );
      expect(span.age, NotificationAge.now);
    });

    test('buckets minutes under an hour', () {
      final span = notificationTimeSpan(
        now.subtract(const Duration(minutes: 5)),
        now,
      );
      expect(span.age, NotificationAge.minutes);
      expect(span.value, 5);
    });

    test('buckets hours under a day', () {
      final span = notificationTimeSpan(
        now.subtract(const Duration(hours: 3)),
        now,
      );
      expect(span.age, NotificationAge.hours);
      expect(span.value, 3);
    });

    test('buckets days beyond', () {
      final span = notificationTimeSpan(
        now.subtract(const Duration(days: 2)),
        now,
      );
      expect(span.age, NotificationAge.days);
      expect(span.value, 2);
    });
  });

  group('notificationDeepLink', () {
    test('an explicit deepLink wins', () {
      expect(
        notificationDeepLink('event_invite', {'deepLink': '/settings'}),
        '/settings',
      );
    });

    test('maps event types to the event detail route', () {
      expect(
        notificationDeepLink('event_invite', {'event_id': 'e1'}),
        '/event/e1',
      );
      expect(
        notificationDeepLink('attendance_confirmed', {'eventId': 'e1'}),
        '/event/e1',
      );
    });

    test('maps qr_active to the QR route', () {
      expect(notificationDeepLink('qr_active', {'event_id': 'e1'}), '/qr/e1');
    });

    test('maps friend_request to the public profile route', () {
      expect(
        notificationDeepLink('friend_request', {'user_id': 'u1'}),
        '/user/u1',
      );
    });

    test('maps group types to the group detail route', () {
      for (final type in ['rank_update', 'minigame_invite', 'poke_received']) {
        expect(
          notificationDeepLink(type, {'group_id': 'g1'}),
          '/group/g1',
          reason: type,
        );
      }
    });

    test('minigame_invite with a session id lands on the session detail '
        '(140_minigame_invites)', () {
      expect(
        notificationDeepLink('minigame_invite', {
          'groupId': 'g1',
          'sessionId': 's1',
        }),
        '/minigames/session/s1',
      );
      expect(
        notificationDeepLink('minigame_invite', {'session_id': 's2'}),
        '/minigames/session/s2',
      );
      // Without a session id it falls back to the group detail.
      expect(
        notificationDeepLink('minigame_invite', {'groupId': 'g1'}),
        '/group/g1',
      );
    });

    test('minigame session deep links are registered routes', () {
      expect(isRegisteredRoutePath('/minigames/session/s1'), isTrue);
      // 150_minigame_play: the Verdad o Reto play route is a registered
      // deep-link target (4 segments: minigames/play/truth-dare/:id).
      expect(isRegisteredRoutePath('/minigames/play/truth-dare/s1'), isTrue);
    });

    test('maps chat_message to the chat route', () {
      expect(
        notificationDeepLink('chat_message', {'chat_id': 'c1'}),
        '/chat/c1',
      );
    });

    test('returns null without data or ids', () {
      expect(notificationDeepLink('event_invite', null), isNull);
      expect(notificationDeepLink('event_invite', const {}), isNull);
      expect(
        notificationDeepLink('event_invite', const {'foo': 'bar'}),
        isNull,
      );
    });
  });

  group('isRegisteredRoutePath', () {
    test('accepts registered routes', () {
      for (final path in [
        '/event/e1',
        '/group/g1',
        '/chat/c1',
        '/user/u1',
        '/qr/e1',
        RoutePaths.mainNotifications,
        RoutePaths.mainFeed,
        RoutePaths.settings,
        '/event/e1/photos',
      ]) {
        expect(isRegisteredRoutePath(path), isTrue, reason: path);
      }
    });

    test('rejects unknown and malformed routes', () {
      for (final path in [
        '/event',
        '/user/u1/friend',
        '/unknown',
        '/notifications/x',
      ]) {
        expect(isRegisteredRoutePath(path), isFalse, reason: path);
      }
    });
  });

}
