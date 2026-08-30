import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/minigames/screens/minigame_session_detail_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show GoTrueClient, RealtimeChannel, SupabaseClient;

import '../../support/fake_supabase_http.dart' as support;
import '../../support/stub_auth_notifier.dart';

const _sessionId = '33333333-3333-3333-3333-333333333333';
const _creatorId = '11111111-1111-1111-1111-111111111111';
const _playerId = '22222222-2222-2222-2222-222222222222';

/// Partida lobby tests (180_minigame_lobby): the REALTIME participants list
/// (ready toggles wire through `set_minigame_ready`), the creator-only Start
/// button (backend-enforced — `init_minigame_game_state`), and creator-only
/// player removal (`remove_minigame_participant`). The AppBar title is the
/// minigame name in LOWERCASE ("verdad o reto").
class _FakeMinigameService implements MinigameService {
  _FakeMinigameService({this.isCreator = true});

  final bool isCreator;
  int initCalls = 0;
  int cancelCalls = 0;
  int readyCalls = 0;
  int removeCalls = 0;
  bool? lastReady;
  String? lastRemovedId;
  bool _started = false;
  Map<String, bool> readyMap = const {};

  String get _me => isCreator ? _creatorId : _playerId;

  Map<String, dynamic> _session() => {
    'id': _sessionId,
    'group_id': null,
    'game_type': 'truth_dare',
    'status': 'active',
    'shard_wager': 0,
    'participants': [_creatorId, _playerId],
    'winner_id': null,
    'created_at': '2026-08-30T10:00:00Z',
    'name': null,
    'auto_name': 'partida-1',
  };

  Map<String, dynamic>? _state;

  Map<String, dynamic> get _gameState {
    if (!_started) {
      return {
        'session_id': _sessionId,
        'game_type': 'truth_dare',
        'state': <String, dynamic>{},
        'rounds': <dynamic>[],
        'ready': readyMap,
        'created_at': '2026-08-30T10:00:00Z',
        'updated_at': '2026-08-30T10:00:00Z',
      };
    }
    return {
      'session_id': _sessionId,
      'game_type': 'truth_dare',
      'state': {
        'judge_index': 0,
        'round': 0,
        'phase': 'playing',
        'subject_id': _creatorId,
        'prompt_type': null,
        'prompt': null,
      },
      'rounds': <dynamic>[],
      'ready': readyMap,
      'created_at': '2026-08-30T10:00:00Z',
      'updated_at': '2026-08-30T10:00:00Z',
    };
  }

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listSessions(String groupId) async => [];

  @override
  Future<List<Map<String, dynamic>>> listMySessions() async => [];

  @override
  Future<Map<String, dynamic>?> getSession(String id) async => _session();

