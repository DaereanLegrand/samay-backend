import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/shared/widgets/glass/v_glass.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_thinking_dots.dart';
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

  /// When set, [send] awaits this future — lets tests pin the in-flight
  /// (thinking dots) state of the send button.
  final Completer<void>? sendGate;

  _FakeChatMessagesNotifier(
    this.data, {
    this.hasMore = false,
    this.loadingOlder = false,
    this.sendGate,
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
    if (sendGate != null) await sendGate!.future;
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
  _FakeChatMessagesNotifier? notifier,
}) async {
  final chatService = service ?? _MockChatService();
  final channel = _MockRealtimeChannel();
  when(() => chatService.subscribeToMessages(any(), any())).thenReturn(channel);
  when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_StubAuthNotifier.new),
      chatMessagesProvider.overrideWith(
        () =>
            notifier ??
            _FakeChatMessagesNotifier(
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
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(chatId: _chatId),
      ),
    ),
  );
  // Flush the async provider build (AsyncNotifier) before assertions.
  await tester.pump();
  return container;
}

void main() {
  testWidgets('renders the message list and the composer input row', (
    tester,
  ) async {
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

  testWidgets('sends through the provider and clears the composer', (
    tester,
  ) async {
    final container = await _pump(tester, const []);

    await tester.enterText(find.byType(TextField), '  nuevo mensaje  ');
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    final notifier =
        container.read(chatMessagesProvider(_chatId).notifier)
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

    final notifier =
        container.read(chatMessagesProvider(_chatId).notifier)
            as _FakeChatMessagesNotifier;
    expect(notifier.sent, isEmpty);
  });

  testWidgets('renders the localized placeholder for undecryptable messages', (
    tester,
  ) async {
    await _pump(tester, [
      _message('m-1', chatUndecryptablePlaceholder, sender: 'other')
        ..['decryptFailed'] = true,
    ]);

    final text = tester.widget<Text>(find.text('Mensaje no descifrable'));
    expect(
      text.style?.color,
      AppColors.mutedStrong,
      reason:
          '§2.4: informational text is mutedStrong (#999999 AA), never '
          'muted #666666 (3.66:1 fails 1.4.3 at normal size)',
    );
  });

  testWidgets('bubbles are LUXE liquid glass — own = watered peach + white '
      'hairline, peer = white glass, radius 16, max width 320', (tester) async {
    await _pump(tester, [
      _message('m-1', 'hola', sender: 'other'),
      _message('m-2', 'responde'),
    ]);

    final own = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chatBubbleOwn-m-2')),
    );
    final ownDecoration = own.decoration as BoxDecoration;
    expect(
      ownDecoration.borderRadius,
      const BorderRadius.all(Radius.circular(16)),
      reason:
          'LUXE v2: bubbles are liquid (radius 16) — the pre-LUXE '
          'radius-0 bubble rule is replaced (ORCHESTRATION-LUXE liquid '
          'corner scope)',
    );
    final ownGradient = ownDecoration.gradient as LinearGradient;
    expect(
      ownGradient.colors,
      AppGradients.watered(AppGradients.peach.colors, mix: 0.45),
      reason:
          'Gemma 14_chat "MEDIOCRE. Lacks focus": own bubbles are the '
          'peach family watered 45% toward white — never the saturated fill',
    );
    expect(
      ownDecoration.border,
      isNotNull,
      reason:
          'the glow halo is replaced by a 1px white α0.2 hairline '
          '(XL-18 directive: border instead of glow)',
    );
    expect(
      ownDecoration.boxShadow,
      isNull,
      reason: 'no glow chrome on bubbles — the composer is the only accent',
    );
    expect(
      tester.widget<Text>(find.text('responde')).style?.color,
      AppColors.discoBlack,
      reason: 'black text on the watered peach fill (still AA+)',
    );

    final peer = tester.widget<VGlass>(
      find.byKey(const ValueKey('chatBubblePeer-m-1')),
    );
    expect(
      peer.gradient,
      isNull,
      reason:
          'peer bubbles are white-only glass — the peach accent is '
          'confined to the composer row',
    );
    expect(
      peer.radius,
      const BorderRadius.all(Radius.circular(16)),
      reason: 'peer bubbles share the liquid 16 corner',
    );

    for (final key in const ['chatBubbleOwn-m-2', 'chatBubblePeer-m-1']) {
      final box = tester.widget<ConstrainedBox>(
        find.ancestor(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(ConstrainedBox),
        ),
      );
      expect(
        box.constraints.maxWidth,
        320,
        reason: 'XL-18: bubbles cap at 320 px — the thread is the visual '
            'center with maximum width utilization',
      );
    }
  });

  testWidgets('send button shows VThinkingDots while a message is in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    final notifier = _FakeChatMessagesNotifier(const [], sendGate: gate);
    await _pump(tester, const [], notifier: notifier);

    await tester.enterText(find.byType(TextField), 'en camino');
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    expect(
      find.byType(VThinkingDots),
      findsOneWidget,
      reason:
          'LUXE AI-thinking accent: the send button pulses thinking dots '
          'instead of the label while the send is in flight',
    );
    expect(find.text('Enviar'), findsNothing);

    gate.complete();
    await tester.pump();

    expect(find.byType(VThinkingDots), findsNothing);
    expect(find.text('Enviar'), findsOneWidget);
    expect(notifier.sent, ['en camino']);
  });

  testWidgets('shows the empty state when there are no messages', (
    tester,
  ) async {
    await _pump(tester, const []);

    expect(find.text('No hay mensajes todavía'), findsOneWidget);
    expect(find.byType(VEmptyView), findsOneWidget);
    // XL-19 (14_chat — "trivial / mediocre" on the EMPTY state): the empty
    // thread is an INTENTIONAL minimal view — chat icon + one line only:
    // no description, no CTA, nothing between the AppBar and the composer.
    final empty = tester.widget<VEmptyView>(find.byType(VEmptyView));
    expect(empty.icon, Icons.chat_bubble_outline);
    expect(empty.title, 'No hay mensajes todavía');
    expect(empty.description, isNull);
    expect(empty.actionLabel, isNull);
    // The composer row (glass input + send) is the only other chrome.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Enviar'), findsOneWidget);
  });

  testWidgets('shows the load-older button only when hasMore is true', (
    tester,
  ) async {
    await _pump(tester, [_message('m-1', 'hola')], hasMore: true);

    expect(find.text('Cargar anteriores'), findsOneWidget);
  });

  testWidgets('hides the load-older button when there is no more history', (
    tester,
  ) async {
    await _pump(tester, [_message('m-1', 'hola')], hasMore: false);

    expect(find.text('Cargar anteriores'), findsNothing);
  });

  testWidgets('tapping the load-older button calls loadOlder on the provider', (
    tester,
  ) async {
    final container = await _pump(tester, [
      _message('m-1', 'hola'),
    ], hasMore: true);

    await tester.tap(find.text('Cargar anteriores'));
    await tester.pump();

    final notifier =
        container.read(chatMessagesProvider(_chatId).notifier)
            as _FakeChatMessagesNotifier;
    expect(notifier.olderLoaded, hasLength(1));
  });

  testWidgets('shows a small loader row instead of the button while loading '
      'older messages', (tester) async {
    await _pump(
      tester,
      [_message('m-1', 'hola')],
      hasMore: true,
      loadingOlder: true,
    );

    expect(find.text('Cargar anteriores'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('hola'), findsOneWidget); // the list stays visible
  });
}
