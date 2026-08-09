import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/chat_message.dart';

void main() {
  const id = 'm001e002-4003-4f04-8a05-6b07c08d09e0';
  const chatId = 'c001d002-e003-4f04-8a05-6b07c08d09e0';
  const senderId = '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60';
  final createdAt = '2026-08-01T22:15:30.123Z';

  final fixture = <String, dynamic>{
    'id': id,
    'chat_id': chatId,
    'sender_id': senderId,
    'content': 'Nos vemos en la entrada',
    'media_url': 'https://cdn.example.test/media/photo.jpg',
    'created_at': createdAt,
  };

  group('ChatMessage', () {
    test('fromJson maps a messages row', () {
      final message = ChatMessage.fromJson(fixture);
      expect(message.id, id);
      expect(message.chatId, chatId);
      expect(message.senderId, senderId);
      expect(message.content, 'Nos vemos en la entrada');
      expect(message.mediaUrl, 'https://cdn.example.test/media/photo.jpg');
      expect(message.createdAt, DateTime.parse(createdAt));
    });

    test('fromJson handles null media_url', () {
      final message = ChatMessage.fromJson({...fixture, 'media_url': null});
      expect(message.mediaUrl, isNull);
    });

    test('fromJson handles a missing media_url key', () {
      final message = ChatMessage.fromJson({
        ...fixture,
      }..remove('media_url'));
      expect(message.mediaUrl, isNull);
    });

    test('toJson emits snake_case DB column names', () {
      final json = ChatMessage.fromJson(fixture).toJson();
      expect(json['id'], id);
      expect(json['chat_id'], chatId);
      expect(json['sender_id'], senderId);
      expect(json['content'], 'Nos vemos en la entrada');
      expect(json['media_url'], fixture['media_url']);
      expect(json['created_at'], createdAt);
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = ChatMessage.fromJson(fixture);
      expect(ChatMessage.fromJson(original.toJson()), original);
    });

    test('copyWith updates only the given field', () {
      final message = ChatMessage.fromJson(fixture);
      final updated = message.copyWith(content: 'Cambié de plan');
      expect(updated.content, 'Cambié de plan');
      expect(updated.chatId, chatId);
      expect(updated.createdAt, DateTime.parse(createdAt));
    });

    test('copyWith can clear nullable fields', () {
      final message = ChatMessage.fromJson(fixture);
      expect(message.copyWith(mediaUrl: null).mediaUrl, isNull);
    });

    test('equality compares all fields', () {
      expect(ChatMessage.fromJson(fixture), ChatMessage.fromJson(fixture));
      expect(
        ChatMessage.fromJson(fixture).copyWith(senderId: 'other'),
        isNot(ChatMessage.fromJson(fixture)),
      );
    });
  });
}
