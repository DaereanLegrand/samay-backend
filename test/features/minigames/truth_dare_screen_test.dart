import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/minigames/screens/truth_dare_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show GoTrueClient, RealtimeChannel, SupabaseClient;

import '../../support/fake_supabase_http.dart' as support;
import '../../support/stub_auth_notifier.dart';

const _sessionId = '33333333-3333-3333-3333-333333333333';
const _myUserId = '11111111-1111-1111-1111-111111111111';
const _otherUserId = '22222222-2222-2222-2222-222222222222';

class _FakeMinigameService implements MinigameService {
  _FakeMinigameService({this.isMyTurn = true});

  final bool isMyTurn;
  int revealCalls = 0;
  int advanceCalls = 0;
  int completeCalls = 0;
  String? lastPromptType;
  Map<String, dynamic>? _current;

  Map<String, dynamic> _state({String? phase, String? promptType, bool revealed = false}) {
    return {
      'session_id': _sessionId,
      'game_type': 'truth_dare',
      'state': {
        'judge_index': 0,
        'round': 0,
        'phase': phase ?? 'playing',
        'subject_id': isMyTurn ? _myUserId : _otherUserId,
        'prompt_type': promptType,
        'prompt': revealed
            ? {'id': 'p-1', 'body': '¿Cuál fue tu primer beso?'}
            : null,
      },
      'rounds': <dynamic>[],
      'created_at': '2026-08-28T10:00:00Z',
      'updated_at': '2026-08-28T10:00:00Z',
    };
  }

  Map<String, dynamic> get current => _current ??= _state();

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
  Future<Map<String, dynamic>?> getSession(String id) async => {
    'id': id,
    'group_id': null,
    'game_type': 'truth_dare',
    'status': 'active',
    'shard_wager': 0,
    'participants': [
      {'id': _myUserId, 'username': 'yo'},
      {'id': _otherUserId, 'username': 'otro'},
    ],
    'winner_id': null,
    'created_at': '2026-08-28T10:00:00Z',
  };

  @override
  Future<String> createSession(
    String? groupId,
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
    String? name,
  }) async =>
      _sessionId;

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
  RealtimeChannel subscribeToSession(String id) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMinigameGameState(String sessionId) async =>
      _current;

  @override
  Future<Map<String, dynamic>> initMinigameGameState(String sessionId) async =>
      _current = _state();

  @override
  Future<Map<String, dynamic>> revealMinigamePrompt(
    String sessionId,
    String promptType,
  ) async {
    revealCalls++;
    lastPromptType = promptType;
    return _current = _state(promptType: promptType, revealed: true);
  }

  @override
  Future<Map<String, dynamic>> advanceMinigameTurn(
    String sessionId,
    Map<String, dynamic> round,
  ) async {
    advanceCalls++;
    return _current = _state();
  }

  @override
  Future<void> completeMinigameGame(String sessionId) async {
    completeCalls++;
  }

  @override
  RealtimeChannel subscribeToGameState(String sessionId) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(support.initSupabaseHarness);

  Future<void> pumpTruthDare(
    WidgetTester tester, {
    required _FakeMinigameService service,
    bool myTurn = true,
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
          path: '/play',
          builder: (_, _) => const TruthDareScreen(sessionId: _sessionId),
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
    router.go('/play');
    await tester.pumpAndSettle();
  }

  testWidgets('my turn shows the Verdad/Reto picker (wiring to reveal)',
      (tester) async {
    final service = _FakeMinigameService(isMyTurn: true);
    await pumpTruthDare(tester, service: service);

    expect(find.text('Verdad'), findsOneWidget);
    expect(find.text('Reto'), findsOneWidget);

    await tester.tap(find.text('Verdad'));
    await tester.pumpAndSettle();

    expect(service.revealCalls, 1);
    expect(service.lastPromptType, 'verdad');
  });

  testWidgets('revealed prompt shows Hecho/Saltar (wiring to advance)',
      (tester) async {
    final service = _FakeMinigameService(isMyTurn: true);
    await pumpTruthDare(tester, service: service);

    await tester.tap(find.text('Reto'));
    await tester.pumpAndSettle();
    expect(service.revealCalls, 1);

    await tester.tap(find.text('Hecho'));
    await tester.pumpAndSettle();

    expect(service.advanceCalls, 1);
  });

  testWidgets('not-my-turn shows the waiting header and no picker',
      (tester) async {
    final service = _FakeMinigameService(isMyTurn: false);
    await pumpTruthDare(tester, service: service);

    expect(find.text('Verdad'), findsNothing);
    expect(find.text('Reto'), findsNothing);
    // The header + the waiting body both name the subject.
    expect(find.textContaining('Le toca a'), findsNWidgets(2));
  });

  testWidgets('ending the game confirms then settles (wiring to complete)',
      (tester) async {
    final service = _FakeMinigameService(isMyTurn: true);
    await pumpTruthDare(tester, service: service);

    await tester.tap(find.text('Terminar juego'));
    await tester.pumpAndSettle();
    expect(find.text('Terminar juego'), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, 'Terminar juego').last);
    await tester.pumpAndSettle();

    expect(service.completeCalls, 1);
  });
}
