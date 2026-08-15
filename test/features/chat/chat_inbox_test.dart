import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';

/// ChatInboxNotifier + chatUnreadCountProvider (2026-08-15): the inbox maps
/// the `get_chat_inbox` RPC rows through the E2EE preview decrypt seam, the
/// unread total drives the feed button badge, and markRead re-reads after
/// bumping the watermark.
class _MockChatRepository extends Mock implements ChatRepository {}

void main() {
  late _MockChatRepository repo;

  setUp(() {
    repo = _MockChatRepository();
  });

  ProviderContainer container() => ProviderContainer(overrides: [
        chatE2eeRepositoryProvider.overrideWithValue(repo),
      ]);

  Map<String, dynamic> row({
    String chatId = 'chat-1',
    String peer = 'peer-1',
    int unread = 2,
    String? lastContent = 'SME2.envelope',
  }) =>
      {
        'chat_id': chatId,
        'type': 'direct',
        'peer_id': peer,
        'peer_username': 'bob',
        'last_message_id': 'm-1',
        'last_message_sender_id': peer,
        'last_message_content': lastContent,
        'last_message_created_at': '2026-08-15T00:00:00Z',
        'unread_count': unread,
      };

  test('build maps the RPC rows through the E2EE preview seam', () async {
    when(() => repo.fetchInbox()).thenAnswer(
      (_) async => [row(chatId: 'chat-1', unread: 2), row(chatId: 'chat-2', unread: 5)],
    );
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => {
        ...Map<String, dynamic>.from(inv.positionalArguments.first as Map),
        'last_message_content': 'hola',
        'last_message_decrypt_failed': false,
      },
    );
    final c = container();

    final items = await  c.read(chatInboxProvider.future);

    expect(items, hasLength(2));
    expect(items.first.chatId, 'chat-1');
    expect(items.first.peerUsername, 'bob');
    expect(items.first.unreadCount, 2);
    expect(items.first.lastMessageContent, 'hola');
    expect(items.first.decryptFailed, isFalse);
    verify(() => repo.fetchInbox()).called(1);
    verify(() => repo.decryptInboxRow(any())).called(2);
  });

  test('chatUnreadCountProvider sums every chat unread count', () async {
    when(() => repo.fetchInbox()).thenAnswer(
      (_) async => [row(unread: 2), row(unread: 5), row(unread: 0)],
    );
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
    );
    final c = container();
    await  c.read(chatInboxProvider.future);

    expect( c.read(chatUnreadCountProvider), 7);
  });

  test('chatUnreadCountProvider is 0 while the inbox is loading', () {
    when(() => repo.fetchInbox()).thenAnswer((_) async => []);
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
    );

    expect(container().read(chatUnreadCountProvider), 0);
  });

  test('markRead bumps the watermark and re-reads the inbox', () async {
    when(() => repo.fetchInbox()).thenAnswer((_) async => [row(unread: 3)]);
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
    );
    when(() => repo.markChatRead(any())).thenAnswer((_) async {});
    final c = container();
    await  c.read(chatInboxProvider.future);
    expect( c.read(chatUnreadCountProvider), 3);

    when(() => repo.fetchInbox()).thenAnswer((_) async => [row(unread: 0)]);
    await  c.read(chatInboxProvider.notifier).markRead('chat-1');
    await  c.read(chatInboxProvider.future);

    verify(() => repo.markChatRead('chat-1')).called(1);
    expect( c.read(chatUnreadCountProvider), 0);
  });

  test('markRead swallows watermark failures (badge re-derives on next read)',
      () async {
    when(() => repo.fetchInbox()).thenAnswer((_) async => [row(unread: 1)]);
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
    );
    when(() => repo.markChatRead(any())).thenThrow(Exception('rpc down'));
    final c = container();
    await  c.read(chatInboxProvider.future);

    await  c.read(chatInboxProvider.notifier).markRead('chat-1');

    expect( c.read(chatInboxProvider).hasValue, isTrue);
  });
}
