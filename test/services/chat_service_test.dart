
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/message_plaintext_store.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/utils/input_sanitizer.dart';
import 'package:samay/crypto/codec.dart';
import 'package:samay/crypto/constants.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/e2ee_prekey_service.dart';
import 'package:samay/crypto/e2ee_primitives.dart';
import 'package:samay/crypto/envelope.dart';
import 'package:samay/crypto/group_cipher.dart';
import 'package:samay/crypto/interfaces.dart';
import 'package:samay/crypto/session.dart';
import 'package:samay/crypto/x3dh.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// ChatService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18).
///
/// I-38 owns `lib/core/services/chat_service.dart` (E2EE seam — the service
/// file was NOT touched); these tests cover the current public contract:
/// `loadMessages` ordering/pagination, `sendMessage` sanitize + insert shape,
/// and `subscribeToMessages` delegation to [RealtimeService].
const _chatId = '44444444-4444-4444-4444-444444444444';
const _userId = '11111111-1111-1111-1111-111111111111';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  setUpAll(() {
    // mocktail cannot synthesize enum values for `any(named: 'event')`.
    registerFallbackValue(PostgresChangeEvent.insert);
  });

  late MockSupabaseClient client;
  late MockGoTrueClient auth;
  late RealtimeService realtime;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
    realtime = RealtimeService(client: client);
  });

  ChatService service() => ChatService(client: client, realtime: realtime);

  group('ChatService.loadMessages (ordering + pagination)', () {
    test('fetches the newest page and reverses it to chronological order',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      final rows = ResolvingBuilder<PostgrestList>([
        {'id': 'm-3', 'content': 'third', 'created_at': '2026-08-01T00:03:00Z'},
        {'id': 'm-2', 'content': 'second', 'created_at': '2026-08-01T00:02:00Z'},
        {'id': 'm-1', 'content': 'first', 'created_at': '2026-08-01T00:01:00Z'},
      ]);
      when(() => messages.select(any())).thenAnswer((_) => rows);

      final result = await service().loadMessages(_chatId, limit: 3);

      // The service orders DESC on the server and reverses client-side, so
      // the oldest message of the page comes first.
      expect(result.map((m) => m['id']).toList(), ['m-1', 'm-2', 'm-3']);
      expect(rows.filters, contains(
        const RecordedFilter('chat_id', _chatId),
      ));
    });

    test('applies the offset/limit pagination window', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      final rows = ResolvingBuilder<PostgrestList>([
        {'id': 'm-5', 'content': 'older page', 'created_at': 'x'},
      ]);
      when(() => messages.select(any())).thenAnswer((_) => rows);

      final result = await service().loadMessages(_chatId, limit: 10, offset: 50);

      // The page window is 50..59 (offset + limit - 1).
      expect(rows.ranges, [(50, 59)]);
      expect(result.single['id'], 'm-5');
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().loadMessages(_chatId), throwsA(isA<Exception>()));
      verifyNever(() => client.from('messages'));
    });

    test('propagates a network-class PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection reset',
          code: '28000',
        ),
      );

      final err =
          await captureError(() => service().loadMessages(_chatId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });

  group('ChatService.sendMessage', () {
    test('inserts the sanitized content with the sender id', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().sendMessage(_chatId, '  hola \u{200B}mundo  ', null);

      final payload =
          verify(() => messages.insert(captureAny())).captured.single as Map;
      expect(payload['chat_id'], _chatId);
      expect(payload['sender_id'], _userId);
      // Control/format chars stripped, trimmed, media null.
      expect(payload['content'], 'hola mundo');
      expect(payload['media_url'], isNull);
      expect(payload['created_at'], isNotEmpty);
    });

    test('caps the content length at the message limit', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      final long =
          'x' * (InputSanitizer.messageMaxLength + 100);
      await service().sendMessage(_chatId, long, null);

      final payload =
          verify(() => messages.insert(captureAny())).captured.single as Map;
      expect(payload['content'], hasLength(InputSanitizer.messageMaxLength));
    });

    test('propagates a duplicate-row PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.insert(any())).thenThrow(
        const PostgrestException(
          message: 'duplicate key value',
          code: '23505',
        ),
      );

      final err =
          await captureError(() => service().sendMessage(_chatId, 'hola', null));
      expect(err, isA<PostgrestException>());
      expectMapped(err, ValidationError);
    });
  });

  group('ChatService.subscribeToMessages', () {
    test('delegates to the realtime service channel', () async {
      final channel = MockRealtimeChannel();
      when(() => client.channel('messages:$_chatId')).thenReturn(channel);
      when(() => channel.onPostgresChanges(
            event: any(named: 'event'),
            schema: any(named: 'schema'),
            table: any(named: 'table'),
            callback: any(named: 'callback'),
          )).thenReturn(channel);
      when(() => channel.subscribe()).thenReturn(channel);

      // Sync by design (I-38): returns the channel for caller unsubscribe.
      final returned = service().subscribeToMessages(_chatId, (_) {});

      expect(returned, same(channel));
      verify(() => client.channel('messages:$_chatId')).called(1);      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe()).called(1);
    });
  });

  group('ChatService.createDirectChat', () {
    const peerId = '22222222-2222-2222-2222-222222222222';

    test('creates a chat via the RPC and returns the chat id', () async {
      final rpc = ResolvingBuilder<dynamic>({'chatId': _chatId, 'reused': false});
      when(() => client.rpc('create_direct_chat', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      final id = await service().createDirectChat(peerId);

      expect(id, _chatId);
      final params =
          verify(() => client.rpc('create_direct_chat', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params, {'p_peer_id': peerId});
    });

    test('reuses the existing chat when the pair already has one', () async {
      final rpc = ResolvingBuilder<dynamic>({'chatId': _chatId, 'reused': true});
      when(() => client.rpc('create_direct_chat', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      expect(await service().createDirectChat(peerId), _chatId);
    });

    test('throws when the RPC fails (peer not found / unauthorized)', () async {
      when(() => client.rpc('create_direct_chat', params: any(named: 'params')))
          .thenThrow(
        const PostgrestException(
          message: 'Peer not found',
          code: 'PGRST203',
        ),
      );

      expect(
        () => service().createDirectChat(peerId),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('ChatService.fetchInbox + markChatRead (20260815000004 RPCs)', () {
    test('fetchInbox maps the RPC result into rows', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>([
        {
          'chat_id': _chatId,
          'type': 'direct',
          'peer_id': '22222222-2222-2222-2222-222222222222',
          'peer_username': 'bob',
          'last_message_id': 'm-1',
          'last_message_sender_id': '22222222-2222-2222-2222-222222222222',
          'last_message_content': 'SME2.envelope',
          'last_message_created_at': '2026-08-15T00:00:00Z',
          'unread_count': 3,
        },
      ]);
      when(() => client.rpc('get_chat_inbox')).thenAnswer((_) => rpc);

      final rows = await service().fetchInbox();

      expect(rows, hasLength(1));
      expect(rows.single['chat_id'], _chatId);
      expect(rows.single['unread_count'], 3);
      verify(() => client.rpc('get_chat_inbox')).called(1);
    });

    test('fetchInbox throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().fetchInbox(), throwsA(isA<Exception>()));
    });

    test('markChatRead calls the self-only RPC with the chat id', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>(null);
      when(() => client.rpc('mark_chat_read', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      await service().markChatRead(_chatId);

      final params =
          verify(() => client.rpc('mark_chat_read', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params, {'p_chat_id': _chatId});
    });

    test('decryptInboxRow returns the row unchanged without E2EE wiring '
        '(plaintext service)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final row = {
        'chat_id': _chatId,
        'last_message_id': 'm-1',
        'last_message_sender_id': 'peer',
        'last_message_content': 'hola',
      };

      final out = await service().decryptInboxRow(row);

      expect(out['last_message_content'], 'hola');
      expect(out['last_message_decrypt_failed'], false);
    });

    test('decryptInboxRow is E2EE-safe: a malformed envelope with NO session '
        'yields the needsSession flag (Signal reinstall semantics 2026-08-16), '
        'never a throw', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenThrow(UnimplementedError());
      when(() => client.rpc('delete_undecryptable_messages',
              params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(0));
      when(() => client.from('chat_participants')).thenAnswer((_) => throw UnimplementedError());

      final service = ChatService(
        client: client,
        realtime: realtime,
        e2eeKeyStore: MemoryE2eeKeyStore(),
        e2eeSessionStore: MemoryE2eeSessionStore(),
        e2eePrekeyService: _FakePrekeyService(),
      );
      final out = await service.decryptInboxRow({
        'chat_id': _chatId,
        'last_message_id': 'm-1',
        'last_message_sender_id': 'peer',
        'last_message_content': 'not-an-envelope',
      });

      // No session exists → the row is the pre-reinstall class: hidden, not
      // placeholder-marked.
      expect(out['last_message_needs_session'], true);
      expect(out['last_message_decrypt_failed'], false);
    });
  });

  group('ChatService.deleteMessageForEveryone (20260815000006)', () {
    test('maps the server verdicts to MessageDeleteOutcome', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      Future<MessageDeleteOutcome> attempt(
        void Function() rpcStub,
      ) async {
        rpcStub();
        return service().deleteMessageForEveryone('m-1');
      }

      expect(
        await attempt(() => when(() => client.rpc('delete_message_for_everyone',
                params: any(named: 'params')))
            .thenAnswer((_) => ResolvingBuilder<dynamic>(null))),
        MessageDeleteOutcome.deleted,
      );

      expect(
        await attempt(() => when(() => client.rpc('delete_message_for_everyone',
                params: any(named: 'params')))
            .thenThrow(const PostgrestException(
              message: 'MESSAGE_TOO_OLD',
              code: 'P0001',
            ))),
        MessageDeleteOutcome.tooOld,
      );

      expect(
        await attempt(() => when(() => client.rpc('delete_message_for_everyone',
                params: any(named: 'params')))
            .thenThrow(const PostgrestException(
              message: 'NOT_THE_SENDER',
              code: 'P0001',
            ))),
        MessageDeleteOutcome.notSender,
      );

      expect(
        await attempt(() => when(() => client.rpc('delete_message_for_everyone',
                params: any(named: 'params')))
            .thenThrow(const PostgrestException(
              message: 'MESSAGE_NOT_FOUND',
              code: 'P0001',
            ))),
        MessageDeleteOutcome.notFound,
      );

      expect(
        await attempt(() => when(() => client.rpc('delete_message_for_everyone',
                params: any(named: 'params')))
            .thenThrow(const PostgrestException(
              message: 'connection reset',
              code: '28000',
            ))),
        MessageDeleteOutcome.failed,
      );
    });

    test('sends the message id as the RPC param', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => client.rpc('delete_message_for_everyone',
              params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().deleteMessageForEveryone('m-42');

      verify(() => client.rpc('delete_message_for_everyone',
              params: {'p_message_id': 'm-42'}))
          .called(1);
    });
  });

  group('ChatService.deleteMessageForMe (2026-08-16)', () {
    test('tombstones the message locally; other messages are unaffected',
        () async {
      final svc = service();
      await svc.deleteMessageForMe('chat-1', 'm-9');

      expect(svc.isLocallyDeleted('chat-1', 'm-9'), isTrue);
      expect(svc.isLocallyDeleted('chat-1', 'm-8'), isFalse);
      expect(svc.isLocallyDeleted('chat-2', 'm-9'), isFalse);
    });
  });

  group('ChatService.loadMessages undecryptable cleanup (2026-08-16)', () {
    test('no-session failures fire the delete_undecryptable_messages RPC '
        'with the flagged ids (offload)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenThrow(UnimplementedError());
      when(() => client.from('chat_participants')).thenAnswer(
        (_) => throw UnimplementedError(),
      );
      when(() => client.from('messages')).thenAnswer((_) => MockQueryBuilder());
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {
            'id': 'm-2',
            'sender_id': 'peer',
            'content': 'not-an-envelope-2',
            'created_at': '2026-08-01T00:01:00Z',
          },
          {
            'id': 'm-1',
            'sender_id': 'peer',
            'content': 'not-an-envelope',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ]),
      );
      when(() => client.rpc('delete_undecryptable_messages',
              params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(2));

      final service = ChatService(
        client: client,
        realtime: realtime,
        e2eeKeyStore: MemoryE2eeKeyStore(),
        e2eeSessionStore: MemoryE2eeSessionStore(),
        e2eePrekeyService: _FakePrekeyService(),
      );
      final rows = await service.loadMessages(_chatId);

      // Both rows are the no-session class (hidden — never a placeholder).
      expect(rows.every((r) => r['needsSession'] == true), isTrue);
      expect(rows.every((r) => r['decryptFailed'] != true), isTrue);
      verify(() => client.rpc('delete_undecryptable_messages',
              params: {
                'p_chat_id': _chatId,
                'p_message_ids': ['m-1', 'm-2'],
              }))
          .called(1);
    });

    test('a missing cleanup RPC (old server) is swallowed — rows stay '
        'hidden, no throw (compat 2026-08-16)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
          .thenThrow(UnimplementedError());
      when(() => client.from('chat_participants')).thenAnswer(
        (_) => throw UnimplementedError(),
      );
      final messages = MockQueryBuilder();
      when(() => client.from('messages')).thenAnswer((_) => messages);
      when(() => messages.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {
            'id': 'm-1',
            'sender_id': 'peer',
            'content': 'not-an-envelope',
            'created_at': '2026-08-01T00:00:00Z',
          },
        ]),
      );
      when(() => client.rpc('delete_undecryptable_messages',
              params: any(named: 'params')))
          .thenThrow(const PostgrestException(
            message: 'Could not find the function public.delete_undecryptable_messages',
            code: 'PGRST202',
          ));

      final service = ChatService(
        client: client,
        realtime: realtime,
        e2eeKeyStore: MemoryE2eeKeyStore(),
        e2eeSessionStore: MemoryE2eeSessionStore(),
        e2eePrekeyService: _FakePrekeyService(),
      );
      final rows = await service.loadMessages(_chatId);

      expect(rows.single['needsSession'], true);
      expect(rows.single['decryptFailed'], isNot(true));
    });
  });
  group('ChatService group chat E2EE (ISSUE 4 / D3b)', () {
    // Two parties with REAL pairwise (1:1 E2EE) crypto + a FAKE
    // GroupE2eeCipher (mocktail): the pairwise distribution envelopes are
    // real (X3DH init — the responder flow decrypts them), while the group
    // cipher's key-holding operations (encrypt/decrypt/processBundle) are
    // stubbed. Type/marker checks (isSenderKeyEnvelope/isSenderKeyBundle)
    // delegate to the REAL envelope/JSON parsers.
    late _GroupFakeServer server;
    late _GroupParty alice;
    late _GroupParty bob;
    late _GroupParty carol;

    setUp(() async {
      server = _GroupFakeServer(chatId: _groupChatId);
      final msgEnv = await _makeSenderKeyEnvelope('hola grupo');
      alice = _GroupParty(userId: _userId, server: server, messageEnvelope: msgEnv);
      bob = _GroupParty(userId: _memberBobId, server: server, messageEnvelope: msgEnv);
      carol = _GroupParty(userId: _memberCarolId, server: server, messageEnvelope: msgEnv);
      server.roster = [_userId, _memberBobId];
      // Members publish their prekey bundles at "profile creation"; the
      // distributor initiates the pairwise sessions against these bundles.
      await bob.prekeyService.publishAll();
    });

    test('sendMessage on a group chat encrypts via groupCipher and inserts '
        'the message row with recipient_id NULL', () async {
      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'hola grupo', null);

      // Distribution row (bundle to the only other member) first, then the
      // single sender-key message row.
      expect(alice.inserts, hasLength(2));
      final msg = alice.inserts.last;
      expect(msg['chat_id'], _groupChatId);
      expect(msg['sender_id'], _userId);
      expect(msg['recipient_id'], isNull);
      expect(msg['content'], alice.messageEnvelope);
      expect(msg['created_at'], isNotEmpty);
      // The roster was resolved and handed to the cipher for the
      // membersMissingSenderKey computation.
      verify(() => alice.cipher.membersMissingSenderKey(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            activeMemberIds: [_userId, _memberBobId],
          )).called(1);
      // Own rows render from the outbox, exactly like the 1:1 path.
      final mine = await svc.loadMessages(_groupChatId);
      expect(mine.last['content'], 'hola grupo');
      expect(mine.last['decryptFailed'], isFalse);
    });

    test('a group chat with ONLY the sender sends just the message row '
        '(zero-member distribution, no throw — _resolvePeerUserId is never '
        'reached)', () async {
      server.roster = [_userId];

      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'solo yo', null);

      expect(alice.inserts, hasLength(1));
      final msg = alice.inserts.single;
      expect(msg['recipient_id'], isNull);
      expect(msg['content'], alice.messageEnvelope);
      verifyNever(() => alice.cipher.wipeGroupKeys(any()));
    });

    test('sendMessage distributes sender-key bundles to missing members '
        'FIRST — distribution rows carry recipient_id + the pairwise-session '
        'envelope, the message row comes last', () async {
      server.roster = [_userId, _memberBobId, _memberCarolId];
      await carol.prekeyService.publishAll();

      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'hola a todos', null);

      expect(alice.inserts, hasLength(3));
      // (a) distribution rows (order-agnostic since 2026-08-17 — the
      // distribution phase runs in PARALLEL, so completion order is not
      // member order), recipient_id set, content is a REAL pairwise X3DH
      // init envelope (0x01).
      final distributions = alice.inserts.sublist(0, 2);
      final targets = distributions.map((r) => r['recipient_id']).toSet();
      expect(targets, {_memberBobId, _memberCarolId});
      for (final dist in distributions) {
        final env = base64UrlNoPadDecode(dist['content'] as String)!;
        expect(SamayEnvelope.tryParse(env)?.type, e2eeEnvelopeTypeInit,
            reason: 'distribution rows carry the pairwise-session envelope');
      }
      // (b) the single sender-key message row, recipient_id NULL, content is
      // the group cipher's 0x03 envelope.
      final msg = alice.inserts[2];
      expect(msg['recipient_id'], isNull);
      final msgEnv = base64UrlNoPadDecode(msg['content'] as String)!;
      expect(SamayEnvelope.tryParse(msgEnv)?.type,
          e2eeEnvelopeTypeSenderKey);
      // No roster change on a steady state → no rekey.
      verifyNever(() => alice.cipher.wipeGroupKeys(any()));
    });

    test('group sends reuse the cached roster within the TTL — ONE roster '
        'SELECT for consecutive messages (latency: the per-send round trip '
        'is dropped; a membership change is noticed at the next TTL '
        'boundary)', () async {
      server.roster = [_userId, _memberBobId];
      var rosterFetches = 0;
      when(() => alice.participantsQb.select(any())).thenAnswer((inv) {
        rosterFetches++;
        return _ServerFilter<List<Map<String, dynamic>>>(
          () => [for (final uid in server.roster) {'user_id': uid}],
        );
      });

      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'uno', null);
      await svc.sendMessage(_groupChatId, 'dos', null);

      expect(rosterFetches, 1,
          reason: 'the second send must reuse the cached roster (within the '
              'TTL) — one fewer network round trip per group message');
      verify(() => alice.cipher.membersMissingSenderKey(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            activeMemberIds: [_userId, _memberBobId],
          )).called(2);
    });

    test('distribution to MULTIPLE missing members encrypts in PARALLEL — '
        'the message row still lands after ALL distribution rows '
        '(latency: N serial round trips → 1)', () async {
      server.roster = [_userId, _memberBobId, _memberCarolId];
      await carol.prekeyService.publishAll();
      final gated = _GatedSessionStore(alice.sessions);
      final svc = alice.service(sessionStore: gated);

      final send = svc.sendMessage(_groupChatId, 'hola a todos', null);
      await pumpEventQueue();
      // Both pairwise encrypts reached their final saveSession step while
      // the OTHER was still in flight — pre-fix the distribution loop was
      // strictly serial (maxActive would stay 1).
      expect(gated.maxActive, greaterThan(1),
          reason: 'the per-member distribution encrypts must run in parallel');
      for (final g in gated.gates) {
        g.complete();
      }
      await send;

      expect(alice.inserts.length, 3);
      expect(alice.inserts.last['recipient_id'], isNull,
          reason: 'the message row must land AFTER every distribution row');
      expect(
        alice.inserts
            .where((r) => r['recipient_id'] == _memberBobId)
            .length,
        1,
      );
      expect(
        alice.inserts
            .where((r) => r['recipient_id'] == _memberCarolId)
            .length,
        1,
      );
      // The registry marks stay SERIAL (the registry JSON is a
      // read-modify-write document — parallel marks would lose updates).
      verify(() => alice.cipher.markSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberBobId],
          )).called(1);
      verify(() => alice.cipher.markSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberCarolId],
          )).called(1);
    });

    test('group sends publish the local bundle ONCE per process — the '
        'per-send publishAll round trip is dropped after the first send '
        '(latency fix 2026-08-17: the old 1:1-namespace guard never matched '
        'group chats, so EVERY group message re-published)', () async {
      server.roster = [_userId, _memberBobId];
      var upserts = 0;
      when(() => alice.prekeysQb.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((inv) {
        upserts++;
        alice.server.prekeys[_userId] = {
          'consumed_one_time_prekeys': const [],
          ...Map<String, dynamic>.from(inv.positionalArguments.first as Map),
        };
        return _FixedFilter<dynamic>(null);
      });

      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'uno', null);
      await svc.sendMessage(_groupChatId, 'dos', null);

      expect(upserts, 1,
          reason: 'the local bundle is published once per process — the '
              'second send must not re-run the publish round trip');
    });

    test('roster SHRINK → wipeGroupKeys (new epoch) + fresh bundle '
        're-distributed to the remaining members', () async {
      server.roster = [_userId, _memberBobId, _memberCarolId];
      await carol.prekeyService.publishAll();
      // rosterTtl: Duration.zero — the shrink must be DETECTED on the very
      // next send (the TTL cache would hide it until the boundary).
      final svc = alice.service(rosterTtl: Duration.zero);
      await svc.sendMessage(_groupChatId, 'primera', null);
      expect(alice.inserts, hasLength(3));

      // Carol leaves: the cached roster differs → hard rekey.
      server.roster = [_userId, _memberBobId];
      await svc.sendMessage(_groupChatId, 'segunda', null);

      verify(() => alice.cipher.wipeGroupKeys(_groupChatId)).called(1);
      // The send after the wipe re-distributes to every other active member
      // (the registry is gone → the members show as missing again).
      final secondRound = alice.inserts.sublist(3);
      expect(secondRound, hasLength(2));
      expect(secondRound.first['recipient_id'], _memberBobId);
      expect(secondRound.last['recipient_id'], isNull);
      // The message itself was re-encrypted for the new epoch.
      expect(secondRound.last['content'], alice.messageEnvelope);
    });

    test('a member WITHOUT a published prekey bundle is SKIPPED — the send '
        'must not fail; the other members still get their distribution and '
        'the message row lands (2026-08-17 live finding: "send does not '
        'allow")', () async {
      server.roster = [_userId, _memberBobId, _memberCarolId];
      // Only carol published her bundle — bob has none, so the X3DH
      // initiation for bob's distribution cannot happen.
      await carol.prekeyService.publishAll();
      // Undo the harness default (setUp publishes every member's bundle):
      // bob must genuinely have no published prekeys for this scenario.
      server.prekeys.remove(_memberBobId);

      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'hola a todos', null);

      // Bob skipped (no bundle): carol's distribution row + the message row.
      expect(alice.inserts, hasLength(2));
      expect(alice.inserts[0]['recipient_id'], _memberCarolId);
      expect(alice.inserts[1]['recipient_id'], isNull);
      expect(alice.inserts[1]['content'], alice.messageEnvelope);
      // The skip is persisted for the reachable member only.
      verify(() => alice.cipher.markSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberCarolId],
          )).called(1);
      verifyNever(() => alice.cipher.markSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberBobId],
          ));
    });

    test('loadMessages on a group chat: skips recipient_id != me, decrypts '
        '0x03 via groupCipher (cached to the plaintext store), hides dropped, '
        'bubbles failed, hides distribution rows after processing the bundle',
        () async {
      // Alice sends → server rows: distribution (msg-0) then message (msg-1).
      final aliceSvc = alice.service();
      await aliceSvc.sendMessage(_groupChatId, 'hola grupo', null);

      // A bundle addressed to CAROL (not bob): must be skipped untouched.
      server.rows.insert(0, {
        'id': 'msg-2',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'recipient_id': _memberCarolId,
        'content': 'bundle-not-for-bob',
        'created_at': '2026-08-16T00:00:03Z',
      });
      // A tampered 0x03 (genuine failure → bubble) and a stale 0x03
      // (protocol drop → hidden).
      final failedEnv = await _makeSenderKeyEnvelope('tampered');
      final droppedEnv = await _makeSenderKeyEnvelope('stale');
      bob.decryptResults[failedEnv] =
          const E2eeDecryptResult.failed();
      bob.decryptResults[droppedEnv] =
          const E2eeDecryptResult.dropped();
      server.rows.insert(0, {
        'id': 'msg-3',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': failedEnv,
        'created_at': '2026-08-16T00:00:04Z',
      });
      server.rows.insert(0, {
        'id': 'msg-4',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': droppedEnv,
        'created_at': '2026-08-16T00:00:05Z',
      });

      final bobService = bob.service();
      final rows = await bobService.loadMessages(_groupChatId);

      // Oldest first: dist, message, carol-bundle, tampered, stale.
      expect(rows, hasLength(5));
      // Distribution row: bundle processed, row hidden (never a bubble).
      expect(rows[0]['decryptDropped'], isTrue);
      // The sender-key message: plaintext + cached to the plaintext store.
      expect(rows[1]['content'], 'hola grupo');
      expect(rows[1]['decryptFailed'], isFalse);
      expect(await bob.plaintext.get(_groupChatId, 'msg-1'), 'hola grupo');
      // Non-target row: skipped silently — NOT even parsed.
      expect(rows[2]['content'], 'bundle-not-for-bob');
      expect(rows[2]['decryptDropped'], isTrue);
      verifyNever(() => bob.cipher.isSenderKeyEnvelope('bundle-not-for-bob'));
      // Genuine failure → the undecryptable bubble.
      expect(rows[3]['decryptFailed'], isTrue);
      expect(rows[3]['content'], chatUndecryptablePlaceholder);
      // Protocol drop → hidden.
      expect(rows[4]['decryptDropped'], isTrue);
      // The bundle was processed through the group cipher with the message
      // row's sender as the chain owner.
      verify(() => bob.cipher.processSenderKeyBundle(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            groupId: _groupId,
            bundleJson: _bundleJson,
          )).called(1);
    });

    test('subscribeToMessages routes group rows the same way: bundles and '
        'non-target rows hidden, 0x03 messages decrypted before delivery',
        () async {
      final realtime = _MockRealtimeService();
      final channel = MockRealtimeChannel();
      void Function(Map<String, dynamic>)? onInsert;
      when(() => realtime.subscribeToMessages(any(), any())).thenAnswer(
        (inv) {
          onInsert =
              inv.positionalArguments[1] as void Function(Map<String, dynamic>);
          return channel;
        },
      );

      final aliceSvc = alice.service();
      await aliceSvc.sendMessage(_groupChatId, 'hola en vivo', null);
      // A non-target distribution row (addressed to carol).
      server.rows.insert(0, {
        'id': 'msg-9',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'recipient_id': _memberCarolId,
        'content': 'not-for-bob',
        'created_at': '2026-08-16T00:01:00Z',
      });

      final received = <Map<String, dynamic>>[];
      bob.service(realtime: realtime).subscribeToMessages(_groupChatId,
          received.add);
      expect(onInsert, isNotNull);

      for (final row in server.messagesFor().toList().reversed) {
        onInsert!(row);
      }
      await pumpEventQueue();

      // Only the sender-key message is delivered (decrypted); the
      // distribution row and the non-target row are hidden.
      expect(received, hasLength(1));
      expect(received.single['content'], 'hola grupo');
      expect(received.single['decryptFailed'], isFalse);
    });

    test('decryptInboxRow on a group row decrypts the last message via the '
        'group path', () async {
      final bobService = bob.service();
      final out = await bobService.decryptInboxRow({
        'chat_id': _groupChatId,
        'type': 'group',
        'last_message_id': 'm-1',
        'last_message_sender_id': _userId,
        'last_message_content': alice.messageEnvelope,
      });

      expect(out['last_message_content'], 'hola grupo');
      expect(out['last_message_decrypt_failed'], false);
      expect(out['last_message_needs_session'], isNot(true));
    });

    test('decryptInboxRow skips a group distribution row addressed to '
        'ANOTHER member silently: null preview, no decrypt attempt, no '
        'bubble (0004/F5 — last_message_recipient_id)', () async {
      final bobService = bob.service();
      final out = await bobService.decryptInboxRow({
        'chat_id': _groupChatId,
        'type': 'group',
        'last_message_id': 'm-dist',
        'last_message_sender_id': _userId,
        'last_message_recipient_id': _memberCarolId,
        'last_message_content': 'bundle-for-carol',
      });

      expect(out['last_message_content'], isNull);
      expect(out['last_message_decrypt_failed'], isFalse);
      expect(out['last_message_needs_session'], isNot(true));
      // The non-target envelope is never even parsed (no AEAD attempt).
      verifyNever(() => bob.cipher.isSenderKeyEnvelope('bundle-for-carol'));
    });

    test('decryptInboxRow still routes a distribution row addressed to ME '
        'through the group path (bundle processed, row hidden)', () async {
      // A REAL alice→bob distribution envelope (X3DH init — bob is the
      // responder), exactly like the loadMessages path.
      final aliceSvc = alice.service();
      await aliceSvc.sendMessage(_groupChatId, 'hola grupo', null);
      final bobEnvelope = alice.inserts
          .firstWhere((r) => r['recipient_id'] == _memberBobId)['content']
          as String;

      final bobService = bob.service();
      final out = await bobService.decryptInboxRow({
        'chat_id': _groupChatId,
        'type': 'group',
        'last_message_id': 'm-me',
        'last_message_sender_id': _userId,
        'last_message_recipient_id': _memberBobId,
        'last_message_content': bobEnvelope,
      });

      expect(out['last_message_content'], isNull);
      expect(out['last_message_decrypt_failed'], isFalse);
      verify(() => bob.cipher.processSenderKeyBundle(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            groupId: _groupId,
            bundleJson: _bundleJson,
          )).called(1);
    });

    test('group sends never open a 1:1 session under the real chatId — the '
        'pairwise distribution namespace is used instead', () async {
      final svc = alice.service();
      await svc.sendMessage(_groupChatId, 'hola', null);

      // The pairwise distribution session lives under the synthetic
      // 'g:<chatId>:<peer>' key…
      expect(await alice.sessions.loadSession(
        'g:$_groupChatId:$_memberBobId',
      ), isNotNull);
      // …and the real chatId (the 1:1 namespace) was NEVER used — pinning
      // that _resolvePeerUserId is not on the group path.
      expect(await alice.sessions.loadSession(_groupChatId), isNull);
    });

    test('two concurrent sends on the same group chat serialize their '
        'cipher encrypts (no overlap → no AEAD key/nonce reuse) and BOTH '
        'messages land', () async {
      // Re-stub the fake cipher's encrypt with a Completer-gated overlap
      // detector: pre-fix two in-flight sends load the same chain root,
      // derive the same message key and emit two envelopes with the same
      // AEAD (key, nonce) — GCM nonce reuse (and the second message drops
      // as a replay on receivers). The per-chat send mutex must keep the
      // encrypts strictly non-overlapping.
      final trace = <String>[];
      var active = 0;
      var maxActive = 0;
      final gates = [Completer<void>(), Completer<void>()];
      var call = 0;
      when(() => alice.cipher.encrypt(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            groupId: any(named: 'groupId'),
            plaintext: any(named: 'plaintext'),
          )).thenAnswer((inv) async {
        final idx = call++;
        trace.add('$idx-start');
        active++;
        if (active > maxActive) maxActive = active;
        await gates[idx].future;
        active--;
        trace.add('$idx-end');
        return alice.messageEnvelope;
      });

      final svc = alice.service();
      final first = svc.sendMessage(_groupChatId, 'primera', null);
      final second = svc.sendMessage(_groupChatId, 'segunda', null);
      // Let both calls progress as far as they can: pre-fix both are inside
      // encrypt (blocked on the gates); fixed, the second is still queued
      // behind the first on the per-chat send tail.
      await pumpEventQueue();
      gates[0].complete();
      await pumpEventQueue();
      gates[1].complete();
      await Future.wait([first, second]);

      // Both sends succeeded: distribution + message row per send.
      expect(alice.inserts, hasLength(4));
      expect(
        alice.inserts.where((r) => r['recipient_id'] == null),
        hasLength(2),
        reason: 'both message rows must land',
      );
      expect(
        alice.inserts.where((r) => r['recipient_id'] == _memberBobId),
        hasLength(2),
        reason: 'both distribution rows must land',
      );
      // The cipher's encrypt was called exactly twice…
      verify(() => alice.cipher.encrypt(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            groupId: _groupId,
            plaintext: any(named: 'plaintext'),
          )).called(2);
      // …with strictly serialized invocations: call 1 must not start before
      // call 0 ends (no overlapping encrypt = no shared chain position).
      expect(trace, ['0-start', '0-end', '1-start', '1-end'],
          reason: 'the per-chat send mutex must serialize the two encrypts');
      expect(maxActive, 1);
    });

    test('the distribution decrypt path cross-checks the bundle ik_dh '
        'against the pairwise session\'s BOUND peer identity — a '
        'spoofed-ik_dh bundle is rejected end-to-end (K1)', () async {
      // Swap bob's fake cipher for the REAL cipher bound to bob's own
      // keys/sessions (the identity whose bundle is published on the
      // server): only the real processSenderKeyBundle applies the
      // expectedSenderIkDh check — a mock would accept anything.
      bob.cipher = GroupE2eeCipher(
        keyStore: bob.keys,
        sessionStore: bob.sessions,
      );
      final aliceSvc = alice.service();
      final bobSvc = bob.service();

      // Round 1: distribute a NON-bundle plaintext first — the pairwise
      // session must EXIST (bound to alice's REAL ik_dh) before the spoofed
      // bundle arrives, otherwise there is no bound identity to check.
      when(() => alice.cipher.senderKeyBundleJson(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => 'no-bundle-yet');
      await aliceSvc.sendMessage(_groupChatId, 'primera', null);
      await bobSvc.loadMessages(_groupChatId);
      expect(
        await bob.sessions.loadSession('g:$_groupChatId:$_userId'),
        isNotNull,
        reason: 'the pairwise session must be established before the spoof',
      );

      // Round 2: the SPOOFED bundle (fake cipher default): sender_user_id is
      // alice (RLS-bound) but sender_ik_dh is a FOREIGN key — the K1 attack
      // shape (a learned published key, NOT alice's bound identity).
      final aliceIkDh =
          base64UrlNoPadEncode((await alice.keys.loadOrCreateIdentity()).ikDhPublic);
      final spoofedIkDh = (jsonDecode(_bundleJson) as Map)['sender_ik_dh']
          as String;
      expect(spoofedIkDh, isNot(aliceIkDh),
          reason: 'the harness bundle must genuinely carry a foreign ik_dh');
      when(() => alice.cipher.senderKeyBundleJson(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => _bundleJson);
      await aliceSvc.sendMessage(_groupChatId, 'segunda', null);
      await bobSvc.loadMessages(_groupChatId);

      // End-to-end: bob did NOT process the spoofed bundle — no sender-key
      // record exists for alice even though the pairwise decrypt succeeded.
      expect(
        await bob.sessions.loadSession(
          '${GroupE2eeCipher.senderKeyKeyPrefix}$_groupId:$_userId',
        ),
        isNull,
        reason: 'a bundle whose ik_dh the delivering pairwise session did '
            'not bind must never be accepted (K1 identity binding)',
      );
    });

    test('the distribution decrypt path ACCEPTS a bundle whose ik_dh IS the '
        'pairwise session\'s bound peer identity (the wiring passes the '
        'bound key through)', () async {
      bob.cipher = GroupE2eeCipher(
        keyStore: bob.keys,
        sessionStore: bob.sessions,
      );
      final aliceSvc = alice.service();
      final bobSvc = bob.service();

      // Establish the pairwise session (round 1, non-bundle plaintext).
      when(() => alice.cipher.senderKeyBundleJson(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => 'no-bundle-yet');
      await aliceSvc.sendMessage(_groupChatId, 'primera', null);
      await bobSvc.loadMessages(_groupChatId);

      // Round 2: a GENUINE bundle minted by alice's real identity — its
      // ik_dh equals the key the pairwise session bound.
      final realAliceGroup = GroupE2eeCipher(
        keyStore: alice.keys,
        sessionStore: alice.sessions,
      );
      final realBundle = await realAliceGroup.senderKeyBundleJson(
        groupChatId: _groupChatId,
        senderUserId: _userId,
        groupId: _groupId,
      );
      when(() => alice.cipher.senderKeyBundleJson(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => realBundle);
      await aliceSvc.sendMessage(_groupChatId, 'segunda', null);
      await bobSvc.loadMessages(_groupChatId);

      final record = await bob.sessions.loadSession(
        '${GroupE2eeCipher.senderKeyKeyPrefix}$_groupId:$_userId',
      );
      expect(record, isNotNull,
          reason: 'the genuine bundle must be accepted (the reinstall-heal '
              'path keeps working when the pairwise session bound the NEW '
              'identity)');
      final saved = jsonDecode(record!) as Map;
      expect(saved['sender_ik_dh'],
          base64UrlNoPadEncode(
              (await alice.keys.loadOrCreateIdentity()).ikDhPublic),
          reason: 'the saved record carries alice\'s bound identity');
    });

    test('1:1 concurrent sends on the same chat serialize their pairwise '
        'cipher encrypts (no overlap → no AEAD key/nonce reuse) and BOTH '
        'messages land (K1 — the _sendTail mutex pins the 1:1 path)',
        () async {
      // Re-point the chat metadata to a DIRECT chat so the send never
      // routes to the group path: the 1:1 path uses the REAL pairwise
      // E2eeSession created inside the service (the harness's real crypto
      // machinery — X3DH + ratchet).
      when(() => alice.chatsQb.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'type': 'direct', 'reference_id': null},
        ),
      );
      // Gate the pairwise session's persistence — saveSession is the FINAL
      // step of the real encrypt. Two overlapping encrypts would enter it
      // concurrently (pre-fix: both load the same ratchet position and emit
      // two envelopes with the same AEAD key + nonce — GCM nonce reuse).
      final gated = _GatedSessionStore(alice.sessions);
      final svc = alice.service(sessionStore: gated);

      final first = svc.sendMessage(_chatId, 'primera', null);
      final second = svc.sendMessage(_chatId, 'segunda', null);
      // Pre-fix both encrypts are inside saveSession (blocked on the
      // gates); fixed, the second send is still queued behind the first on
      // the per-chat send tail.
      await pumpEventQueue();
      expect(gated.trace, ['0-start'],
          reason: 'only the first encrypt may be in flight');
      gated.gates[0].complete();
      await pumpEventQueue();
      expect(gated.trace, ['0-start', '0-end', '1-start'],
          reason: 'the second encrypt starts only after the first completed');
      gated.gates[1].complete();
      await Future.wait([first, second]);

      // Both messages inserted as DISTINCT envelopes (serialized chain
      // positions — never the same AEAD key/nonce).
      expect(alice.inserts, hasLength(2));
      expect(alice.inserts[0]['chat_id'], _chatId);
      expect(alice.inserts[0]['sender_id'], _userId);
      expect(alice.inserts[0]['content'], isNot(alice.inserts[1]['content']),
          reason: 'two envelopes from the same chain position would be '
              'byte-identical');
      expect(gated.trace, ['0-start', '0-end', '1-start', '1-end']);
      expect(gated.maxActive, 1,
          reason: 'the per-chat send mutex must serialize the two encrypts');
    });

    test('a group 0x03 message dropped with missingChain fires ONE key-'
        'request row addressed to the sender (Signal retry-request heal, '
        'throttled per (chat, sender))', () async {
      // Bob's device has no sender-key record for alice (missed/stale
      // bundle class): the 0x03 decrypt verdict is a missing-chain drop.
      bob.decryptResults[bob.messageEnvelope] =
          const E2eeDecryptResult.dropped(missingChain: true);
      await alice.prekeyService.publishAll();
      server.rows.insert(0, {
        'id': 'msg-a1',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': bob.messageEnvelope,
        'created_at': '2026-08-17T00:00:01Z',
      });
      server.rows.insert(0, {
        'id': 'msg-a2',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': bob.messageEnvelope,
        'created_at': '2026-08-17T00:00:02Z',
      });
      server.rows.insert(0, {
        'id': 'msg-a3',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': bob.messageEnvelope,
        'created_at': '2026-08-17T00:00:03Z',
      });

      final bobService = bob.service();
      final rows = await bobService.loadMessages(_groupChatId);

      // The dropped rows are hidden (Signal semantics), never bubbles.
      expect(rows.every((r) => r['decryptDropped'] == true), isTrue);

      // EXACTLY ONE request row: recipient = the chain owner (alice),
      // content = a REAL pairwise envelope of the request JSON (the row's
      // sender_id — bob — is the RLS-bound requester).
      final requests = bob.inserts
          .where((r) => r['recipient_id'] == _userId)
          .toList();
      expect(requests, hasLength(1),
          reason: 'the key request is throttled per (chat, sender)');
      final requestRow = requests.single;
      expect(requestRow['chat_id'], _groupChatId);
      expect(requestRow['sender_id'], _memberBobId);
      final reqEnv = base64UrlNoPadDecode(requestRow['content'] as String)!;
      final parsed = SamayEnvelope.tryParse(reqEnv);
      expect(
        parsed?.type == e2eeEnvelopeTypeInit ||
            parsed?.type == e2eeEnvelopeTypeRatchet,
        isTrue,
        reason: 'requests ride the pairwise channel (X3DH/ratchet envelope)',
      );
    });

    test('a pairwise row whose plaintext is a key REQUEST for MY chain '
        'un-marks the requester and re-distributes the bundle immediately',
        () async {
      final aliceSvc = alice.service();
      final bobSvc = bob.service();
      // Establish the pairwise session both ways (round 1: alice
      // distributes her bundle; bob processes it).
      await aliceSvc.sendMessage(_groupChatId, 'hola', null);
      await bobSvc.loadMessages(_groupChatId);
      expect(
        await bob.sessions.loadSession('g:$_groupChatId:$_userId'),
        isNotNull,
        reason: 'the pairwise session must exist before the request',
      );

      // Bob's device crafts a key request for alice's chain and it lands as
      // a pairwise row addressed to alice (the deadlock-heal message).
      final bobPair = E2eeSession(
        chatId: 'g:$_groupChatId:$_userId',
        peerUserId: _userId,
        keyStore: bob.keys,
        sessionStore: bob.sessions,
        prekeyService: bob.prekeyService,
      );
      final requestEnvelope = await bobPair.encrypt(
        chatId: 'g:$_groupChatId:$_userId',
        peerUserId: _userId,
        plaintext: _requestJson,
      );
      server.rows.insert(0, {
        'id': 'msg-req',
        'chat_id': _groupChatId,
        'sender_id': _memberBobId,
        'recipient_id': _userId,
        'content': requestEnvelope,
        'created_at': '2026-08-17T00:01:00Z',
      });

      final rows = await aliceSvc.loadMessages(_groupChatId);

      // The request row is hidden (never a bubble)…
      expect(rows.singleWhere((r) => r['id'] == 'msg-req')['decryptDropped'],
          isTrue);
      // …and alice un-marked bob + immediately re-distributed her chain: a
      // fresh distribution row addressed to bob lands (the heal).
      expect(alice.inserts.last['recipient_id'], _memberBobId);
      expect(alice.inserts.last['chat_id'], _groupChatId);
      verify(() => alice.cipher.unmarkSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberBobId],
          )).called(1);
      // The mark was called TWICE total: once for the round-1 distribution
      // (the initial send) and once for the request-heal re-distribution.
      verify(() => alice.cipher.markSenderKeyDistributed(
            groupChatId: _groupChatId,
            senderUserId: _userId,
            memberIds: [_memberBobId],
          )).called(2);
    });

    test('a key request for ANOTHER member\'s chain is ignored — no unmark, '
        'no re-distribution (defensive cross-chain guard)', () async {
      final aliceSvc = alice.service();
      await aliceSvc.sendMessage(_groupChatId, 'hola', null);
      when(() => alice.cipher.senderKeyRequestTarget(
            json: any(named: 'json'),
            groupChatId: any(named: 'groupChatId'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => _memberCarolId);

      final bobPair = E2eeSession(
        chatId: 'g:$_groupChatId:$_userId',
        peerUserId: _userId,
        keyStore: bob.keys,
        sessionStore: bob.sessions,
        prekeyService: bob.prekeyService,
      );
      final requestEnvelope = await bobPair.encrypt(
        chatId: 'g:$_groupChatId:$_userId',
        peerUserId: _userId,
        plaintext: _requestJson,
      );
      server.rows.insert(0, {
        'id': 'msg-req-other',
        'chat_id': _groupChatId,
        'sender_id': _memberBobId,
        'recipient_id': _userId,
        'content': requestEnvelope,
        'created_at': '2026-08-17T00:02:00Z',
      });

      final insertsBefore = alice.inserts.length;
      await aliceSvc.loadMessages(_groupChatId);

      expect(alice.inserts.length, insertsBefore,
          reason: 'a request for someone else\'s chain must not trigger a '
              're-distribution');
      verifyNever(() => alice.cipher.unmarkSenderKeyDistributed(
            groupChatId: any(named: 'groupChatId'),
            senderUserId: any(named: 'senderUserId'),
            memberIds: any(named: 'memberIds'),
          ));
    });

    test('end-to-end deadlock heal: a member who LOST the sender-key chain '
        'requests re-distribution and the NEXT message decrypts '
        '(2026-08-17)', () async {
      // Both parties use REAL group ciphers (key-holding operations real).
      alice.cipher = GroupE2eeCipher(
        keyStore: alice.keys,
        sessionStore: alice.sessions,
      );
      bob.cipher = GroupE2eeCipher(
        keyStore: bob.keys,
        sessionStore: bob.sessions,
      );
      await alice.prekeyService.publishAll();
      server.roster = [_userId, _memberBobId];

      final aliceSvc = alice.service();
      final bobSvc = bob.service();

      // Round 1: healthy distribution — bob receives alice's chain + msg1.
      await aliceSvc.sendMessage(_groupChatId, 'msg1', null);
      await bobSvc.loadMessages(_groupChatId);
      expect(
        await bob.sessions.loadSession(
          '${GroupE2eeCipher.senderKeyKeyPrefix}$_groupId:$_userId',
        ),
        isNotNull,
        reason: 'round 1 must distribute the chain to bob',
      );

      // Round 2: bob's device LOST the chain (the stale/missed-bundle
      // class). Alice still believes bob distributed → NO re-distribution
      // on the next send (the deadlock the user hit: msg2 arrives to
      // everyone except the member who missed the chain).
      await bob.cipher.wipeGroupKeys(_groupChatId);
      await aliceSvc.sendMessage(_groupChatId, 'msg2', null);
      expect(
        alice.inserts.where((r) => r['recipient_id'] == _memberBobId),
        hasLength(1),
        reason: 'only the round-1 distribution exists — bob is marked '
            'distributed, so msg2 sends no bundle (deadlock)',
      );

      // Bob loads: msg2 is a missing-chain drop and his device requests
      // alice's chain (one request, throttled).
      var bobRows = await bobSvc.loadMessages(_groupChatId);
      expect(bobRows.any((r) => r['content'] == 'msg2'), isFalse,
          reason: 'msg2 cannot decrypt without the chain (missing-chain drop)');
      expect(
        server.rows
            .where((r) =>
                r['sender_id'] == _memberBobId && r['recipient_id'] == _userId)
            .length,
        1,
        reason: 'bob\'s device requested the missing chain',
      );

      // Alice's device processes the request: un-marks bob and re-distributes
      // her chain to him immediately.
      await aliceSvc.loadMessages(_groupChatId);
      expect(alice.inserts.last['recipient_id'], _memberBobId,
          reason: 'alice re-distributed her chain to bob on the request');

      // Bob processes the fresh bundle → the record is restored.
      await bobSvc.loadMessages(_groupChatId);
      expect(
        await bob.sessions.loadSession(
          '${GroupE2eeCipher.senderKeyKeyPrefix}$_groupId:$_userId',
        ),
        isNotNull,
        reason: 'the re-distributed bundle heals bob\'s device',
      );

      // Round 3: the next message decrypts — the heal is complete.
      await aliceSvc.sendMessage(_groupChatId, 'msg3', null);
      bobRows = await bobSvc.loadMessages(_groupChatId);
      expect(bobRows.any((r) => r['content'] == 'msg3'), isTrue,
          reason: 'the healed chain decrypts the next message');
    });

    test('markMessagesRead routes by chat type (20260817000006): GROUP chats '
        'call mark_group_messages_read, DIRECT chats keep '
        'mark_messages_read', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>(null);

      // Group chat (the harness default: chatsQb → type group).
      when(() => alice.client.rpc(
            'mark_group_messages_read',
            params: any(named: 'params'),
          )).thenAnswer((_) => rpc);
      final svc = alice.service();
      await svc.markMessagesRead(_groupChatId);
      verify(() => alice.client.rpc('mark_group_messages_read',
              params: {'p_chat_id': _groupChatId}))
          .called(1);
      verifyNever(() => alice.client.rpc(
            'mark_messages_read',
            params: any(named: 'params'),
          ));

      // Direct chat: re-point the chat metadata and re-stub the RPC.
      when(() => alice.chatsQb.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'type': 'direct', 'reference_id': null},
        ),
      );
      when(() => alice.client.rpc(
            'mark_messages_read',
            params: any(named: 'params'),
          )).thenAnswer((_) => rpc);
      final directSvc = alice.service();
      await directSvc.markMessagesRead(_chatId);
      verify(() => alice.client.rpc('mark_messages_read',
              params: {'p_chat_id': _chatId}))
          .called(1);
    });

    test('loadMessages (group) passes the embedded message_reads read set '
        'through untouched (20260817000006)', () async {
      final aliceSvc = alice.service();
      await aliceSvc.sendMessage(_groupChatId, 'hola grupo', null);
      server.rows.insert(0, {
        'id': 'msg-with-reads',
        'chat_id': _groupChatId,
        'sender_id': _userId,
        'content': alice.messageEnvelope,
        'created_at': '2026-08-17T00:10:00Z',
        'message_reads': [
          {'user_id': _memberBobId, 'read_at': '2026-08-17T00:11:00Z'},
        ],
      });

      final bobService = bob.service();
      final rows = await bobService.loadMessages(_groupChatId);

      final withReads = rows.firstWhere((r) => r['id'] == 'msg-with-reads');
      expect(withReads['message_reads'], isA<List<dynamic>>());
      expect(
        (withReads['message_reads'] as List).single['user_id'],
        _memberBobId,
      );
    });

    test('subscribeToGroupMessageReads delegates to the realtime '
        'message-reads INSERT channel (20260817000006)', () async {
      final channel = MockRealtimeChannel();
      when(() => client.channel('message-reads:$_groupChatId'))
          .thenReturn(channel);
      when(() => channel.onPostgresChanges(
            event: any(named: 'event'),
            schema: any(named: 'schema'),
            table: any(named: 'table'),
            callback: any(named: 'callback'),
          )).thenReturn(channel);
      when(() => channel.subscribe()).thenReturn(channel);

      final returned = service().subscribeToGroupMessageReads(
        _groupChatId,
        (_) {},
      );

      expect(returned, same(channel));
      verify(() => client.channel('message-reads:$_groupChatId')).called(1);
      verify(() => channel.onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'message_reads',
            callback: any(named: 'callback'),
          )).called(1);
      verify(() => channel.subscribe()).called(1);
    });
  });
}

