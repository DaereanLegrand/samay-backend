import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/e2ee_prekey_service.dart';
import 'package:samay/crypto/envelope.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Two-party end-to-end E2EE chat harness (E2EE-ARCHITECTURE.md §11.2 I1-I4):
/// two real `ChatService` instances (real `lib/crypto/` session machinery)
/// against an in-memory fake Supabase server implementing §9 semantics —
/// prekey bundles with atomic OPK consumption, opaque `messages.content`,
/// `chat_participants` for peer resolution.
class _FakeServer {
  _FakeServer({required this.chatId});

  final String chatId;

  /// Per-user prekey rows (the `e2ee_identity_keys` table).
  final Map<String, Map<String, dynamic>> prekeys = {};

  /// All message rows, newest FIRST (server returns DESC — the service
  /// reverses to oldest-first for history).
  final List<Map<String, dynamic>> rows = [];

  final Map<String, List<String>> participants = {};

  List<Map<String, dynamic>> messagesFor(String chatId) =>
      rows.where((r) => r['chat_id'] == chatId).toList();

  Map<String, dynamic>? prekeyRowFor(String userId) {
    final row = prekeys[userId];
    if (row == null) return null;
    return Map<String, dynamic>.from(row);
  }

  void publishRow(String userId, Map<String, dynamic> row) {
    // The DB column has a DEFAULT '[]' — emulate it for rows the client
    // upserts without the consumed list.
    prekeys[userId] = {
      'consumed_one_time_prekeys': const [],
      ...Map<String, dynamic>.from(row),
    };
  }

  /// `fetch_prekey_bundle` RPC: pops ONE one-time prekey atomically and
  /// appends it to the consumed list (§9.3 / migration 20260809000003).
  Map<String, dynamic>? fetchBundle(String userId) {
    final row = prekeys[userId];
    if (row == null) return null;
    final remaining = (row['one_time_prekeys'] as List).toList();
    Map<String, dynamic>? popped;
    if (remaining.isNotEmpty) {
      popped = Map<String, dynamic>.from(remaining.removeAt(0) as Map);
      row['one_time_prekeys'] = remaining;
      final consumed = (row['consumed_one_time_prekeys'] as List).toList()
        ..add(popped);
      row['consumed_one_time_prekeys'] = consumed;
    }
    return {
      'user_id': userId,
      'identity_key': row['identity_key'],
      'identity_sig_key': row['identity_sig_key'],
      'signed_prekey_id': row['signed_prekey_id'],
      'signed_prekey': row['signed_prekey'],
      'signed_prekey_sig': row['signed_prekey_sig'],
      'signed_prekey_expires_at': row['signed_prekey_expires_at'],
      'one_time_prekey': popped,
    };
  }

  void insertMessage(String chatId, String senderId, Map<String, dynamic> payload) {
    rows.insert(0, {
      'id': 'msg-${rows.length}',
      'chat_id': chatId,
      'sender_id': senderId,
      ...payload,
    });
  }
}

/// A Postgrest filter that resolves to a value freshly computed at await
/// time (so every call sees the current server state) and whose chain
/// methods are no-ops returning `this`.
class _ServerFilter<T> extends PostgrestFilterBuilder<T> {
  _ServerFilter(this._resolve)
      : super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final T Function() _resolve;

  @override
  _ServerFilter<T> eq(String column, Object value) => this;

  @override
  _ServerFilter<T> order(
    String column, {
    bool ascending = false,
    bool nullsFirst = false,
    String? referencedTable,
  }) => this;

  @override
  _ServerFilter<T> range(int from, int to, {String? referencedTable}) => this;

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(_resolve()));
  }
}

/// A filter that resolves to a fixed value (RPC results, insert acks).
class _FixedFilter<T> extends PostgrestFilterBuilder<T> {
  _FixedFilter(this._value)
      : super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(_value as T));
  }
}

class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockGoTrueClient extends Mock implements GoTrueClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

const _chatId = 'chat-1';
const _userIdA = '11111111-1111-1111-1111-111111111111';
const _userIdB = '22222222-2222-2222-2222-222222222222';

