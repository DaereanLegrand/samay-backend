import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/minigames/screens/minigame_detail_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show GoTrueClient, RealtimeChannel, SupabaseClient;

import '../../support/fake_supabase_http.dart' as support;
import '../../support/stub_auth_notifier.dart';

const _sessionId = '33333333-3333-3333-3333-333333333333';
const _myUserId = '11111111-1111-1111-1111-111111111111';

/// Empty [NotificationService] fake so [myPendingInvitesProvider] resolves
/// (the per-game page renders the pending-invite list it drives).
class _FakeNotificationService implements NotificationService {
  @override
  Future<List<Map<String, dynamic>>> getNotifications() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Dedicated per-game landing page tests (2026-08-28): the reusable shell
/// shows the game title/explanation/audience, the ongoing partidas (with the
/// empty state when there are none) and — the functional wiring — "Nueva
/// partida" opens the wizard which creates a DIRECT session with the
/// default 10-shard wager and forwards the entered name through the
/// notifier to the service.
class _StubProfileNotifier extends MyProfileNotifier {
  @override
  Future<Map<String, dynamic>?> build() async => const {
    'username': 'dana',
    'personal_shards': 120,
    'preshards': 0,
    'subscription_tier': 'free',
  };
}
class _FakeMinigameService implements MinigameService {
  _FakeMinigameService({this.sessions = const []});

  List<Map<String, dynamic>> sessions;
  List<Map<String, dynamic>> pendingInvites = [];
  int createCalls = 0;
  String? lastCreatedName;
  int? lastCreatedWager;
  MinigameType? lastCreatedType;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listSessions(String groupId) async =>
      List.of(sessions);

  @override
  Future<List<Map<String, dynamic>>> listMySessions() async =>
      List.of(sessions);

  @override
  Future<Map<String, dynamic>?> getSession(String id) async => null;

  @override
  Future<String> createSession(
    String? groupId,
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
    String? name,
  }) async {
    createCalls++;
    lastCreatedType = type;
    lastCreatedWager = wager;
    lastCreatedName = name;
    sessions = [
      {
        'id': _sessionId,
        'group_id': null,
        'game_type': type.value,
        'status': 'active',
        'shard_wager': wager,
        'participants': [_myUserId],
        'winner_id': null,
        'created_at': '2026-08-28T10:00:00Z',
        'name': name,
      },
      ...sessions,
    ];
    return _sessionId;
  }

  @override
  Future<void> joinSession(String id) async {}

  @override
  Future<void> updateStatus(String id, MinigameStatus status) async {}

  @override
  Future<Map<String, dynamic>?> myInviteForSession(String sessionId) async =>
      null;

  @override
  Future<List<Map<String, dynamic>>> listMyPendingInvites() async =>
      List.of(pendingInvites);

  @override
  Future<void> acceptInvite(String inviteId) async {}

  @override
  Future<void> declineInvite(String inviteId) async {}

  @override
  RealtimeChannel subscribeToSession(String id) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMinigameGameState(String sessionId) async =>
      null;

  @override
  Future<Map<String, dynamic>> initMinigameGameState(String sessionId) async =>
      throw UnimplementedError();

  @override
  Future<void> setReady(String sessionId, bool ready) async {}

  @override
  Future<List<Map<String, dynamic>>> getMinigameParticipants(
    String sessionId,
  ) async => const [];

  @override
  Future<void> removeParticipant(String sessionId, String userId) async {}

  @override
  Future<Map<String, dynamic>> revealMinigamePrompt(
    String sessionId,
    String promptType,
  ) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> advanceMinigameTurn(
    String sessionId,
    Map<String, dynamic> round,
  ) async =>
      throw UnimplementedError();

  @override
  Future<void> completeMinigameGame(String sessionId) async {}

  @override
  RealtimeChannel subscribeToGameState(String sessionId) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(support.initSupabaseHarness);

  Future<void> pumpDetail(
    WidgetTester tester, {
    required _FakeMinigameService service,
    MinigameType gameType = MinigameType.truthDare,
  }) async {
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(
          () => StubAuthNotifier(
            authenticated: true,
            hasProfile: true,
            userId: _myUserId,
          ),
        ),
        minigameServiceProvider.overrideWithValue(service),
        notificationServiceProvider.overrideWithValue(_FakeNotificationService()),
        realtimeChannelProvider.overrideWith(
          (ref, request) => const Stream<Map<String, dynamic>>.empty(),
        ),
        myProfileProvider.overrideWith(() => _StubProfileNotifier()),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home-marker')),
        ),
        GoRoute(
          path: '/detail',
          builder: (_, _) => MinigameDetailScreen(gameType: gameType),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    router.go('/detail');
    await tester.pumpAndSettle();
  }