class _FakePrekeyService implements E2eePrekeyService {
  @override
  Future<PrekeyBundle?> fetchBundle(String peerUserId) async => null;

  @override
  Future<void> publishAll() async {}

  @override
  Future<void> handleMissingSession() async {}
}

/// ---------------------------------------------------------------------------
/// ISSUE 4 group harness: real pairwise E2EE + a FAKE GroupE2eeCipher
/// ---------------------------------------------------------------------------
const _groupChatId = '77777777-7777-7777-7777-777777777777';
const _groupId = '33333333-3333-3333-3333-333333333333';
const _memberBobId = '22222222-2222-2222-2222-222222222222';
const _memberCarolId = '55555555-5555-5555-5555-555555555555';

/// The bundle the FAKE group cipher hands out on distribution. `isSenderKeyBundle`
/// routes on the real `kind` marker, so it must be a well-formed bundle JSON.
/// v3 wire shape (2026-08-17 rekey epochs): carries `epoch` + `chat_id` so a
/// future real-cipher switch validates it (and the epoch guard) instead of
/// silently rejecting a v1-shaped bundle.
const _bundleJson = '{'
    '"v":$e2eeSenderKeyBundleVersion,'
    '"kind":"samay.group_sender_key",'
    '"group_id":"33333333-3333-3333-3333-333333333333",'
    '"chat_id":"77777777-7777-7777-7777-777777777777",'
    '"sender_user_id":"11111111-1111-1111-1111-111111111111",'
    '"sender_ik_dh":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",'
    '"chain_root":"ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-P0A",'
    '"chain_index":0,'
    '"epoch":0,'
    '"created_at":"2026-08-16T00:00:00Z"'
    '}';