class _Party {
  _Party({required this.userId, required this.server}) {
    keys = MemoryE2eeKeyStore();
    sessions = MemoryE2eeSessionStore();
    client = _MockSupabaseClient();
    auth = _MockGoTrueClient();
    messagesQb = _MockQueryBuilder();
    participantsQb = _MockQueryBuilder();
    prekeysQb = _MockQueryBuilder();

    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenReturn(User.fromJson({'id': userId}));

    when(() => client.from('messages')).thenAnswer((_) => messagesQb);
    when(() => messagesQb.select(any())).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () => server.messagesFor(_chatId),
      ),
    );
    when(() => messagesQb.insert(any())).thenAnswer((inv) {
      final payload = Map<String, dynamic>.from(inv.positionalArguments.first as Map);
      server.insertMessage(_chatId, userId, payload);
      return _FixedFilter<dynamic>(null);
    });

    when(() => client.from('chat_participants')).thenAnswer((_) => participantsQb);
    when(() => participantsQb.select(any())).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () => [
          for (final uid in server.participants[_chatId] ?? <String>[])
            {'user_id': uid},
        ],
      ),
    );

    when(() => client.from(SupabaseE2eePrekeyService.tableName))
        .thenAnswer((_) => prekeysQb);
    when(() => prekeysQb.select()).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () {
          final row = server.prekeyRowFor(userId);
          return row == null ? const [] : [row];
        },
      ),
    );
    when(() => prekeysQb.upsert(any(), onConflict: any(named: 'onConflict')))
        .thenAnswer((inv) {
      server.publishRow(
        userId,
        Map<String, dynamic>.from(inv.positionalArguments.first as Map),
      );
      return _FixedFilter<dynamic>(null);
    });

    when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
        .thenAnswer((inv) {
      final params = inv.namedArguments[#params];
      return _FixedFilter<dynamic>(server.fetchBundle(params['p_user_id'] as String));
    });

    prekeyService = SupabaseE2eePrekeyService(client: client, keyStore: keys);
  }

  final String userId;
  final _FakeServer server;
  late final MemoryE2eeKeyStore keys;
  late final MemoryE2eeSessionStore sessions;
  late final _MockSupabaseClient client;
  late final _MockGoTrueClient auth;
  late final _MockQueryBuilder messagesQb;
  late final _MockQueryBuilder participantsQb;
  late final _MockQueryBuilder prekeysQb;
  late final SupabaseE2eePrekeyService prekeyService;

  /// A fresh ChatService over the SAME stores — the "app restart" simulation
  /// (§7.3 resumption via the serialized session JSON).
  ChatService service({RealtimeService? realtime}) => ChatService(
    client: client,
    realtime: realtime ?? RealtimeService(client: client),
    e2eeKeyStore: keys,
    e2eeSessionStore: sessions,
    e2eePrekeyService: prekeyService,
  );
}

