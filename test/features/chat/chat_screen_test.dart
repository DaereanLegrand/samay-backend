import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/features/chat/chat_providers.dart';
import 'package:samay/features/chat/chat_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import 'package:samay/l10n/app_localizations.dart';

const _chatId = '33333333-3333-3333-3333-333333333333';
const _userId = '11111111-1111-1111-1111-111111111111';

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState(user: {'id': _userId});
}

class _FakeChatMessagesNotifier extends ChatMessagesNotifier {
  final List<Map<String, dynamic>> data;
  final List<String> sent = [];

  _FakeChatMessagesNotifier(this.data);

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;

  @override
  Future<void> send(String chatId, String text) async {
    sent.add(text);
  }
}

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

Map<String, dynamic> _message(String id, String content, {String? sender}) => {
  'id': id,
  'sender_id': sender ?? _userId,
  'content': content,
  'media_url': null,
  'created_at': '2026-08-01T00:00:00Z',
};

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> messages, {
  _MockChatService? service,
}) async {
  final chatService = service ?? _MockChatService();
  final channel = _MockRealtimeChannel();
  when(() => chatService.subscribeToMessages(any(), any())).thenReturn(channel);
  when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(_StubAuthNotifier.new),
    chatMessagesProvider
        .overrideWith(() => _FakeChatMessagesNotifier(messages)),
    // The screen reads the E2EE service for the realtime subscription; a
    // mock avoids touching Supabase.instance (uninitialized in tests).
    chatE2eeServiceProvider.overrideWithValue(chatService),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ChatScreen(chatId: _chatId),
      ),
    ),
  );
  // Flush the async provider build (AsyncNotifier) before assertions.
  await tester.pump();
  return container;
}

void main() {
  testWidgets('renders the message list and the composer input row',
      (tester) async {
    await _pump(tester, [
      _message('m-1', 'hola', sender: 'other'),
      _message('m-2', 'responde'),
    ]);

    expect(find.text('hola'), findsOneWidget);
    expect(find.text('responde'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget); // app bar title
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Enviar'), findsOneWidget);
  });

  testWidgets('sends through the provider and clears the composer',
      (tester) async {
    final container = await _pump(tester, const []);

    await tester.enterText(find.byType(TextField), '  nuevo mensaje  ');
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    final notifier = container.read(chatMessagesProvider(_chatId).notifier)
        as _FakeChatMessagesNotifier;
    // The screen trims before sending.
    expect(notifier.sent, ['nuevo mensaje']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('does not send an empty message', (tester) async {
    final container = await _pump(tester, const []);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    final notifier = container.read(chatMessagesProvider(_chatId).notifier)
        as _FakeChatMessagesNotifier;
    expect(notifier.sent, isEmpty);
  });

  testWidgets('renders the localized placeholder for undecryptable messages',
      (tester) async {
    await _pump(tester, [
      _message('m-1', chatUndecryptablePlaceholder,
          sender: 'other')..['decryptFailed'] = true,
    ]);

    expect(find.text('Mensaje no descifrable'), findsOneWidget);
  });

  testWidgets('shows the empty state when there are no messages',
      (tester) async {
    await _pump(tester, const []);

    expect(find.text('No hay mensajes todavía'), findsOneWidget);
  });
}
