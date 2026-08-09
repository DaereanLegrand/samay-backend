import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../../support/resolving_builder.dart';

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeService extends Mock implements RealtimeService {}

const _chatId = '33333333-3333-3333-3333-333333333333';
const _otherId = '22222222-2222-2222-2222-222222222222';

void main() {
  late _MockChatService chat;
  late _MockRealtimeService realtime;
  late ChatRepository repo;

  setUp(() {
    chat = _MockChatService();
    realtime = _MockRealtimeService();
    repo = ChatRepository(chat: chat, realtime: realtime);
  });

  group('ChatRepository.loadMessages', () {
    test('delegates to ChatService with the default pagination', () async {
      when(() => chat.loadMessages(_chatId, limit: any(named: 'limit'),
              offset: any(named: 'offset')))
          .thenAnswer((_) async => const [
                {'id': 'm-1', 'sender_id': _otherId, 'content': 'hola',
                 'media_url': null, 'created_at': '2026-08-01T00:00:00Z'},
              ]);

      final rows = await repo.loadMessages(_chatId);

      verify(() => chat.loadMessages(_chatId, limit: 50, offset: 0)).called(1);
      expect(rows.single['content'], 'hola');
    });

    test('forwards explicit limit/offset', () async {
      when(() => chat.loadMessages(_chatId, limit: any(named: 'limit'),
              offset: any(named: 'offset')))
          .thenAnswer((_) async => const []);

      await repo.loadMessages(_chatId, limit: 25, offset: 100);

      verify(() => chat.loadMessages(_chatId, limit: 25, offset: 100))
          .called(1);
    });

    test('propagates service errors unchanged', () async {
      when(() => chat.loadMessages(_chatId, limit: any(named: 'limit'),
              offset: any(named: 'offset')))
          .thenThrow(StateError('no authenticated user'));

      final err = await captureError(() => repo.loadMessages(_chatId));
      expect(err, isA<StateError>());
    });
  });

  group('ChatRepository.sendMessage', () {
    test('delegates content + mediaUrl to ChatService', () async {
      when(() => chat.sendMessage(_chatId, any(), any()))
          .thenAnswer((_) async {});

      await repo.sendMessage(_chatId, 'hola mundo', null);

      verify(() => chat.sendMessage(_chatId, 'hola mundo', null)).called(1);
    });

    test('forwards a media URL when present', () async {
      when(() => chat.sendMessage(_chatId, any(), any()))
          .thenAnswer((_) async {});

      await repo.sendMessage(_chatId, 'foto', 'https://cdn.example/m.png');

      verify(() => chat.sendMessage(_chatId, 'foto', 'https://cdn.example/m.png'))
          .called(1);
    });
  });

  group('ChatRepository.subscribe (E2EE invariant)', () {
    test('delegates to ChatService.subscribeToMessages and returns its channel',
        () async {
      final channel = MockRealtimeChannel();
      when(() => chat.subscribeToMessages(_chatId, any()))
          .thenReturn(channel);

      RealtimeChannel? returned;
      void Function(Map<String, dynamic>)? received;
      when(() => chat.subscribeToMessages(_chatId, captureAny()))
          .thenAnswer((inv) {
        received = inv.positionalArguments.last as void Function(Map<String, dynamic>);
        return channel;
      });

      returned = repo.subscribe(_chatId, (row) {});

      expect(returned, same(channel));
      verify(() => chat.subscribeToMessages(_chatId, any())).called(1);
      expect(received, isNotNull);
    });

    test('MUST NOT bypass ChatService: the raw realtime subscribe is never '
        'called for messages (E2EE decryption lives in ChatService)', () async {
      final channel = MockRealtimeChannel();
      when(() => chat.subscribeToMessages(_chatId, any()))
          .thenReturn(channel);

      repo.subscribe(_chatId, (row) {});

      verifyNever(() => realtime.subscribeToMessages(any(), any()));
    });
  });

  group('ChatRepository.e2eeEnabled', () {
    test('exposes the underlying ChatService flag', () {
      when(() => chat.e2eeEnabled).thenReturn(true);
      expect(repo.e2eeEnabled, isTrue);
      verify(() => chat.e2eeEnabled).called(1);

      when(() => chat.e2eeEnabled).thenReturn(false);
      expect(repo.e2eeEnabled, isFalse);
    });
  });
}