  @override
  Future<String> createSession(
    String? groupId,
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
    String? name,
  }) async => _sessionId;

  @override
  Future<void> joinSession(String id) async {}

  @override
  Future<void> updateStatus(String id, MinigameStatus status) async {}

  @override
  Future<Map<String, dynamic>?> myInviteForSession(String sessionId) async =>
      null;

  @override
  Future<List<Map<String, dynamic>>> listMyPendingInvites() async => [];

  @override
  Future<void> acceptInvite(String inviteId) async {}

  @override
  Future<void> declineInvite(String inviteId) async {}

  @override
  RealtimeChannel subscribeToSession(String id) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMinigameGameState(String sessionId) async =>
      _state ??= _gameState;

  @override
  Future<Map<String, dynamic>> initMinigameGameState(String sessionId) async {
    initCalls++;
    _started = true;
    return _state = _gameState;
  }

  @override
  Future<void> cancelMinigameStart(String sessionId) async {
    cancelCalls++;
    _started = false;
    _state = _gameState;
  }

  @override
  Future<void> setReady(String sessionId, bool ready) async {
    readyCalls++;
    lastReady = ready;
    readyMap = {...readyMap, _me: ready};
    _state = _gameState;
  }

  @override
  Future<List<Map<String, dynamic>>> getMinigameParticipants(
    String sessionId,
  ) async => [
    {'id': _creatorId, 'username': 'dana', 'avatar_url': null},
    {'id': _playerId, 'username': 'leo', 'avatar_url': null},
  ];

  @override
  Future<void> removeParticipant(String sessionId, String userId) async {
    removeCalls++;
    lastRemovedId = userId;
  }

  @override
  Future<Map<String, dynamic>> revealMinigamePrompt(
    String sessionId,
    String promptType,
  ) async => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> advanceMinigameTurn(
    String sessionId,
    Map<String, dynamic> round,
  ) async => throw UnimplementedError();

  @override
  Future<void> completeMinigameGame(String sessionId) async {}

  @override
  RealtimeChannel subscribeToGameState(String sessionId) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(support.initSupabaseHarness);

  Future<void> pumpLobby(
    WidgetTester tester, {
    required _FakeMinigameService service,
  }) async {
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(
          () => StubAuthNotifier(
            authenticated: true,
            hasProfile: true,
            userId: service.isCreator ? _creatorId : _playerId,
          ),
        ),
        minigameServiceProvider.overrideWithValue(service),
        realtimeChannelProvider.overrideWith(
          (ref, request) => const Stream<Map<String, dynamic>>.empty(),
        ),
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
          path: '/lobby',
          builder: (_, _) =>
              const MinigameSessionDetailScreen(sessionId: _sessionId),
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
    router.go('/lobby');
    await tester.pumpAndSettle();
  }

  testWidgets('AppBar title is the LOWERCASE minigame name (verdad o reto)', (
    tester,
  ) async {
    final service = _FakeMinigameService();
    await pumpLobby(tester, service: service);

    // The AppBar carries the LOWERCASE game name; the body no longer repeats
    // the capitalized title (2026-08-30 user directive).
    expect(find.text('verdad o reto'), findsOneWidget);
    expect(find.text('Verdad o Reto'), findsNothing);
  });

  testWidgets('realtime participants list renders names + host marker, and '
      'the non-creator ¿Listo? toggle wires through set_minigame_ready', (
    tester,
  ) async {
    final service = _FakeMinigameService(isCreator: false);
    await pumpLobby(tester, service: service);

    expect(find.text('JUGADORES'), findsOneWidget);
    expect(find.text('dana'), findsOneWidget);
    expect(find.text('leo'), findsOneWidget);
    expect(find.text('Anfitrión'), findsOneWidget);

    // Nobody is ready yet: no chips anywhere.
    expect(find.text('Listo'), findsNothing);
    expect(find.text('No listo'), findsNothing);

    // The non-creator's ready toggle sits where the creator's Start button
    // would be — tapping it wires set_minigame_ready(true).
    expect(find.text('¿Listo?'), findsOneWidget);
    await tester.tap(find.text('¿Listo?'));
    await tester.pumpAndSettle();
    expect(service.readyCalls, 1);
    expect(service.lastReady, isTrue);
  });

  testWidgets('creator Start button wires init_minigame_game_state', (
    tester,
  ) async {
    final service = _FakeMinigameService();
    await pumpLobby(tester, service: service);

    expect(find.text('Empezar'), findsOneWidget);
    await tester.tap(find.text('Empezar'));
    await tester.pumpAndSettle();

    expect(service.initCalls, 1);
  });

  testWidgets('a NON-creator participant sees the ready toggle, no Start '
      'button', (tester) async {
    final service = _FakeMinigameService(isCreator: false);
    await pumpLobby(tester, service: service);

    expect(find.text('¿Listo?'), findsOneWidget);
    expect(find.text('Empezar'), findsNothing);
  });

  testWidgets('creator-only remove: the creator row has no remove button but '
      'the other player does, and removing wires remove_minigame_participant', (
    tester,
  ) async {
    final service = _FakeMinigameService();
    await pumpLobby(tester, service: service);

    // Exactly one remove icon — only for the non-self participant.
    expect(find.byIcon(Icons.person_remove_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.person_remove_outlined));
    await tester.pumpAndSettle();
    // Confirmation dialog.
    expect(find.text('¿Quitar a leo de esta partida?'), findsOneWidget);
    await tester.tap(find.text('Quitar jugador').last);
    await tester.pumpAndSettle();

    expect(service.removeCalls, 1);
    expect(service.lastRemovedId, _playerId);
  });
}