/// The request payload the FAKE group cipher hands out on
/// `senderKeyRequestJson` — well-formed so the REAL `isSenderKeyRequest` /
/// `senderKeyRequestTarget` parsers route it (2026-08-17 retry protocol).
const _requestJson = '{'
    '"v":$e2eeGroupKeyRequestVersion,'
    '"kind":"samay.group_key_request",'
    '"group_id":"33333333-3333-3333-3333-333333333333",'
    '"chat_id":"77777777-7777-7777-7777-777777777777",'
    '"for_sender_user_id":"11111111-1111-1111-1111-111111111111"'
    '}';

/// Real type-0x03 sender-key envelope with a deterministic key (the FAKE
/// cipher's "encrypt" output — structurally valid so the real
/// `isSenderKeyEnvelope` parser routes it to the 0x03 path).
Future<String> _makeSenderKeyEnvelope(String plaintext) async {
  final material = Uint8List.fromList(List.generate(44, (i) => i));
  final ciphertext = await aesGcmEncrypt(
    key: Uint8List.sublistView(material, 0, e2eeAeadKeyLength),
    nonce: Uint8List.sublistView(material, e2eeAeadKeyLength),
    plaintext: utf8Bytes(plaintext),
    aad: Uint8List(0),
  );
  return base64UrlNoPadEncode(
    SamayEnvelope.senderKey(
      senderIkDh: Uint8List.fromList(List.generate(32, (i) => i + 1)),
      groupId: groupIdToBytes(_groupId),
      chainIndex: 0,
      ciphertext: ciphertext,
    ).encode(),
  );
}

