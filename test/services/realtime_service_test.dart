import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// RealtimeService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18).
///
/// The full reconnect/backoff lifecycle is I-52's scope
/// (`lib/core/providers/realtime_provider.dart`); this file pins the
/// subscription contract this service owns: channel naming, event/table
/// wiring, callback payload extraction and subscribe() invocation — all
/// against a mocktail [RealtimeChannel], so zero network I/O.
const _userId = '11111111-1111-1111-1111-111111111111';
const _eventId = '66666666-6666-6666-6666-666666666666';

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

  RealtimeService service() => RealtimeService(client: client);

  /// Stubs a channel for [name] and captures the postgres-changes callback so
  /// tests can feed it payloads (the channel is a mock — realtime never runs).
  MockRealtimeChannel stubChannel(String name,
      {required void Function(void Function(PostgresChangePayload)) onCallback}) {
    final channel = MockRealtimeChannel();
    when(() => client.channel(name)).thenReturn(channel);
    when(() => channel.onPostgresChanges(
          event: any(named: 'event'),
          schema: any(named: 'schema'),
          table: any(named: 'table'),
          callback: any(named: 'callback'),
        )).thenAnswer((invocation) {
      onCallback(invocation.namedArguments[#callback]
          as void Function(PostgresChangePayload));
      return channel;
    });
    when(() => channel.subscribe()).thenReturn(channel);
    return channel;
  }

  group('RealtimeService.subscribeToMessages', () {
    test('subscribes to the messages channel for the chat', () async {
      final channel = stubChannel('messages:chat-1', onCallback: (_) {});

      // Sync by design (I-38): returns the channel for caller unsubscribe.
      final returned = service().subscribeToMessages('chat-1', (_) {});

      expect(returned, same(channel));
      verify(() => client.channel('messages:chat-1')).called(1);
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe()).called(1);
    });
  });

  group('RealtimeService.subscribeToNotifications', () {
    test('subscribes to the per-user notifications channel', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final channel =
          stubChannel('notifications:$_userId', onCallback: (_) {});

      await service().subscribeToNotifications((_) {});

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

  group('RealtimeService.subscribeToEventStatus', () {
    test('forwards the new status from the events payload', () async {
      late void Function(PostgresChangePayload) callback;
      final channel = stubChannel('event-status:$_eventId',
          onCallback: (cb) => callback = cb);

      final received = <String>[];
      await service().subscribeToEventStatus(_eventId, received.add);

      // Feed the callback a postgres update payload (mocktail captured it).
      callback(PostgresChangePayload(
        schema: 'public',
        table: 'events',
        commitTimestamp: DateTime.now(),
        eventType: PostgresChangeEvent.update,
        newRecord: {'status': 'live'},
        oldRecord: const {},
        errors: null,
      ));

      expect(received, ['live']);
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'events',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe()).called(1);
    });

    test('ignores updates without a status field', () async {
      late void Function(PostgresChangePayload) callback;
      stubChannel('event-status:$_eventId', onCallback: (cb) => callback = cb);

      final received = <String>[];
      await service().subscribeToEventStatus(_eventId, received.add);

      callback(PostgresChangePayload(
        schema: 'public',
        table: 'events',
        commitTimestamp: DateTime.now(),
        eventType: PostgresChangeEvent.update,
        newRecord: {'name': 'renombrado'},
        oldRecord: const {},
        errors: null,
      ));

      expect(received, isEmpty);
    });
  });

  group('RealtimeService.subscribeToQRToken', () {
    test('forwards the token from the QR payload', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      late void Function(PostgresChangePayload) callback;
      final channel = stubChannel('qr-token:$_eventId:$_userId',
          onCallback: (cb) => callback = cb);

      final received = <String>[];
      await service().subscribeToQRToken(_eventId, received.add);

      callback(PostgresChangePayload(
        schema: 'public',
        table: 'event_qr_tokens',
        commitTimestamp: DateTime.now(),
        eventType: PostgresChangeEvent.update,
        newRecord: {'token': 'tok-123'},
        oldRecord: const {},
        errors: null,
      ));

      expect(received, ['tok-123']);
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'event_qr_tokens',
            callback: any(named: 'callback'),
          )).called(1);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().subscribeToQRToken(_eventId, (_) {}),
          throwsA(isA<Exception>()));
    });
  });

  group('RealtimeService.subscribeToChannel', () {
    /// The I-52 lifecycle seam: the optional [onStatus] callback is wired
    /// into `channel.subscribe` so the realtime provider can track
    /// connection state and drive reconnect backoff.
    test('passes the status callback to channel.subscribe', () {
      late void Function(RealtimeSubscribeStatus, Object?) statusCallback;
      final channel = MockRealtimeChannel();
      when(() => client.channel('messages:chat-1')).thenReturn(channel);
      when(() => channel.onPostgresChanges(
            event: any(named: 'event'),
            schema: any(named: 'schema'),
            table: any(named: 'table'),
            callback: any(named: 'callback'),
          )).thenReturn(channel);
      when(() => channel.subscribe(any())).thenAnswer((invocation) {
        statusCallback = invocation.positionalArguments[0]
            as void Function(RealtimeSubscribeStatus, Object?);
        return channel;
      });

      final reported = <RealtimeSubscribeStatus>[];
      final returned = service().subscribeToChannel(
        'messages:chat-1',
        PostgresChangeEvent.insert,
        'messages',
        (_) {},
        onStatus: (status, _) => reported.add(status),
      );

      expect(returned, same(channel));
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe(any())).called(1);

      // The captured callback is the provider's own — drive it and observe
      // the passthrough.
      expect(statusCallback, isNotNull);
      statusCallback(RealtimeSubscribeStatus.subscribed, null);
      statusCallback(RealtimeSubscribeStatus.channelError, Exception('x'));
      expect(reported, [
        RealtimeSubscribeStatus.subscribed,
        RealtimeSubscribeStatus.channelError,
      ]);
    });

    test('omits the status callback for plain subscriptions', () {
      final channel = MockRealtimeChannel();
      when(() => client.channel('messages:chat-1')).thenReturn(channel);
      when(() => channel.onPostgresChanges(
            event: any(named: 'event'),
            schema: any(named: 'schema'),
            table: any(named: 'table'),
            callback: any(named: 'callback'),
          )).thenReturn(channel);
      when(() => channel.subscribe()).thenReturn(channel);

      final returned = service().subscribeToChannel(
        'messages:chat-1',
        PostgresChangeEvent.insert,
        'messages',
        (_) {},
      );

      expect(returned, same(channel));
      verify(() => channel.subscribe()).called(1);
    });
  });
}
