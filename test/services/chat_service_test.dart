
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/utils/input_sanitizer.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/interfaces.dart';
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
}

class _FakePrekeyService implements E2eePrekeyService {
  @override
  Future<PrekeyBundle?> fetchBundle(String peerUserId) async => null;

  @override
  Future<void> publishAll() async {}

  @override
  Future<void> handleMissingSession() async {}
}
