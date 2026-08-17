import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/screens/chat_screen.dart';
import 'package:samay/features/chat/widgets/chat_thread_view.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_thinking_dots.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import 'package:samay/l10n/app_localizations.dart';

const _chatId = '33333333-3333-3333-3333-333333333333';
const _userId = '11111111-1111-1111-1111-111111111111';
const _peerId = '22222222-2222-2222-2222-222222222222';

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

class _FakeChatInboxNotifier extends ChatInboxNotifier {
  final List<ChatInboxItem> items;

  _FakeChatInboxNotifier(this.items);

  @override
  Future<List<ChatInboxItem>> build() async => items;
}

class _MockChatService extends Mock implements ChatService {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

class _MockChatRepository extends Mock implements ChatRepository {}

class _MockFriendsRepository extends Mock implements FriendsRepository {}

/// Group-members stub for the ChatThreadView sender-label tests: returns
/// [members] as-is (rows carry `users.username` like the real RPC).
class _StubGroupMembersNotifier extends GroupMembersNotifier {
  final List<Map<String, dynamic>> data;

  _StubGroupMembersNotifier(this.data);

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

Map<String, dynamic> _message(
  String id,
  String content, {
  String? sender,
  String? readAt,
  String? sentAt,
  List<Map<String, dynamic>>? reads,
}) => {
  'id': id,
  'sender_id': sender ?? _userId,
  'content': content,
  'media_url': null,
  'created_at': '2026-08-01T00:00:00Z',
  'sent_at': sentAt,
  'read_at': ?readAt,
  'message_reads': ?reads,
};

/// A member row of the group-members stub (the thread's sender labels and
/// the read-by-all roster derive from these).
Map<String, dynamic> _member(String id, String username) => {
      'user_id': id,
      'role': 'member',
      'status': 'active',
      'users': {'username': username},
    };

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> messages, {
  _MockChatService? service,
  bool hasMore = false,
  bool loadingOlder = false,
  _FakeChatMessagesNotifier? notifier,
  List<ChatInboxItem> inbox = const [],
  HiveService? hive,
  bool settle = true,
  String? groupId,
  List<Map<String, dynamic>> members = const [],
  FriendsRepository? friends,
}) async {
  final chatService = service ?? _MockChatService();
  final channel = _MockRealtimeChannel();
  when(() => chatService.subscribeToMessages(any(), any())).thenReturn(channel);
  when(() => chatService.subscribeToMessageReads(any(), any())).thenReturn(channel);
  when(() => chatService.subscribeToMessageDeletes(any(), any())).thenReturn(channel);
  when(() => chatService.subscribeToGroupMessageReads(any(), any())).thenReturn(channel);
  // Default stub only when the caller did not supply a service — a custom
  // service's own `peerNeedsRekey` stub must win (the §7.5 notice test).
  if (service == null) {
    when(() => chatService.peerNeedsRekey(any())).thenAnswer((_) async => false);
  }
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
      chatInboxProvider.overrideWith(() => _FakeChatInboxNotifier(inbox)),
      // The screen reads the E2EE repository, which is built from the E2EE
      // service (for the realtime subscription) and the realtime service
      // (raw-channel seam, I-50); mocks avoid touching Supabase.instance
      // (uninitialized in tests).
      chatE2eeServiceProvider.overrideWithValue(chatService),
      realtimeServiceProvider.overrideWithValue(_MockRealtimeService()),
      if (groupId != null)
        groupMembersProvider.overrideWith(
          () => _StubGroupMembersNotifier(members),
        ),
      if (friends != null)
        friendsRepositoryProvider.overrideWithValue(friends),
      if (hive != null) hiveServiceProvider.overrideWithValue(hive),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: groupId == null
            ? const ChatScreen(chatId: _chatId)
            // The GROUP thread hosts the same ChatThreadView the group
            // detail Chat tab mounts (ISSUE 4) — pump it directly.
            : Scaffold(
                body: ChatThreadView(chatId: _chatId, groupId: groupId),
              ),
      ),
    ),
  );
  // Flush the async provider builds (AsyncNotifier) before assertions.
  // [settle] false leaves frames pumping manually — an animating loader row
  // would otherwise run pumpAndSettle's timeout.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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
    expect(find.text('Chat'), findsOneWidget); // app bar fallback title
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Enviar'), findsOneWidget);
  });

  testWidgets('app bar shows the PEER USERNAME from the inbox (not "Chat")', (
    tester,
  ) async {
    await _pump(tester, const [], inbox: [
      const ChatInboxItem(
        chatId: _chatId,
        type: 'direct',
        peerId: _peerId,
        peerUsername: 'alice',
        unreadCount: 2,
      ),
    ]);

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('Chat'), findsNothing);
  });

  testWidgets('date separators group the thread by day (one chip per day)', (
    tester,
  ) async {
    // Relative to now so the Hoy/Ayer chips hold on any run date. Built from
    // LOCAL calendar parts (no 'Z') — the thread's day labels compare local
    // dates, so the fixtures must not drift across timezones either.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    String at(int hour) => (DateTime(
          today.year,
          today.month,
          today.day,
          hour,
        ))
            .toIso8601String();
    await _pump(tester, [
      _message('m-1', 'ayer', sender: 'other')..['created_at'] = DateTime(
              yesterday.year,
              yesterday.month,
              yesterday.day,
              10,
            ).toIso8601String(),
      _message('m-2', 'hoy', sender: 'other')..['created_at'] = at(10),
      _message('m-3', 'tambien hoy', sender: 'other')..['created_at'] = at(11),
    ]);

    expect(find.text('Ayer'), findsOneWidget);
    expect(find.text('Hoy'), findsOneWidget);
  });

  testWidgets('every bubble shows the sent time (HH:mm)', (tester) async {
    await _pump(tester, [
      _message('m-1', 'hola', sender: 'other'),
      _message('m-2', 'responde'),
    ]);

    // Each of the two bubbles carries a footer clock. The exact label is
    // timezone-dependent (the fixture is UTC), so match the shape.
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsNWidgets(2));
  });

  testWidgets('own bubble: the delivery checks sit at the RIGHT of the hour '
      '(same footer row — never below it)', (tester) async {
    await _pump(tester, [
      _message('m-2', 'responde', readAt: '2026-08-01T00:05:00Z'),
    ]);

    expect(find.byIcon(Icons.done_all), findsOneWidget);
    final rowsWithStatus = find.ancestor(
      of: find.byIcon(Icons.done_all),
      matching: find.byType(Row),
    );
    var hourOnSameRow = false;
    for (final element in rowsWithStatus.evaluate()) {
      if (find
          .descendant(
            of: find.byWidget(element.widget),
            matching: find.textContaining(RegExp(r'^\d{2}:\d{2}$')),
          )
          .evaluate()
          .isNotEmpty) {
        hourOnSameRow = true;
        break;
      }
    }
    expect(
      hourOnSameRow,
      isTrue,
      reason:
          'the read/sent checks share the hour\'s footer row (checks at its '
          'right side) — a check below the hour is a regression',
    );
  });

  testWidgets('peer bubble: the hour stays at the BOTTOM-RIGHT — its Column '
      'is right-aligned, even for a compact (shrink-wrapped) bubble', (
    tester,
  ) async {
    await _pump(tester, [_message('m-1', 'hola', sender: 'other')]);

    final timeText = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
    expect(timeText, findsOneWidget);
    final colsWithTime = find.ancestor(
      of: timeText,
      matching: find.byType(Column),
    );
    var rightAligned = false;
    for (final element in colsWithTime.evaluate()) {
      final col = element.widget as Column;
      if (col.crossAxisAlignment == CrossAxisAlignment.end) {
        rightAligned = true;
        break;
      }
    }
    expect(
      rightAligned,
      isTrue,
      reason:
          'the hour sits at the bottom-right of peer bubbles — a bottom-'
          'left hour (start-aligned column) is a regression',
    );
  });

  testWidgets('own messages show a double grey check (received) — not read', (
    tester,
  ) async {
    await _pump(tester, [_message('m-2', 'responde')]);

    final icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(icon.color, AppColors.statusGrey);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('own messages with read_at show the BLUE double check (read)', (
    tester,
  ) async {
    await _pump(tester, [
      _message('m-2', 'responde', readAt: '2026-08-01T00:05:00Z'),
    ]);

    final icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(icon.color, AppColors.statusRead);
  });

  testWidgets('GROUP: own bubbles turn blue ONLY when every other member '
      'read — one reader keeps the grey double check (20260817000006 — the '
      'ISSUE fix: a single reader must not fake read-by-everyone)', (
    tester,
  ) async {
    const me = '11111111-1111-1111-1111-111111111111';
    const bob = '22222222-2222-2222-2222-222222222222';
    const carol = '55555555-5555-5555-5555-555555555555';
    final members = [_member(me, 'tester1'), _member(bob, 'tester2'), _member(carol, 'tester3')];

    // Only bob read → grey double check (2 other members matter).
    await _pump(
      tester,
      [
        _message('m-2', 'responde', reads: [
          {'user_id': bob, 'read_at': '2026-08-01T00:05:00Z'},
        ]),
      ],
      groupId: 'group-1',
      members: members,
    );
    var icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(icon.color, AppColors.statusGrey,
        reason: '1 of 2 other members read → grey, never blue');
    expect(find.byIcon(Icons.check), findsNothing);

    // Both bob AND carol read → BLUE (all other members).
    await _pump(
      tester,
      [
        _message('m-2', 'responde', reads: [
          {'user_id': bob, 'read_at': '2026-08-01T00:05:00Z'},
          {'user_id': carol, 'read_at': '2026-08-01T00:06:00Z'},
        ]),
      ],
      groupId: 'group-1',
      members: members,
    );
    icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(icon.color, AppColors.statusRead,
        reason: 'every other member read → blue');
  });

  testWidgets('GROUP: an unknown roster never claims all-read — the grey '
      'check stays (conservative under stale member data)', (tester) async {
    await _pump(
      tester,
      [
        _message('m-2', 'responde', reads: [
          {'user_id': '22222222-2222-2222-2222-222222222222',
            'read_at': '2026-08-01T00:05:00Z'},
        ]),
      ],
      groupId: 'group-1',
      // members: const [] — the stale/empty-members class (the iPhone
      // stuck-at-4 bug would otherwise fake read-by-everyone).
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
    expect(icon.color, AppColors.statusGrey,
        reason: 'with no roster the thread must not claim all-read');
  });

  testWidgets('long-press on an OWN message shows the message-info action '
      'and sheet: Enviado + Leído por N de M (2026-08-17 user request; '
      'own messages only)', (tester) async {
    const bob = '22222222-2222-2222-2222-222222222222';
    const carol = '55555555-5555-5555-5555-555555555555';
    final members = [
      _member(_userId, 'tester1'),
      _member(bob, 'tester2'),
      _member(carol, 'tester3'),
    ];
    await _pump(
      tester,
      [
        _message('m-2', 'hola', reads: [
          {'user_id': bob, 'read_at': '2026-08-01T00:05:00Z'},
        ]),
      ],
      groupId: 'group-1',
      members: members,
    );

    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();
    expect(find.text('Información del mensaje'), findsOneWidget);

    await tester.tap(find.text('Información del mensaje'));
    await tester.pumpAndSettle();

    // The sheet: sent time + the per-member read count with names.
    expect(find.textContaining('Enviado'), findsOneWidget);
    expect(find.text('Leído por 1 de 2'), findsOneWidget);
    expect(find.text('tester2'), findsOneWidget,
        reason: "the reader's username resolves from the members list");
  });

  testWidgets('long-press on a PEER message offers NO message-info action '
      '(status is only available for own messages)', (tester) async {
    await _pump(
      tester,
      [
        _message('m-1', 'hola del otro', sender: _peerId),
      ],
      groupId: 'group-1',
      members: [
        _member(_userId, 'tester1'),
        _member(_peerId, 'tester2'),
      ],
    );

    await tester.longPress(find.text('hola del otro'));
    await tester.pumpAndSettle();

    expect(find.text('Información del mensaje'), findsNothing);
    expect(find.text('Eliminar para mí'), findsOneWidget);
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

  testWidgets('bubbles are WHITE — own = solid white fill + black text, '
      'peer = white glass, radius 8, max width 320', (tester) async {
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
      const BorderRadius.all(Radius.circular(8)),
      reason: 'bubbles stay liquid (radius 8)',
    );
    expect(
      ownDecoration.color,
      AppColors.white,
      reason:
          '2026-08-15 user directive: own bubbles are SOLID WHITE — the '
          'peach (orange) fill is replaced, no gradient, no halo',
    );
    expect(ownDecoration.gradient, isNull);
    expect(ownDecoration.boxShadow, isNull);
    expect(
      tester.widget<Text>(find.text('responde')).style?.color,
      AppColors.discoBlack,
      reason: 'black text on the white fill (21:1 AA)',
    );

    final peer = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chatBubblePeer-m-1')),
    );
    final peerDecoration = peer.decoration as BoxDecoration;
    expect(
      peerDecoration.borderRadius,
      const BorderRadius.all(Radius.circular(8)),
      reason: 'peer bubbles share the liquid 8 corner',
    );
    expect(peerDecoration.gradient, isNotNull);
    final gradient = peerDecoration.gradient as LinearGradient;
    expect(
      gradient.colors,
      [AppColors.muted, AppColors.border],
      reason:
          'peer bubbles render a muted → border grey gradient, no border '
          'ring, no glass layers on top of the text',
    );
    expect(peerDecoration.color, isNull);
    expect(
      peerDecoration.boxShadow,
      isNotNull,
      reason: 'peer bubbles have a per-user colored shadow',
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
        reason: 'bubbles cap at 320 px — the thread is the visual center',
      );
      // The CONSTRAINT caps at 320, but the RENDERED bubble must shrink to
      // its content — a short message ('hola'/'responde') is never a full
      // 320px-wide bubble.
      final rendered = tester.getSize(find.byKey(ValueKey(key)));
      expect(
        rendered.width,
        lessThan(320),
        reason:
            'short messages shrink-wrap; only long content reaches the '
            '320px cap (the sender-name Align used to pin every group '
            'bubble at max width)',
      );
    }
  });

  testWidgets('send button is flat white (no peach gradient)', (tester) async {
    await _pump(tester, const []);

    final button = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Enviar'),
        matching: find.byType(TextButton),
      ),
    );
    final bg = button.style?.backgroundColor;
    expect(bg, isNotNull);
    expect(bg!.resolve({}), AppColors.white);
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
          'the send button pulses thinking dots instead of the label while '
          'the send is in flight',
    );
    expect(find.text('Enviar'), findsNothing);

    gate.complete();
    await tester.pump();

    expect(find.byType(VThinkingDots), findsNothing);
    expect(find.text('Enviar'), findsOneWidget);
    expect(notifier.sent, ['en camino']);
  });

  testWidgets('optimistic send: pending bubble appears with a single grey '
      'check and is replaced by the committed row on refresh', (tester) async {
    final repo = _MockChatRepository();
    final gate = Completer<void>();
    final channel = _MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) => Future.value('ok'));
    when(
      () => repo.loadMessages(
        _chatId,
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const []);
    when(() => repo.sendMessage(_chatId, any(), any())).thenAnswer(
      (_) async => gate.future,
    );
    when(() => repo.subscribe(any(), any())).thenReturn(channel);
    when(() => repo.subscribeToMessageReads(any(), any())).thenReturn(channel);
    when(() => repo.subscribeToMessageDeletes(any(), any())).thenReturn(channel);
    when(() => repo.peerNeedsRekey(any())).thenAnswer((_) async => false);
    when(() => repo.markChatRead(any())).thenAnswer((_) async {});
    when(() => repo.markMessagesRead(any())).thenAnswer((_) async {});
    when(() => repo.getReadReceiptsEnabled()).thenAnswer((_) async => true);
    when(() => repo.fetchInbox()).thenAnswer((_) async => []);

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        chatE2eeRepositoryProvider.overrideWithValue(repo),
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
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'en el aire');
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    // The optimistic bubble + the WhatsApp "sent" single grey check.
    expect(find.text('en el aire'), findsOneWidget);
    final pendingCheck = tester.widget<Icon>(find.byIcon(Icons.check));
    expect(pendingCheck.color, AppColors.statusGrey);

    // The send confirms → refresh replaces the pending row with the server
    // truth (empty thread in this harness).
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('en el aire'), findsNothing);
  });

  testWidgets('shows the empty state when there are no messages', (
    tester,
  ) async {
    await _pump(tester, const []);

    expect(find.text('No hay mensajes todavía'), findsOneWidget);
    expect(find.byType(VEmptyView), findsOneWidget);
    // The empty thread is an INTENTIONAL minimal view — chat icon + one line
    // only: no description, no CTA, nothing between the AppBar and the
    // composer.
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
      settle: false,
    );
    await tester.pump();

    expect(find.text('Cargar anteriores'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('hola'), findsOneWidget); // the list stays visible
  });

  testWidgets('long-press on an OWN message within 5 minutes offers BOTH '
      'delete options (delete-for-everyone + delete-for-me)', (tester) async {
    final service = _MockChatService();
    when(() => service.deleteMessageForEveryone(any()))
        .thenAnswer((_) async => MessageDeleteOutcome.deleted);
    when(() => service.deleteMessageForMe(any(), any())).thenAnswer((_) async {});
    await _pump(
      tester,
      [
        _message(
          'm-1',
          'hola',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ],
      service: service,
    );

    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();

    expect(find.text('Eliminar para todos'), findsOneWidget);
    expect(find.text('Eliminar para mí'), findsOneWidget);
  });

  testWidgets('long-press on an OWN message OLDER than 5 minutes offers ONLY '
      'delete-for-me (the server enforces the window too)', (tester) async {
    await _pump(tester, [
      _message(
        'm-1',
        'hola',
        sentAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)).toIso8601String(),
      ),
    ]);

    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();

    expect(find.text('Eliminar para todos'), findsNothing);
    expect(find.text('Eliminar para mí'), findsOneWidget);
  });

  testWidgets('long-press on a PEER message offers ONLY delete-for-me',
      (tester) async {
    await _pump(tester, [
      _message(
        'm-1',
        'hola del otro',
        sender: _peerId,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    ]);

    await tester.longPress(find.text('hola del otro'));
    await tester.pumpAndSettle();

    expect(find.text('Eliminar para todos'), findsNothing);
    expect(find.text('Eliminar para mí'), findsOneWidget);
  });

  testWidgets('delete-for-everyone removes the bubble and the too-old verdict '
      'shows the snackbar', (tester) async {
    final service = _MockChatService();
    when(() => service.deleteMessageForEveryone('m-1'))
        .thenAnswer((_) async => MessageDeleteOutcome.tooOld);
    when(() => service.deleteMessageForMe(any(), any())).thenAnswer((_) async {});
    await _pump(
      tester,
      [
        _message(
          'm-1',
          'hola',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ],
      service: service,
    );

    // too-old verdict → the snackbar explains the 5-minute window.
    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar para todos'));
    await tester.pumpAndSettle();
    expect(
      find.text('Solo puedes eliminar mensajes enviados hace menos de 5 minutos'),
      findsOneWidget,
    );

    // deleted verdict → the row leaves the thread.
    when(() => service.deleteMessageForEveryone('m-1'))
        .thenAnswer((_) async => MessageDeleteOutcome.deleted);
    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar para todos'));
    await tester.pumpAndSettle();
    expect(find.text('hola'), findsNothing);
  });

  testWidgets('delete-for-me removes the bubble on this device only',
      (tester) async {
    final service = _MockChatService();
    when(() => service.deleteMessageForMe(any(), any())).thenAnswer((_) async {});
    await _pump(
      tester,
      [_message('m-1', 'hola', sentAt: DateTime.now().toUtc().toIso8601String())],
      service: service,
    );

    await tester.longPress(find.text('hola'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar para mí'));
    await tester.pumpAndSettle();

    expect(find.text('hola'), findsNothing);
    verify(() => service.deleteMessageForMe(_chatId, 'm-1')).called(1);
  });

  testWidgets('peer-reinstall notice shows ONCE per peer (E2EE §7.5)',
      (tester) async {
    final service = _MockChatService();
    when(() => service.peerNeedsRekey(any())).thenAnswer((_) async => true);
    final hive = _RecordingHiveService();

    await _pump(
      tester,
      const [],
      service: service,
      hive: hive,
      settle: false,
    );
    // Drive the snackbar's entrance animation explicitly (settle:false —
    // the pending 4s dismissal timer would otherwise make pumpAndSettle
    // advance past the snackbar's lifetime).
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.text('El otro usuario reinstaló la app o cambió de dispositivo'),
      findsOneWidget,
    );
    expect(
      hive.config.containsKey('reinstall_notice_seen_$_chatId'),
      isTrue,
    );

    // A SECOND open (fresh screen, flag already persisted) → no notice.
    final hive2 = _RecordingHiveService({'reinstall_notice_seen_$_chatId': '1'});
    final service2 = _MockChatService();
    when(() => service2.peerNeedsRekey(any())).thenAnswer((_) async => true);
    await _pump(tester, const [], service: service2, hive: hive2);
    expect(
      find.text('El otro usuario reinstaló la app o cambió de dispositivo'),
      findsNothing,
    );
  });

  testWidgets('GROUP thread: peer bubbles show the sender username from '
      'groupMembersProvider; own bubbles do not (D4a)', (tester) async {
    await _pump(tester, [
      _message('m-1', 'hola a todos', sender: _peerId),
      _message('m-2', 'yo tambien'),
    ], groupId: 'group-9', members: [
      {'user_id': _peerId, 'users': {'username': 'lucas'}},
      {'user_id': _userId, 'users': {'username': 'yo'}},
    ]);

    // The peer bubble renders the sender's username as a small label.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatBubblePeer-m-1')),
        matching: find.text('lucas'),
      ),
      findsOneWidget,
      reason:
          'group peer bubbles label the sender from groupMembersProvider '
          '(ISSUE 4)',
    );
    // Own bubbles never label their sender (the white bubble stays clean).
    expect(find.text('yo'), findsNothing);
    // The 1:1 bubble chrome (time clock) survives in the group thread too.
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsNWidgets(2));
    // The sender label must NOT stretch the bubble: a short group message
    // renders a compact bubble (the pre-fix `Align` wrapper expanded to the
    // full 320px and pinned EVERY group peer bubble at max width).
    final groupBubble = tester.getSize(
      find.byKey(const ValueKey('chatBubblePeer-m-1')),
    );
    expect(
      groupBubble.width,
      lessThan(320),
      reason:
          'the sender name shrink-wraps (capped at 200px) — a short group '
          'message is never a full-width bubble',
    );
  });

  testWidgets('GROUP thread: an unknown sender falls back to a short uid '
      'prefix instead of crashing (D4a)', (tester) async {
    await _pump(tester, [
      _message('m-1', 'quien soy', sender: '99999999-9999-9999-9999-999999999999'),
    ], groupId: 'group-9', members: const []);

    expect(
      find.text('99999999'),
      findsOneWidget,
      reason:
          'senders missing from the members list fall back to the first 8 '
          'uid chars — never crash',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('GROUP thread: with an EMPTY members list the sender label '
      'resolves the username via getUserProfile — the uid prefix is only '
      'shown while the lookup is pending (USER FIX 2)', (tester) async {
    const senderId = 'e5b725d6-0000-0000-0000-000000000001';
    final friends = _MockFriendsRepository();
    final gate = Completer<UserProfile?>();
    when(
      () => friends.getUserProfile(senderId),
    ).thenAnswer((_) => gate.future);

    await _pump(tester, [
      _message('m-1', 'hola a todos', sender: senderId),
    ], groupId: 'group-9', members: const [], friends: friends, settle: false);
    await tester.pump();

    // While the profile lookup is in flight the pending uid-prefix fallback
    // keeps the label non-empty (deterministic — the completer is gated).
    expect(
      find.text('e5b725d6'),
      findsOneWidget,
      reason:
          'the uid-prefix fallback renders while the direct lookup is pending',
    );

    gate.complete(const UserProfile(id: senderId, username: 'tester4'));
    await tester.pumpAndSettle();

    expect(
      find.text('tester4'),
      findsOneWidget,
      reason:
          'a resolvable sender must NEVER keep the uid-prefix label — the '
          'username replaces it once the lookup lands (USER FIX 2)',
    );
    expect(find.text('e5b725d6'), findsNothing);
    verify(() => friends.getUserProfile(senderId)).called(1);
  });

  testWidgets('GROUP thread: concurrent bubbles for the same unknown sender '
      'fire exactly ONE profile lookup (USER FIX 2)', (tester) async {
    const senderId = 'e5b725d6-0000-0000-0000-000000000001';
    final friends = _MockFriendsRepository();
    final gate = Completer<UserProfile?>();
    when(
      () => friends.getUserProfile(senderId),
    ).thenAnswer((_) => gate.future);

    await _pump(tester, [
      _message('m-1', 'primero', sender: senderId),
      _message('m-2', 'segundo', sender: senderId),
      _message('m-3', 'tercero', sender: senderId),
    ], groupId: 'group-9', members: const [], friends: friends, settle: false);
    await tester.pump();

    gate.complete(const UserProfile(id: senderId, username: 'tester4'));
    await tester.pumpAndSettle();

    expect(
      find.text('tester4'),
      findsNWidgets(3),
      reason: 'every bubble of the same sender shows the resolved username',
    );
    verify(() => friends.getUserProfile(senderId)).called(1);
  });
}

class _RecordingHiveService implements HiveService {
  _RecordingHiveService([Map<String, String>? initial])
      : config = {...?initial};

  final Map<String, String> config;

  @override
  Future<void> init({bool initializeFlutter = true}) async {}

  @override
  Future<void> cacheConfig(Map<String, String> config) async {
    this.config.addAll(config);
  }

  @override
  Map<String, String>? getCachedConfig() => Map.of(config);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used in tests');
}
