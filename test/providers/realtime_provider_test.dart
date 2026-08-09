import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// RealtimeChannelProvider lifecycle tests (I-52, L-01/ARC-07): channel
/// creation through [RealtimeService], newRecord delivery, dispose safety
/// (unsubscribe + close), error surfacing as AsyncError, and reconnect with
/// exponential backoff ([backoffDelay] from `async_ops.dart`). All against a
/// fake [RealtimeService] — zero network, zero Supabase init.
const _channelName = 'messages:chat-1';
const _table = 'messages';

final _request = (
  channelName: _channelName,
  table: _table,
  event: PostgresChangeEvent.insert,
);

/// Records every channel the fake service created so tests can drive its
/// status callback and postgres callback, and assert unsubscribe.
class _ChannelHandle {
  _ChannelHandle({
    required this.channelName,
    required this.event,
    required this.table,
    required this.onInsert,
    required this.onStatus,
    required this.channel,
  });

  final String channelName;
  final PostgresChangeEvent event;
  final String table;

  /// The callback the provider wired for newRecord delivery.
  final void Function(Map<String, dynamic>) onInsert;

  /// The subscribe status callback the provider passed through.
  final void Function(RealtimeSubscribeStatus status, Object? error) onStatus;

  final RealtimeChannel channel;

  /// Captured from `onPostgresChanges` so tests can feed payloads.
  void Function(PostgresChangePayload)? onPostgresCallback;

  int unsubscribeCalls = 0;
}

/// Fake [RealtimeService]: creates a mocktail [RealtimeChannel] per
/// `subscribeToChannel` call and records a [_ChannelHandle]. The status
/// callback is captured directly from the call, the postgres callback from
/// the channel's `onPostgresChanges` invocation.
class _FakeRealtimeService extends RealtimeService {
  _FakeRealtimeService() : super(client: MockSupabaseClient());

  final List<_ChannelHandle> handles = [];
  int subscribeToChannelCalls = 0;

  @override
  RealtimeChannel subscribeToChannel(
    String channelName,
    PostgresChangeEvent event,
    String table,
    void Function(Map<String, dynamic>) callback, {
    void Function(RealtimeSubscribeStatus status, Object? error)? onStatus,
  }) {
    subscribeToChannelCalls++;
    final channel = MockRealtimeChannel();
    final handle = _ChannelHandle(
      channelName: channelName,
      event: event,
      table: table,
      onInsert: callback,
      onStatus: onStatus!,
      channel: channel,
    );
    handles.add(handle);
    // Concrete values for the enum/string args (mocktail cannot synthesize a
    // PostgresChangeEvent for `any(named: 'event')` matching); only the
    // callback is matched with `any`. The service mirrors the real
    // RealtimeService wiring: onPostgresChanges is invoked with the
    // newRecord-forwarding closure so the mocktail capture below records it.
    when(() => channel.onPostgresChanges(
          event: event,
          schema: 'public',
          table: table,
          callback: any(named: 'callback'),
        )).thenAnswer((invocation) {
      handle.onPostgresCallback = invocation.namedArguments[#callback]
          as void Function(PostgresChangePayload);
      return channel;
    });
    channel.onPostgresChanges(
      event: event,
      schema: 'public',
      table: table,
      callback: (payload) => callback(payload.newRecord),
    );
    when(() => channel.subscribe(any())).thenReturn(channel);
    when(() => channel.unsubscribe()).thenAnswer((_) async {
      handle.unsubscribeCalls++;
      return 'ok';
    });
    return channel;
  }
}

PostgresChangePayload _payload(Map<String, dynamic> newRecord) {
  return PostgresChangePayload(
    schema: 'public',
    table: _table,
    commitTimestamp: DateTime.now(),
    eventType: PostgresChangeEvent.insert,
    newRecord: newRecord,
    oldRecord: const {},
    errors: null,
  );
}

ProviderContainer _makeContainer(_FakeRealtimeService service,
    {int maxRetries = 3}) {
  final container = ProviderContainer(overrides: [
    realtimeServiceProvider.overrideWithValue(service),
    realtimeRetryConfigProvider.overrideWithValue(
      RealtimeRetryConfig(
        initialDelay: const Duration(milliseconds: 10),
        backoffFactor: 2,
        maxRetries: maxRetries,
        // Seeded → deterministic (sub-millisecond) backoff windows.
        jitter: Random(42),
      ),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('subscribes via the realtime service and emits newRecord rows',
      () async {
    final service = _FakeRealtimeService();
    final container = _makeContainer(service);
    final rows = <Map<String, dynamic>>[];
    final sub = container.listen(
        realtimeChannelProvider(_request), (_, next) {
      if (next is AsyncData) rows.add(next.requireValue);
    });
    addTearDown(sub.close);
    await container.pump();

    expect(service.subscribeToChannelCalls, 1);
    final handle = service.handles.single;
    expect(handle.channelName, _channelName);
    expect(handle.table, _table);
    expect(handle.event, PostgresChangeEvent.insert);
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.connecting);

    handle.onStatus(RealtimeSubscribeStatus.subscribed, null);
    await container.pump();
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.connected);

    handle.onPostgresCallback!(_payload({'id': 'm-1', 'content': 'hola'}));
    await container.pump();

    expect(rows, [
      {'id': 'm-1', 'content': 'hola'},
    ]);
    verify(() => handle.channel.onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: _table,
          callback: any(named: 'callback'),
        )).called(1);
  });

  test('onDispose unsubscribes the channel and closes the stream', () async {
    final service = _FakeRealtimeService();
    final container = _makeContainer(service);
    final sub = container.listen(
        realtimeChannelProvider(_request), (_, _) {});
    addTearDown(sub.close);
    await container.pump();

    final handle = service.handles.single;
    handle.onStatus(RealtimeSubscribeStatus.subscribed, null);
    await container.pump();

    container.dispose();
    await container.pump();

    expect(handle.unsubscribeCalls, 1);

    // A late postgres delivery after dispose must be a no-op (guarded in the
    // provider), never a throw into the channel callback.
    handle.onPostgresCallback!(_payload({'id': 'late'}));
    await container.pump();
    expect(handle.unsubscribeCalls, 1);
  });

  test('disposing during the backoff window cancels the reconnect', () async {
    final service = _FakeRealtimeService();
    final container = _makeContainer(service);
    final sub = container.listen(
        realtimeChannelProvider(_request), (_, _) {});
    addTearDown(sub.close);
    await container.pump();

    service.handles.single
        .onStatus(RealtimeSubscribeStatus.channelError, Exception('boom'));
    await container.pump();
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.reconnecting);

    container.dispose();
    // Longer than the seeded backoff window: no reconnect may fire.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(service.subscribeToChannelCalls, 1);
    expect(service.handles.single.unsubscribeCalls, 1);
  });