void main() {
  late _FakeServer server;
  late _Party alice;
  late _Party bob;

  setUp(() async {
    server = _FakeServer(chatId: _chatId);
    server.participants[_chatId] = [_userIdA, _userIdB];
    alice = _Party(userId: _userIdA, server: server);
    bob = _Party(userId: _userIdB, server: server);
    // Bob publishes at "profile creation" (§12.2 step 4 hook — the auth
    // wiring is a documented follow-up); Alice publishes lazily on her
    // first send (handleMissingSession bootstrap). AWAITED on purpose —
    // a fire-and-forget publish races the test body (I-38 MISTAKE block).
    await bob.prekeyService.publishAll();
  });

  List<String> storedContents() =>
      server.messagesFor(_chatId).map((r) => r['content'] as String).toList();

  test('A sends first (init) → B receives (X3DH respond) → B replies → '
      'A receives → 10 more both ways; stored content is NEVER plaintext', () async {
    final serviceA = alice.service();
    final serviceB = bob.service();

    // A's first message: X3DH init envelope, published lazily first.
    await serviceA.sendMessage(_chatId, 'hola bob', null);
    final stored = server.messagesFor(_chatId).single;
    expect(stored['content'], isNot('hola bob'));
    final parsed = SamayEnvelope.tryParse(base64UrlNoPadDecode(stored['content'])!)!;
    expect(parsed.type, e2eeEnvelopeTypeInit);

    // B loads history: decrypts the init message (X3DH respond).
    final bobMessages = await serviceB.loadMessages(_chatId);
    expect(bobMessages, hasLength(1));
    expect(bobMessages.single['content'], 'hola bob');
    expect(bobMessages.single['decryptFailed'], isFalse);

    // B replies (type 0x02 ratchet) → A receives.
    await serviceB.sendMessage(_chatId, 'hola alice', null);
    final aliceMessages = await serviceA.loadMessages(_chatId);
    expect(aliceMessages, hasLength(2));
    expect(aliceMessages[0]['content'], 'hola bob');
    expect(aliceMessages[1]['content'], 'hola alice');
    expect(aliceMessages.every((m) => m['decryptFailed'] == false), isTrue);

    // 10 more messages both ways (multiple DH ratchet turns).
    for (var i = 0; i < 10; i++) {
      await serviceA.sendMessage(_chatId, 'mensaje A$i', null);
      await serviceB.sendMessage(_chatId, 'mensaje B$i', null);
    }

    // Negative proof: NOTHING stored ever equals a plaintext.
    for (final content in storedContents()) {
      for (var i = 0; i < 10; i++) {
        expect(content, isNot('mensaje A$i'));
        expect(content, isNot('mensaje B$i'));
      }
      expect(content, isNot('hola bob'));
      expect(content, isNot('hola alice'));
    }

    // Both sides decrypt the full history correctly.
    final aliceFull = await serviceA.loadMessages(_chatId);
    final bobFull = await serviceB.loadMessages(_chatId);
    expect(aliceFull, hasLength(22));
    expect(aliceFull.map((m) => m['content']), everyElement(isNot(contains('Mensaje no descifrable'))));
    expect(bobFull.map((m) => m['content']), everyElement(isNot(contains('Mensaje no descifrable'))));
    expect(aliceFull[21]['content'], 'mensaje B9');
    expect(bobFull[21]['content'], 'mensaje B9');
  });

  test('restart both sides from serialized sessions → ratchet continues', () async {
    final serviceA = alice.service();
    final serviceB = bob.service();
    await serviceA.sendMessage(_chatId, 'primera', null);
    await serviceB.loadMessages(_chatId);
    await serviceB.sendMessage(_chatId, 'segunda', null);
    await serviceA.loadMessages(_chatId);

    // Serialized sessions exist.
    expect(await alice.sessions.loadSession(_chatId), isNotNull);
    expect(await bob.sessions.loadSession(_chatId), isNotNull);

    // "Restart": brand-new ChatService instances over the same stores.
    final restartedA = alice.service();
    final restartedB = bob.service();

    await restartedA.sendMessage(_chatId, 'despues del reinicio', null);
    final bobSees = await restartedB.loadMessages(_chatId);
    expect(bobSees.last['content'], 'despues del reinicio');
    expect(bobSees.last['decryptFailed'], isFalse);

    await restartedB.sendMessage(_chatId, 'respuesta tras reinicio', null);
    final aliceSees = await restartedA.loadMessages(_chatId);
    expect(aliceSees.last['content'], 'respuesta tras reinicio');
    expect(aliceSees.last['decryptFailed'], isFalse);
  });

  test('tampered envelope → decryptFailed placeholder; session stays healthy', () async {
    final serviceA = alice.service();
    final serviceB = bob.service();
    await serviceA.sendMessage(_chatId, 'bueno', null);
    await serviceB.loadMessages(_chatId);
    await serviceB.sendMessage(_chatId, 'tambien bueno', null);
    await serviceA.loadMessages(_chatId);
    await serviceA.sendMessage(_chatId, 'objetivo', null);

    // Server-side tamper: flip a bit in the newest envelope's ciphertext.
    final stored = server.messagesFor(_chatId).first;
    expect(stored['content'], isNot('objetivo'));
    final evil = base64UrlNoPadDecode(stored['content'] as String)!;
    evil[evil.length - 5] ^= 0x01;
    stored['content'] = base64UrlNoPadEncode(evil);

    final loaded = await serviceB.loadMessages(_chatId);
    final tampered = loaded.last;
    expect(tampered['decryptFailed'], isTrue);
    expect(tampered['content'], chatUndecryptablePlaceholder);
    // Untampered history still decrypts.
    expect(loaded[0]['content'], 'bueno');
    expect(loaded[1]['content'], 'tambien bueno');

    // The next legitimate message decrypts — session state preserved (§4.5).
    await serviceA.sendMessage(_chatId, 'despues del tamper', null);
    final reloaded = await serviceB.loadMessages(_chatId);
    expect(reloaded.last['content'], 'despues del tamper');
    expect(reloaded.last['decryptFailed'], isFalse);
  });

  test('subscribeToMessages decrypts realtime rows before delivery', () async {
    final realtime = _MockRealtimeService();
    final channel = _MockRealtimeChannel();
    void Function(Map<String, dynamic>)? onInsert;
    when(() => realtime.subscribeToMessages(any(), any())).thenAnswer((inv) {
      onInsert = inv.positionalArguments[1] as void Function(Map<String, dynamic>);
      return channel;
    });

    final serviceA = alice.service();
    final serviceB = bob.service(realtime: realtime);
    await serviceA.sendMessage(_chatId, 'hola en vivo', null);

    final received = <Map<String, dynamic>>[];
    serviceB.subscribeToMessages(_chatId, received.add);
    expect(onInsert, isNotNull);

    // A new raw envelope row arrives via realtime. Realtime delivers inserts
    // IN ORDER — the init envelope must be processed before the ratchet
    // message, exactly like a live conversation would.
    await serviceA.sendMessage(_chatId, 'mensaje realtime', null);
    final all = server.messagesFor(_chatId); // newest first
    onInsert!(all[1]); // 'hola en vivo' — the X3DH init envelope
    onInsert!(all[0]); // 'mensaje realtime' — the ratchet envelope
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(received[0]['content'], 'hola en vivo');
    expect(received[0]['decryptFailed'], isFalse);
    expect(received[1]['content'], 'mensaje realtime');
    expect(received[1]['decryptFailed'], isFalse);
  });

  test('sendMessage fails cleanly when the peer has no published bundle', () async {
    final serviceA = alice.service();
    // Bob has NOT published (setUp skipped) — A cannot initiate.
    server.prekeys.clear();
    await expectLater(
      () => serviceA.sendMessage(_chatId, 'sin bundle', null),
      throwsA(isA<Exception>()),
    );
    expect(server.messagesFor(_chatId), isEmpty);
  });
}