class _MockGroupCipher extends Mock implements GroupE2eeCipher {}

class _MockRealtimeService extends Mock implements RealtimeService {}

/// In-memory Supabase stand-in: per-user published prekey rows (atomic OPK
/// consumption), message rows newest-first, and the chat roster.
class _GroupFakeServer {
  _GroupFakeServer({required this.chatId});

  final String chatId;
  final Map<String, Map<String, dynamic>> prekeys = {};
  final List<Map<String, dynamic>> rows = [];
  List<String> roster = [];
  int _nextMessageId = 0;

  List<Map<String, dynamic>> messagesFor() =>
      rows.where((r) => r['chat_id'] == chatId).toList();

  Map<String, dynamic>? fetchBundle(String userId) {
    final row = prekeys[userId];
    if (row == null) return null;
    final remaining = (row['one_time_prekeys'] as List).toList();
    Map<String, dynamic>? popped;
    if (remaining.isNotEmpty) {
      popped = Map<String, dynamic>.from(remaining.removeAt(0) as Map);
      row['one_time_prekeys'] = remaining;
    }
    return {
      'user_id': userId,
      'identity_key': row['identity_key'],
      'identity_sig_key': row['identity_sig_key'],
      'signed_prekey_id': row['signed_prekey_id'],
      'signed_prekey': row['signed_prekey'],
      'signed_prekey_sig': row['signed_prekey_sig'],
      'one_time_prekey': popped,
    };
  }