  test('channelError surfaces as AsyncError and the stream continues after '
      'the backoff retry succeeds', () async {
    final service = _FakeRealtimeService();
    final container = _makeContainer(service);
    final rows = <Map<String, dynamic>>[];
    final errors = <Object>[];
    final sub = container.listen(
        realtimeChannelProvider(_request), (_, next) {
      if (next is AsyncData) rows.add(next.requireValue);
      if (next.hasError) errors.add(next.error!);
    });
    addTearDown(sub.close);
    await container.pump();

    final first = service.handles.single;
    first.onStatus(RealtimeSubscribeStatus.subscribed, null);
    await container.pump();
    first.onPostgresCallback!(_payload({'id': 'm-1'}));
    await container.pump();
    expect(rows, [{'id': 'm-1'}]);

    // The channel fails once: error surfaces, reconnect scheduled with
    // backoff, and a FRESH channel is subscribed (the SDK forbids calling
    // subscribe twice on one channel instance).
    first.onStatus(RealtimeSubscribeStatus.channelError, Exception('boom'));
    await container.pump();
    expect(errors, isNotEmpty);
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.reconnecting);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await container.pump();

    expect(service.subscribeToChannelCalls, 2);
    expect(first.unsubscribeCalls, 1, reason: 'failed channel is torn down');
    final second = service.handles.last;
    expect(second, isNot(same(first)));

    second.onStatus(RealtimeSubscribeStatus.subscribed, null);
    await container.pump();
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.connected);

    second.onPostgresCallback!(_payload({'id': 'm-2'}));
    await container.pump();
    expect(rows, [
      {'id': 'm-1'},
      {'id': 'm-2'},
    ]);
  });

  test('gives up after maxRetries and tears the channel down', () async {
    final service = _FakeRealtimeService();
    final container = _makeContainer(service, maxRetries: 1);
    final sub = container.listen(
        realtimeChannelProvider(_request), (_, _) {});
    addTearDown(sub.close);
    await container.pump();

    service.handles.single
        .onStatus(RealtimeSubscribeStatus.channelError, Exception('boom 1'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await container.pump();

    // One retry happened.
    expect(service.subscribeToChannelCalls, 2);
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.reconnecting);

    service.handles.last
        .onStatus(RealtimeSubscribeStatus.channelError, Exception('boom 2'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await container.pump();

    // Retry budget exhausted: no third channel, terminal error status.
    expect(service.subscribeToChannelCalls, 2);
    expect(service.handles.last.unsubscribeCalls, 1);
    expect(container.read(realtimeStatusProvider(_channelName)),
        RealtimeStatus.error);
  });
}