  testWidgets(
      'shows title, explanation and audience for the game, plus the '
      'ongoing list with the auto partida-XX name', (tester) async {
    final service = _FakeMinigameService(
      sessions: [
        {
          'id': _sessionId,
          'group_id': null,
          'game_type': 'truth_dare',
          'status': 'active',
          'shard_wager': 10,
          'participants': [_myUserId],
          'winner_id': null,
          'created_at': '2026-08-28T10:00:00Z',
          'name': null,
        },
      ],
    );
    await pumpDetail(tester, service: service);

    // The game name renders exactly once (the AppBar) — the hero no longer
    // duplicates the title + icon (2026-08-28 user directive).
    expect(find.text('Verdad o Reto'), findsOneWidget);
    expect(find.text('Para jugar con amigos'), findsOneWidget);
    expect(find.text('Nueva partida'), findsOneWidget);

    // The ongoing-list section sits below the fold on the default test
    // viewport — scroll it into view (the heading is uppercased).
    await tester.scrollUntilVisible(
      find.text('PARTIDAS EN CURSO'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('PARTIDAS EN CURSO'), findsOneWidget);
    expect(find.text('partida-1'), findsOneWidget);
    expect(find.text('Apuesta: 10 shards'), findsOneWidget);
  });

  testWidgets('shows the empty state when there are no ongoing partidas of '
      'this game', (tester) async {
    final service = _FakeMinigameService();
    await pumpDetail(tester, service: service);

    await tester.scrollUntilVisible(
      find.text('Aún no hay partidas de Verdad o Reto'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Aún no hay partidas de Verdad o Reto'), findsOneWidget);
    expect(find.text('Toca «Nueva partida» para crear la primera.'),
        findsOneWidget);
  });

  testWidgets('a PENDING INVITE renders the invited partida (partida-1) '
      'with the invite chip — the invitee sees the match ready to accept '
      '(170_minigame_invite_badges)', (tester) async {
    final service = _FakeMinigameService()
      ..pendingInvites = [
        {
          'id': 'invited-session',
          'group_id': null,
          'game_type': 'truth_dare',
          'status': 'active',
          'shard_wager': 0,
          'participants': ['99999999-9999-9999-9999-999999999999'],
          'winner_id': null,
          'created_at': '2026-08-29T10:00:00Z',
          'name': null,
          'auto_name': 'partida-1',
        },
      ];
    await pumpDetail(tester, service: service);

    // The invitee's pending match shows in the ongoing list with the
    // server-canonical name and the pending-invite chip.
    await tester.scrollUntilVisible(
      find.text('PARTIDAS EN CURSO'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('partida-1'), findsOneWidget);
    expect(find.text('Invitación pendiente'), findsOneWidget);
  });

  testWidgets(
      '"Nueva partida" opens the wizard: default 10-shard wager + entered '
      'name create a direct session through the provider (wiring)', (
      tester) async {
    final service = _FakeMinigameService();
    await pumpDetail(tester, service: service);

    await tester.tap(find.text('Nueva partida'));
    await tester.pumpAndSettle();

    // The wizard defaults to the Directa scope and a 10-shard wager. The
    // name field (no label) shows the next auto name as just "partida-XX".
    expect(find.text('Nombre (opcional)'), findsNothing);
    expect(find.text('partida-1'), findsNWidgets(1));
    expect(find.text('Directa'), findsOneWidget);
    expect(find.text('Grupo'), findsOneWidget);
    expect(find.text('Por defecto: 10'), findsOneWidget);

    // The wager row shows "Usando:" inline to the right of the input and the
    // available balance from the profile further right.
    expect(find.text('Usando:'), findsOneWidget);
    expect(find.text('Disponibles'), findsOneWidget);
    expect(find.text('120 shards'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'La revancha');
    await tester.tap(find.text('Crear partida'));
    await tester.pumpAndSettle();

    // The create action first opens the player picker (140_minigame_invites);
    // back dismisses it without selecting anyone and the session is created.
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(service.createCalls, 1);
    expect(service.lastCreatedType, MinigameType.truthDare);
    expect(service.lastCreatedWager, 10);
    expect(service.lastCreatedName, 'La revancha');
  });

  testWidgets('a blank name still creates the partida (auto-name fallback) '
      'with the default wager', (tester) async {
    final service = _FakeMinigameService();
    await pumpDetail(tester, service: service);

    await tester.tap(find.text('Nueva partida'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Crear partida'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(service.createCalls, 1);
    expect(service.lastCreatedName, '');
    expect(service.lastCreatedWager, 10);
  });
}
