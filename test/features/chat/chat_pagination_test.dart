import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

/// Chat pagination behavioral tests (I-56, CHAT spec: "load last 50 on open,
/// paginate older history on demand").
///
/// The provider is exercised through the REAL `ChatRepository` (I-50) so the
/// E2EE invariant holds: every message path goes through the injected
/// [ChatService] — the provider must never touch the raw Supabase client
/// (pinned below with `verifyNever` on `client.from`).
const _chatId = '33333333-3333-3333-3333-333333333333';
const _otherId = '22222222-2222-2222-2222-222222222222';

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockGoTrueClient extends Mock implements GoTrueClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

Map<String, dynamic> _message(String id) => {
      'id': id,
      'sender_id': _otherId,
      'content': 'contenido $id',
      'media_url': null,
      'created_at': '2026-08-01T00:00:00Z',
    };

/// [count] rows whose ids are `m-<n>` for the window starting at [start]
/// (chronological, oldest first — the service contract the mock replaces).
List<Map<String, dynamic>> _page(int start, int count) =>
    [for (var i = start + count - 1; i >= start; i--) _message('m-$i')];

void main() {
  late _MockChatService service;
  late _MockRealtimeService realtime;
  late ChatRepository repo;
  late _MockSupabaseClient client;
  late _MockGoTrueClient auth;

  late List<int> requestedOffsets;

  /// Stubs the mock service to resolve each page from [pageFor] — invoked
  /// with the offset the provider actually requested.
  void seedService(
    List<Map<String, dynamic>> Function(int offset, int limit) pageFor,
  ) {
    when(
      () => service.loadMessages(
        _chatId,
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((inv) async {
      final offset = inv.namedArguments[#offset] as int;
      final limit = inv.namedArguments[#limit] as int;
      requestedOffsets.add(offset);
      return pageFor(offset, limit);
    });
  }

  setUp(() {
    service = _MockChatService();
    realtime = _MockRealtimeService();
    repo = ChatRepository(chat: service, realtime: realtime);
    client = _MockSupabaseClient();
    auth = _MockGoTrueClient();
    requestedOffsets = <int>[];
    when(() => service.client).thenReturn(client);
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenReturn(
      User.fromJson({'id': '11111111-1111-1111-1111-111111111111'}),
    );
  });

  ProviderContainer container() => ProviderContainer(overrides: [
        chatE2eeRepositoryProvider.overrideWithValue(repo),
      ]);

  group('chatMessagesProvider — first page', () {
    test('loads the last 50 messages (offset 0, limit 50) through the '
        'repository', () async {
      seedService((offset, _) => _page(offset, 50));
      final c = container();
      addTearDown(c.dispose);

      final state = await c.read(chatMessagesProvider(_chatId).future);

      expect(state.messages, hasLength(50));
      expect(state.messages.first['id'], 'm-49');
      expect(state.messages.last['id'], 'm-0');
      expect(state.hasMore, isTrue);
      expect(state.loadingOlder, isFalse);
      verify(() => service.loadMessages(_chatId, limit: 50, offset: 0))
          .called(1);
      expect(requestedOffsets, [0]);
    });

    test('a short first page (< 50) flips hasMore to false', () async {
      seedService((offset, _) => _page(offset, 30));
      final c = container();
      addTearDown(c.dispose);

      final state = await c.read(chatMessagesProvider(_chatId).future);

      expect(state.messages, hasLength(30));
      expect(state.hasMore, isFalse);
    });

    test('an empty chat loads an empty state with hasMore false', () async {
      seedService((_, _) => const []);
      final c = container();
      addTearDown(c.dispose);

      final state = await c.read(chatMessagesProvider(_chatId).future);

      expect(state.messages, isEmpty);
      expect(state.hasMore, isFalse);
    });
  });

  group('chatMessagesProvider — loadOlder', () {
    test('prepends the next page (offset += 50) and dedupes by id',
        () async {
      // Page 0: m-49..m-0 (50). Page 1 (window 50..99): m-100..m-52 plus a
      // row whose id duplicates m-49 (a realtime/page-boundary overlap) —
      // the duplicate must be dropped, the unique rows prepended.
      seedService((offset, _) {
        if (offset == 0) return _page(0, 50);
        final unique = [for (var i = 100; i >= 52; i--) _message('m-$i')];
        return [...unique, _message('m-49')];
      });
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      await notifier.loadOlder();

      final state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(99)); // 49 new + 50 existing
      expect(state.messages.first['id'], 'm-100');
      expect(state.messages.last['id'], 'm-0');
      expect(state.hasMore, isTrue);
      // The duplicated id appears exactly once (the newer instance).
      final dup = state.messages.where((m) => m['id'] == 'm-49');
      expect(dup, hasLength(1));
      // Every id is unique.
      expect(
        state.messages.map((m) => m['id']).toSet(),
        hasLength(state.messages.length),
      );
      // Offsets advanced by a full page.
      expect(requestedOffsets, [0, 50]);
      verify(() => service.loadMessages(_chatId, limit: 50, offset: 50))
          .called(1);
    });

    test('a short older page (< 50) flips hasMore and stops further fetches',
        () async {
      seedService((offset, _) => offset == 0 ? _page(0, 50) : _page(50, 25));
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      await notifier.loadOlder();
      await notifier.loadOlder(); // must be a no-op

      final state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(75));
      expect(state.hasMore, isFalse);
      expect(state.loadingOlder, isFalse);
      // Only the first two pages were ever requested.
      expect(requestedOffsets, [0, 50]);
      verify(() => service.loadMessages(_chatId, limit: 50, offset: 50))
          .called(1);
    });

    test('never paginates past the 1000-message cap (chat.message_cap)',
        () async {
      seedService((offset, _) => _page(offset, 50));
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      for (var i = 0; i < 19; i++) {
        await notifier.loadOlder(); // 20 pages × 50 = 1000
      }

      var state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(1000));
      expect(state.hasMore, isFalse);

      await notifier.loadOlder(); // must not exceed the cap

      state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(1000));
      // 20 service calls total (offset 0 + 19 older pages); the request that
      // would exceed the cap never fires.
      expect(requestedOffsets, hasLength(20));
      expect(requestedOffsets.every((o) => o < 1000), isTrue);
      verify(() => service.loadMessages(any(), limit: any(named: 'limit'),
              offset: any(named: 'offset')))
          .called(20);
    });

    test('exposes loadingOlder while a page is in flight', () async {
      var release = Completer<void>();
      when(
        () => service.loadMessages(
          _chatId,
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((inv) async {
        final offset = inv.namedArguments[#offset] as int;
        if (offset == 0) return _page(0, 50);
        await release.future;
        return _page(50, 50);
      });
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      final pending = notifier.loadOlder();
      // Not awaited yet — the state must expose the in-flight flag.
      final during = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(during.loadingOlder, isTrue);

      release.complete();
      await pending;
      final after = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(after.loadingOlder, isFalse);
      expect(after.messages, hasLength(100));
    });

    test('concurrent loadOlder calls are serialized (no duplicate fetches)',
        () async {
      seedService((offset, _) => _page(offset, 50));
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      await Future.wait([notifier.loadOlder(), notifier.loadOlder()]);

      expect(requestedOffsets, [0, 50]); // the second call was a no-op
      final state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(100));
    });
  });

  group('chatMessagesProvider — realtime append (E2EE path stays intact)', () {
    test('addMessage appends + dedupes on the paged state', () async {
      seedService((_, _) => _page(0, 2));
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      notifier.addMessage(_message('m-new')); // decrypted realtime row
      notifier.addMessage(_message('m-new')); // duplicate — dropped

      final state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages.map((m) => m['id']).toList(), [
        'm-1',
        'm-0',
        'm-new',
      ]);
      expect(state.hasMore, isFalse); // preserved from the first page
    });
  });

  group('E2EE invariant — the service is the only data source', () {
    test('the provider never touches the raw Supabase client (verifyNever)',
        () async {
      seedService((offset, _) => _page(offset, 50));
      final c = container();
      addTearDown(c.dispose);

      await c.read(chatMessagesProvider(_chatId).future);
      await c.read(chatMessagesProvider(_chatId).notifier).loadOlder();

      // Every message path went through the repository → service: neither
      // the client nor the raw realtime service was ever consulted.
      verifyNever(() => client.from(any()));
      verifyNever(() => realtime.subscribeToMessages(any(), any()));
      verify(
        () => service.loadMessages(
          _chatId,
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).called(2);
    });
  });

  group('real stack — ChatService + ChatRepository + provider', () {
    test('offset math and reversed ordering end to end', () async {
      _WindowBuilder.windows.clear();
      // The server holds 150 rows, newest FIRST (PostgREST DESC), ids
      // m-149 (newest) .. m-0 (oldest).
      final serverRows = [for (var i = 149; i >= 0; i--) _message('m-$i')];
      final client = _MockSupabaseClient();
      final auth = _MockGoTrueClient();
      final messagesQb = _MockQueryBuilder();
      when(() => client.auth).thenReturn(auth);
      when(() => auth.currentUser).thenReturn(
        User.fromJson({'id': '11111111-1111-1111-1111-111111111111'}),
      );
      when(() => client.from('messages')).thenAnswer((_) => messagesQb);
      when(() => messagesQb.select(any())).thenAnswer(
        (_) => _WindowBuilder(serverRows),
      );

      final realService = ChatService(
        client: client,
        realtime: RealtimeService(client: client),
      );
      final c = ProviderContainer(overrides: [
        chatE2eeServiceProvider.overrideWithValue(realService),
        // The repository also watches the realtime service — mocked so no
        // build path touches the uninitialized Supabase singleton (the
        // screen owns the realtime subscription, not the provider).
        realtimeServiceProvider.overrideWithValue(_MockRealtimeService()),
      ]);
      addTearDown(c.dispose);

      // First page: the newest 50 (window 0..49 reversed → chronological).
      var state = await c.read(chatMessagesProvider(_chatId).future);
      expect(state.messages, hasLength(50));
      expect(state.messages.first['id'], 'm-100');
      expect(state.messages.last['id'], 'm-149');
      expect(state.hasMore, isTrue);

      // Two more pages → the full 150-message history, oldest first.
      final notifier = c.read(chatMessagesProvider(_chatId).notifier);
      await notifier.loadOlder();
      state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(100));
      expect(state.messages.first['id'], 'm-50');
      expect(state.hasMore, isTrue);

      await notifier.loadOlder();
      state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(150));
      expect(state.messages.first['id'], 'm-0');
      expect(state.messages.last['id'], 'm-149');
      expect(state.hasMore, isTrue);

      // The next page comes back empty → hasMore flips false.
      await notifier.loadOlder();
      state = c.read(chatMessagesProvider(_chatId)).valueOrNull!;
      expect(state.messages, hasLength(150));
      expect(state.hasMore, isFalse);

      // The exact server windows the service requested (offset..offset+49).
      expect(
        _WindowBuilder.windows,
        [(0, 49), (50, 99), (100, 149), (150, 199)],
      );
    });
  });
}

/// Real Postgrest filter resolving each awaited page from a fixed newest-first
/// row list using the recorded `.range(from, to)` window — the same contract
/// the real server implements (DESC order + range, reversed client-side).
class _WindowBuilder extends ResolvingBuilder<PostgrestList> {
  _WindowBuilder(this.rows) : super(const []);

  final List<Map<String, dynamic>> rows;

  /// Every range window requested, in call order.
  static final List<(int, int)> windows = [];

  @override
  Future<U> then<U>(
    FutureOr<U> Function(PostgrestList value) onValue, {
    Function? onError,
  }) {
    final from = ranges.last.$1;
    final to = ranges.last.$2;
    windows.add((from, to));
    final end = min(to + 1, rows.length);
    // The server's answer for the window, newest FIRST (DESC) — the service
    // reverses it client-side to chronological order.
    final slice = rows.sublist(from, end);
    final resolved = ResolvingBuilder.coerce(slice);
    return Future<U>(() => onValue(resolved as PostgrestList));
  }
}
