
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// NotificationService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// history listing (user-scoped, newest first, capped), read-state marking,
/// realtime delegation, and error propagation.
const _userId = '11111111-1111-1111-1111-111111111111';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  setUpAll(() {
    // mocktail cannot synthesize enum values for `any(named: 'event')`.
    registerFallbackValue(PostgresChangeEvent.insert);
  });

  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  NotificationService service() =>
      NotificationService(client: client, realtime: RealtimeService(client: client));

  group('NotificationService.getNotifications', () {
    test('returns the mapped rows for the current user', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final notifications = MockQueryBuilder();
      when(() => client.from('notifications'))
          .thenAnswer((_) => notifications);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'n-1',
          'type': 'event',
          'title': 'Tu evento empieza',
          'body': 'Fiesta de prueba',
          'data': <String, dynamic>{'event_id': 'e-1'},
          'read': false,
          'created_at': '2026-08-01T00:00:00Z',
        },
      ]);
      when(() => notifications.select(any())).thenAnswer((_) => rows);

      final result = await service().getNotifications();

      expect(result, hasLength(1));
      expect(result.single['title'], 'Tu evento empieza');
      expect(result.single['read'], isFalse);
      expect(rows.filters, contains(
        const RecordedFilter('user_id', _userId),
      ));
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().getNotifications(), throwsA(isA<Exception>()));
      verifyNever(() => client.from('notifications'));
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final notifications = MockQueryBuilder();
      when(() => client.from('notifications'))
          .thenAnswer((_) => notifications);
      when(() => notifications.select(any())).thenThrow(
        const PostgrestException(
          message: 'permission denied for table notifications',
          code: '42501',
        ),
      );

      final err = await captureError(() => service().getNotifications());
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('NotificationService.markNotificationRead', () {
    test('updates the read flag scoped to the notification id', () async {
      final notifications = MockQueryBuilder();
      when(() => client.from('notifications'))
          .thenAnswer((_) => notifications);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => notifications.update(any())).thenAnswer((_) => update);

      await service().markNotificationRead('n-1');

      verify(() => notifications.update({'read': true})).called(1);
      expect(update.filters.single.value, 'n-1');
    });

    test('propagates a server PostgrestException', () async {
      final notifications = MockQueryBuilder();
      when(() => client.from('notifications'))
          .thenAnswer((_) => notifications);
      when(() => notifications.update(any())).thenThrow(
        const PostgrestException(
          message: 'database error',
          code: 'P0001',
        ),
      );

      final err =
          await captureError(() => service().markNotificationRead('n-1'));
      expect(err, isA<PostgrestException>());
      expectMapped(err, ServerError);
    });
  });

  group('NotificationService.subscribeToNotifications', () {
    test('delegates to the realtime service user channel', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final channel = MockRealtimeChannel();
      when(() => client.channel('notifications:$_userId'))
          .thenReturn(channel);
      when(() => channel.onPostgresChanges(
            event: any(named: 'event'),
            schema: any(named: 'schema'),
            table: any(named: 'table'),
            callback: any(named: 'callback'),
          )).thenReturn(channel);
      when(() => channel.subscribe()).thenReturn(channel);

      await service().subscribeToNotifications((_) {});

      verify(() => client.channel('notifications:$_userId')).called(1);
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'notifications',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe()).called(1);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().subscribeToNotifications((_) {}),
          throwsA(isA<Exception>()));
    });
  });
}