  void insertMessage(String senderId, Map<String, dynamic> payload) {
    rows.insert(0, {
      'id': 'msg-${_nextMessageId++}',
      'chat_id': chatId,
      'sender_id': senderId,
      ...payload,
    });
  }
}

class _GroupParty {
  _GroupParty({
    required this.userId,
    required this.server,
    required this.messageEnvelope,
  }) {
    keys = MemoryE2eeKeyStore();
    sessions = MemoryE2eeSessionStore();
    plaintext = MemoryMessagePlaintextStore();
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    messagesQb = MockQueryBuilder();
    participantsQb = MockQueryBuilder();
    chatsQb = MockQueryBuilder();
    prekeysQb = MockQueryBuilder();
    cipher = _MockGroupCipher();

    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenReturn(User.fromJson({'id': userId}));

    when(() => client.from('messages')).thenAnswer((_) => messagesQb);
    when(() => messagesQb.select(any())).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () => server.messagesFor(),
      ),
    );
    when(() => messagesQb.insert(any())).thenAnswer((inv) {
      final payload =
          Map<String, dynamic>.from(inv.positionalArguments.first as Map);
      inserts.add(payload);
      server.insertMessage(userId, payload);
      return _FixedFilter<dynamic>(null);
    });

    when(() => client.from('chat_participants')).thenAnswer((_) => participantsQb);
    when(() => participantsQb.select(any())).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () => [for (final uid in server.roster) {'user_id': uid}],
      ),
    );

    // Chat-type resolution: the group chat row (type + reference_id).
    when(() => client.from('chats')).thenAnswer((_) => chatsQb);
    when(() => chatsQb.select(any())).thenAnswer(
      (_) => ResolvingBuilder<PostgrestList>({
        'type': 'group',
        'reference_id': _groupId,
      }),
    );

    when(() => client.from(SupabaseE2eePrekeyService.tableName))
        .thenAnswer((_) => prekeysQb);
    when(() => prekeysQb.select()).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () {
          final row = server.prekeys[userId];
          return row == null ? const [] : [Map<String, dynamic>.from(row)];
        },
      ),
    );
    when(() => prekeysQb.select(any())).thenAnswer(
      (_) => _ServerFilter<List<Map<String, dynamic>>>(
        () {
          final row = server.prekeys[userId];
          return row == null ? const [] : [Map<String, dynamic>.from(row)];
        },
      ),
    );
    when(() => prekeysQb.upsert(any(), onConflict: any(named: 'onConflict')))
        .thenAnswer((inv) {
      server.prekeys[userId] = {
        'consumed_one_time_prekeys': const [],
        ...Map<String, dynamic>.from(inv.positionalArguments.first as Map),
      };
      return _FixedFilter<dynamic>(null);
    });

    when(() => client.rpc('fetch_prekey_bundle', params: any(named: 'params')))
        .thenAnswer((inv) {
      final params = inv.namedArguments[#params] as Map;
      return _FixedFilter<dynamic>(
        server.fetchBundle(params['p_user_id'] as String),
      );
    });

    // The FAKE group cipher. Key-holding operations are stubbed; format
    // checks use the real parsers so routing behaves like production. The
    // K1 identity-binding tests swap in a REAL cipher (same keys/sessions)
    // before building the service — only the real processSenderKeyBundle
    // can reject a spoofed bundle.
    when(() => cipher.isSenderKeyEnvelope(any())).thenAnswer((inv) async {
      final env = inv.positionalArguments.first as String;
      final bytes = base64UrlNoPadDecode(env);
      return bytes != null &&
          SamayEnvelope.tryParse(bytes)?.type == e2eeEnvelopeTypeSenderKey;
    });
    when(() => cipher.isSenderKeyBundle(any())).thenAnswer((inv) async {
      final plaintext = inv.positionalArguments.first as String;
      try {
        final decoded = jsonDecode(plaintext);
        return decoded is Map && decoded['kind'] == e2eeSenderKeyBundleKind;
      } on FormatException {
        return false;
      }
    });
    when(() => cipher.senderKeyBundleJson(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          groupId: any(named: 'groupId'),
        )).thenAnswer((_) async => _bundleJson);
    when(() => cipher.membersMissingSenderKey(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          activeMemberIds: any(named: 'activeMemberIds'),
        )).thenAnswer((inv) async {
      final roster =
          (inv.namedArguments[#activeMemberIds] as List).cast<String>();
      final me = inv.namedArguments[#senderUserId] as String;
      // The fake never "holds" anyone's chain — every other member is missing.
      return [for (final m in roster) if (m != me) m];
    });
    when(() => cipher.wipeGroupKeys(any())).thenAnswer((_) async {});
    when(() => cipher.markSenderKeyDistributed(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          memberIds: any(named: 'memberIds'),
        )).thenAnswer((_) async {});
    when(() => cipher.unmarkSenderKeyDistributed(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          memberIds: any(named: 'memberIds'),
        )).thenAnswer((_) async {});
    when(() => cipher.isSenderKeyRequest(any())).thenAnswer((inv) async {
      final plaintext = inv.positionalArguments.first as String;
      try {
        final decoded = jsonDecode(plaintext);
        return decoded is Map && decoded['kind'] == e2eeGroupKeyRequestKind;
      } on FormatException {
        return false;
      }
    });
    when(() => cipher.senderKeyRequestJson(
          groupChatId: any(named: 'groupChatId'),
          groupId: any(named: 'groupId'),
          missingSenderUserId: any(named: 'missingSenderUserId'),
        )).thenAnswer((_) async => _requestJson);
    when(() => cipher.senderKeyRequestTarget(
          json: any(named: 'json'),
          groupChatId: any(named: 'groupChatId'),
          groupId: any(named: 'groupId'),
        )).thenAnswer((inv) async {
      final json = inv.namedArguments[#json] as String;
      final chatId = inv.namedArguments[#groupChatId] as String;
      final groupId = inv.namedArguments[#groupId] as String;
      try {
        final decoded = jsonDecode(json);
        if (decoded is! Map) return null;
        final map = Map<String, dynamic>.from(decoded);
        if (map['kind'] != e2eeGroupKeyRequestKind ||
            map['v'] != e2eeGroupKeyRequestVersion ||
            map['group_id'] != groupId ||
            map['chat_id'] != chatId) {
          return null;
        }
        return map['for_sender_user_id'] is String
            ? map['for_sender_user_id'] as String
            : null;
      } on FormatException {
        return null;
      }
    });
    when(() => cipher.processSenderKeyBundle(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          groupId: any(named: 'groupId'),
          bundleJson: any(named: 'bundleJson'),
        )).thenAnswer((_) async {});
    when(() => cipher.encrypt(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          groupId: any(named: 'groupId'),
          plaintext: any(named: 'plaintext'),
        )).thenAnswer((_) async => messageEnvelope);
    when(() => cipher.decrypt(
          groupChatId: any(named: 'groupChatId'),
          senderUserId: any(named: 'senderUserId'),
          envelope: any(named: 'envelope'),
        )).thenAnswer((inv) async {
      final env = inv.namedArguments[#envelope] as String;
      return decryptResults[env] ?? const E2eeDecryptResult.plaintext('hola grupo');
    });

    prekeyService = SupabaseE2eePrekeyService(client: client, keyStore: keys);
  }

  final String userId;
  final _GroupFakeServer server;
  late final MemoryE2eeKeyStore keys;
  late final MemoryE2eeSessionStore sessions;
  late final MemoryMessagePlaintextStore plaintext;
  late final MockSupabaseClient client;
  late final MockGoTrueClient auth;
  late final MockQueryBuilder messagesQb;
  late final MockQueryBuilder participantsQb;
  late final MockQueryBuilder chatsQb;
  late final MockQueryBuilder prekeysQb;

  /// The group cipher the service is built with. Defaults to the mocktail
  /// fake; the K1 identity-binding tests REPLACE it with a real
  /// [GroupE2eeCipher] bound to [keys]/[sessions] (the fake can only
  /// accept — only the real `processSenderKeyBundle` applies the
  /// expectedSenderIkDh check).
  late GroupE2eeCipher cipher;
  late final SupabaseE2eePrekeyService prekeyService;

  /// Insert payloads captured in call order (distribution rows first, then
  /// the message row).
  final List<Map<String, dynamic>> inserts = [];

  /// Per-envelope decrypt verdicts for the FAKE group cipher (default:
  /// plaintext).
  final Map<String, E2eeDecryptResult> decryptResults = {};

  /// A structurally real type-0x03 envelope — the fake cipher's "encrypt"
  /// output.
  final String messageEnvelope;

  ChatService service({
    RealtimeService? realtime,
    E2eeSessionStore? sessionStore,
    Duration rosterTtl = const Duration(seconds: 30),
  }) =>
      ChatService(
        client: client,
        realtime: realtime ?? RealtimeService(client: client),
        e2eeKeyStore: keys,
        e2eeSessionStore: sessionStore ?? sessions,
        e2eePrekeyService: prekeyService,
        plaintextStore: plaintext,
        groupCipher: cipher,
        groupRosterTtl: rosterTtl,
      );
}

/// Wraps an [E2eeSessionStore] and gates every `saveSession` on a Completer —
/// the overlap detector for the 1:1 concurrent-send pin: the pairwise encrypt
/// persists the session as its FINAL step, so two overlapping encrypts would
/// enter saveSession concurrently (pre-serial both derive the same ratchet
/// position and emit two envelopes with the same AEAD key + nonce).
class _GatedSessionStore implements E2eeSessionStore {
  _GatedSessionStore(this._inner);

  final E2eeSessionStore _inner;

  /// One gate per expected saveSession call (the two sends).
  final List<Completer<void>> gates = [Completer<void>(), Completer<void>()];

  /// Enter/leave trace of the gated saveSession calls.
  final List<String> trace = [];

  int _call = 0;
  int _active = 0;

  /// Peak number of saveSession calls in flight — MUST stay 1 (serialized
  /// encrypts) for the pin to hold.
  int maxActive = 0;

  @override
  Future<String?> loadSession(String chatId) => _inner.loadSession(chatId);

  @override
  Future<void> saveSession(String chatId, String json) async {
    final idx = _call++;
    trace.add('$idx-start');
    _active++;
    if (_active > maxActive) maxActive = _active;
    await gates[idx].future;
    _active--;
    trace.add('$idx-end');
    return _inner.saveSession(chatId, json);
  }

  @override
  Future<void> deleteSession(String chatId) => _inner.deleteSession(chatId);

  @override
  Future<Map<String, String>> sessionIndex() => _inner.sessionIndex();

  @override
  Future<void> sweepExpiredSessions({int maxAgeDays = 90}) =>
      _inner.sweepExpiredSessions(maxAgeDays: maxAgeDays);

  @override
  Future<void> wipeAll() => _inner.wipeAll();
}

/// A Postgrest filter that resolves to a value freshly computed at await time
/// (every call sees the current server state).
class _ServerFilter<T> extends PostgrestFilterBuilder<T> {  _ServerFilter(this._resolve)
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
  }) =>
      this;

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
