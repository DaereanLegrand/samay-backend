import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/chat/screens/chat_list_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

class _MockChatRepository extends Mock implements ChatRepository {}

class _MockRealtimeService extends Mock implements RealtimeService {}

class _MockRealtimeChannel extends Mock implements RealtimeChannel {}

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, user: {'id': 'me'});
}

void main() {
  late _MockChatRepository repo;
  late _MockRealtimeService realtime;
  late _MockRealtimeChannel channel;

  setUp(() {
    repo = _MockChatRepository();
    realtime = _MockRealtimeService();
    channel = _MockRealtimeChannel();
    when(() => realtime.subscribeToInbox(any())).thenAnswer((_) async => channel);
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
  });

  Future<void> pump(WidgetTester tester, {List<Map<String, dynamic>> rows = const []}) async {
    when(() => repo.fetchInbox()).thenAnswer((_) async => rows);
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => {
        ...Map<String, dynamic>.from(inv.positionalArguments.first as Map),
        'last_message_content': 'hola bob',
        'last_message_decrypt_failed': false,
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatE2eeRepositoryProvider.overrideWithValue(repo),
          realtimeServiceProvider.overrideWithValue(realtime),
          authStateProvider.overrideWith(_StubAuthNotifier.new),
        ],
        child: const MaterialApp(
          locale: Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> row({
    String chatId = 'chat-1',
    String peer = 'peer-1',
    String type = 'direct',
    String username = 'bob',
    int unread = 0,
    String senderId = 'peer-1',
    String? peerAvatarUrl,
  }) =>
      {
        'chat_id': chatId,
        'type': type,
        'peer_id': peer,
        'peer_username': username,
        'peer_avatar_url': peerAvatarUrl,
        'last_message_id': 'm-1',
        'last_message_sender_id': senderId,
        'last_message_content': 'SME2.envelope',
        'last_message_created_at': '2026-08-15T00:00:00Z',
        'unread_count': unread,
      };

  testWidgets('renders the empty state when there are no chats', (tester) async {
    await pump(tester);

    expect(find.text('No hay conversaciones'), findsOneWidget);
  });

  testWidgets('renders a chat row with peer name, preview and unread badge',
      (tester) async {
    await pump(tester, rows: [
      row(username: 'bob', unread: 3),
    ]);

    expect(find.text('bob'), findsOneWidget);
    expect(find.text('hola bob'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a direct row with peerAvatarUrl renders VNetworkImage and '
      'skips the initial-letter fallback', (tester) async {
    await pump(tester, rows: [
      row(username: 'bob', peerAvatarUrl: 'https://cdn.example.com/a.png'),
    ]);

    // The real avatar (from Storage) is rendered instead of the peer initial.
    expect(find.byType(VNetworkImage), findsOneWidget);
    expect(find.byIcon(Icons.group), findsNothing);
    // No initial-letter text ('B') is produced when an avatar URL is present.
    expect(find.text('B'), findsNothing);
  });

  testWidgets('a GROUP-type row renders the group icon avatar + the group '
      'name as the title (D4d)', (tester) async {
    await pump(tester, rows: [
      row(chatId: 'chat-g', type: 'group', username: 'Disco Crew', unread: 1),
    ]);

    // The avatar square carries the group icon instead of the initial letter.
    final tile = find.byType(Container);
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.group)),
      findsOneWidget,
      reason:
          'group rows swap the initial-letter avatar for the group icon '
          '(ISSUE 4)',
    );
    expect(
      find.byIcon(Icons.group),
      findsOneWidget,
      reason: 'the group icon renders exactly once',
    );
    // The group name stays as the row title (server RPC peer_username).
    expect(find.text('Disco Crew'), findsOneWidget);
    expect(find.text('hola bob'), findsOneWidget);
  });

  testWidgets('own last message gets the "Tú:" prefix', (tester) async {
    await pump(tester, rows: [
      row(senderId: 'me'),
    ]);

    expect(find.textContaining('Tú: hola bob'), findsOneWidget);
  });

  testWidgets('subscribes to the inbox realtime stream on open', (tester) async {
    await pump(tester);

    verify(() => realtime.subscribeToInbox(any())).called(1);
  });

  testWidgets('mark-read RPC is not fired from the list (only on thread open)',
      (tester) async {
    await pump(tester, rows: [row(unread: 1)]);

    verifyNever(() => repo.markChatRead(any()));
  });
}
