import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../../support/fake_config_provider.dart';
import '../../support/resolving_builder.dart';

/// The feed's chat inbox shortcut (user request 2026-08-15): a chat bubble
/// at the top-right of the brand hero — the same placement voice as the
/// profile's settings gear — carrying the total-unread badge (hidden at 0).
class _MockChatRepository extends Mock implements ChatRepository {}

class _FakeEventService extends EventService {
  _FakeEventService() : super(client: MockSupabaseClient());

  @override
  Future<List<Event>> listEvents(
    [String? status, String? type]) async {
    final start = DateTime(2026, 9, 15, 22);
    return [
      Event(
        id: 'e-1',
        name: 'Fiesta',
        type: 'juerga',
        status: 'upcoming',
        startsAt: start,
        endsAt: start.add(const Duration(hours: 4)),
      ),
    ];
  }
}

Map<String, dynamic> _inboxRow({required int unread}) => {
      'chat_id': 'chat-1',
      'type': 'direct',
      'peer_id': 'peer-1',
      'peer_username': 'bob',
      'last_message_id': 'm-1',
      'last_message_sender_id': 'peer-1',
      'last_message_content': 'SME2.env',
      'last_message_created_at': '2026-08-15T00:00:00Z',
      'unread_count': unread,
    };

Future<void> _pump(WidgetTester tester, _MockChatRepository repo) async {
  when(() => repo.fetchInbox()).thenAnswer(
    (_) async => [_inboxRow(unread: 3), _inboxRow(unread: 2)],
  );
  when(() => repo.decryptInboxRow(any())).thenAnswer(
    (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
  );
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(_FakeEventService()),
      appConfigProvider.overrideWith(
        () => FakeAppConfigNotifier(const {}),
      ),
      featureFlagsProvider.overrideWithValue(
        const AppFeatureFlags(minigames: false, partyFinder: false),
      ),
      chatE2eeRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const FeedScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the feed header shows the chat inbox button', (tester) async {
    await _pump(tester, _MockChatRepository());

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });

  testWidgets('the button carries the total-unread badge (sum across chats)',
      (tester) async {
    await _pump(tester, _MockChatRepository());

    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('no badge when there is nothing unread', (tester) async {
    final repo = _MockChatRepository();
    when(() => repo.fetchInbox()).thenAnswer((_) async => []);
    when(() => repo.decryptInboxRow(any())).thenAnswer(
      (inv) async => Map<String, dynamic>.from(inv.positionalArguments.first as Map),
    );
    await _pump(tester, repo);

    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });
}
