import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
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
  final List<String> olderLoaded = [];
  final bool hasMore;
  final bool loadingOlder;

  _FakeChatMessagesNotifier(
    this.data, {
    this.hasMore = false,
    this.loadingOlder = false,
  });

  @override
  Future<ChatMessagesState> build(String arg) async => ChatMessagesState(
    messages: data,
    hasMore: hasMore,
    loadingOlder: loadingOlder,
  );

  @override
  Future<void> send(String chatId, String text) async {
    sent.add(text);
  }

  @override
  Future<void> loadOlder() async {
    olderLoaded.add('loadOlder');
  }
}

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeService extends Mock implements RealtimeService {}

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
  bool hasMore = false,
  bool loadingOlder = false,
}) async {
  final chatService = service ?? _MockChatService();
  final channel = _MockRealtimeChannel();
  when(() => chatService.subscribeToMessages(any(), any())).thenReturn(channel);
  when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(_StubAuthNotifier.new),
    chatMessagesProvider.overrideWith(
      () => _FakeChatMessagesNotifier(
        messages,
        hasMore: hasMore,
        loadingOlder: loadingOlder,
      ),
    ),
    // The screen reads the E2EE repository, which is built from the E2EE
    // service (for the realtime subscription) and the realtime service
    // (raw-channel seam, I-50); mocks avoid touching Supabase.instance
    // (uninitialized in tests).
    chatE2eeServiceProvider.overrideWithValue(chatService),
    realtimeServiceProvider.overrideWithValue(_MockRealtimeService()),
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

  testWidgets('shows the load-older button only when hasMore is true',
      (tester) async {
    await _pump(tester, [_message('m-1', 'hola')], hasMore: true);

    expect(find.text('Cargar anteriores'), findsOneWidget);
  });

  testWidgets('hides the load-older button when there is no more history',
      (tester) async {
    await _pump(tester, [_message('m-1', 'hola')], hasMore: false);

    expect(find.text('Cargar anteriores'), findsNothing);
  });

  testWidgets('tapping the load-older button calls loadOlder on the provider',
      (tester) async {
    final container = await _pump(tester, [_message('m-1', 'hola')],
        hasMore: true);

    await tester.tap(find.text('Cargar anteriores'));
    await tester.pump();

    final notifier = container.read(chatMessagesProvider(_chatId).notifier)
        as _FakeChatMessagesNotifier;
    expect(notifier.olderLoaded, hasLength(1));
  });

  testWidgets('shows a small loader row instead of the button while loading '
      'older messages', (tester) async {
    await _pump(tester, [_message('m-1', 'hola')],
        hasMore: true, loadingOlder: true);

    expect(find.text('Cargar anteriores'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('hola'), findsOneWidget); // the list stays visible
  });
}
