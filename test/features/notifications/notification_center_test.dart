import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/core/services/rest_client.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/notifications/notification_center_screen.dart';
import 'package:samay/features/notifications/notifications_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Notification center tests (I-53, NOTI): provider list/refresh/markRead
/// against a fake [NotificationService] injected via
/// [notificationServiceProvider], derived unread count, pure deep-link and
/// relative-time helpers, and the screen's render / empty / tap / realtime /
/// mark-all-read behaviors.
class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

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
  final List<void Function(Map<String, dynamic>)> onInserts = [];
  _MockRealtimeChannel? _channel;

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
  ) async {
    onInserts.add(onInsert);
    final channel = _channel ??= _MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
    return channel;
  }
}

ProviderContainer _container(_FakeNotificationService service) {
  final container = ProviderContainer(overrides: [
    notificationServiceProvider.overrideWithValue(service),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester,
  _FakeNotificationService service, {
  GoRouter? router,
}) async {
  final container = _container(service);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router == null
          ? MaterialApp(
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const NotificationCenterScreen(),
            )
          : MaterialApp.router(
              routerConfig: router,
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
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
      final fake = _FakeNotificationService(
        [_row('n-1')],
        error: Exception('boom'),
      );
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
      final span = notificationTimeSpan(now.subtract(const Duration(seconds: 30)), now);
      expect(span.age, NotificationAge.now);
    });

    test('buckets future timestamps as now (clock skew)', () {
      final span = notificationTimeSpan(now.add(const Duration(minutes: 2)), now);
      expect(span.age, NotificationAge.now);
    });

    test('buckets minutes under an hour', () {
      final span = notificationTimeSpan(now.subtract(const Duration(minutes: 5)), now);
      expect(span.age, NotificationAge.minutes);
      expect(span.value, 5);
    });

    test('buckets hours under a day', () {
      final span = notificationTimeSpan(now.subtract(const Duration(hours: 3)), now);
      expect(span.age, NotificationAge.hours);
      expect(span.value, 3);
    });

    test('buckets days beyond', () {
      final span = notificationTimeSpan(now.subtract(const Duration(days: 2)), now);
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
      expect(
        notificationDeepLink('qr_active', {'event_id': 'e1'}),
        '/qr/e1',
      );
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

    test('maps chat_message to the chat route', () {
      expect(
        notificationDeepLink('chat_message', {'chat_id': 'c1'}),
        '/chat/c1',
      );
    });

    test('returns null without data or ids', () {
      expect(notificationDeepLink('event_invite', null), isNull);
      expect(notificationDeepLink('event_invite', const {}), isNull);
      expect(notificationDeepLink('event_invite', const {'foo': 'bar'}), isNull);
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

  group('NotificationCenterScreen', () {
    testWidgets('renders items with icon, title, body and relative time',
        (tester) async {
      final fiveMinutesAgo =
          DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      final service = _FakeNotificationService([
        _row(
          'n-1',
          title: 'Invitación a evento',
          body: 'Ana te invitó a Fiesta',
          createdAt: fiveMinutesAgo,
        ),
        _row(
          'n-2',
          type: 'qr_active',
          title: 'QR de asistencia activo',
          body: 'Tu QR para Fiesta ya está disponible',
          read: true,
        ),
      ]);
      await _pumpScreen(tester, service);

      expect(find.text('Notificaciones'), findsOneWidget);
      expect(find.text('Invitación a evento'), findsOneWidget);
      expect(find.text('Ana te invitó a Fiesta'), findsOneWidget);
      expect(find.text('QR de asistencia activo'), findsOneWidget);
      expect(find.text('hace 5 min'), findsOneWidget);
      expect(find.text('Ahora'), findsOneWidget);
      expect(find.byIcon(Icons.event), findsOneWidget);
      expect(find.byIcon(Icons.qr_code), findsOneWidget);
    });

    testWidgets('shows the empty state', (tester) async {
      await _pumpScreen(tester, _FakeNotificationService([]));

      expect(find.text('Sin notificaciones'), findsOneWidget);
      expect(find.text('Cuando recibas novedades, aparecerán aquí.'),
          findsOneWidget);
    });

    testWidgets('shows the unread dot only on unread items', (tester) async {
      final service = _FakeNotificationService([
        _row('n-1'),
        _row('n-2', read: true),
      ]);
      await _pumpScreen(tester, service);

      expect(find.byKey(const ValueKey('unread-dot-n-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('unread-dot-n-2')), findsNothing);
    });

    testWidgets('tapping a notification without a deep link marks it read',
        (tester) async {
      final service = _FakeNotificationService([_row('n-1', data: null)]);
      await _pumpScreen(tester, service);

      await tester.tap(find.text('Invitación a evento'));
      await tester.pumpAndSettle();

      expect(service.markedRead, ['n-1']);
      expect(find.byKey(const ValueKey('unread-dot-n-1')), findsNothing);
    });

    testWidgets('tapping a notification with a registered deep link navigates',
        (tester) async {
      final service = _FakeNotificationService([
        _row('n-1', type: 'event_invite', data: {'event_id': 'e1'}),
      ]);
      final router = GoRouter(
        initialLocation: RoutePaths.mainNotifications,
        routes: [
          GoRoute(
            path: RoutePaths.mainNotifications,
            builder: (_, _) => const NotificationCenterScreen(),
          ),
          GoRoute(
            path: RoutePaths.eventDetail('e1'),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('EVENT STUB'))),
          ),
        ],
      );
      await _pumpScreen(tester, service, router: router);

      await tester.tap(find.text('Invitación a evento'));
      await tester.pumpAndSettle();

      expect(find.text('EVENT STUB'), findsOneWidget);
      expect(service.markedRead, ['n-1']);
    });

    testWidgets('a realtime insert appends the new notification',
        (tester) async {
      final service = _FakeNotificationService([_row('n-1', data: null)]);
      await _pumpScreen(tester, service);
      expect(find.text('Invitación a evento'), findsOneWidget);

      service.onInserts.single(
        _row('n-live', type: 'shard_received', title: 'Shards recibidos'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Shards recibidos'), findsOneWidget);
      expect(find.byKey(const ValueKey('unread-dot-n-live')), findsOneWidget);
    });

    testWidgets('mark-all-read clears every unread dot', (tester) async {
      final service = _FakeNotificationService([
        _row('n-1', data: null),
        _row('n-2', data: null),
      ]);
      await _pumpScreen(tester, service);
      expect(find.text('Marcar todo como leído'), findsOneWidget);

      await tester.tap(find.text('Marcar todo como leído'));
      await tester.pumpAndSettle();

      expect(service.markedRead.toSet(), {'n-1', 'n-2'});
      expect(find.byKey(const ValueKey('unread-dot-n-1')), findsNothing);
      expect(find.byKey(const ValueKey('unread-dot-n-2')), findsNothing);
      expect(find.text('Marcar todo como leído'), findsNothing);
    });
  });
}
