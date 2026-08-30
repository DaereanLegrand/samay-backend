import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/core/services/rest_client.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:samay/features/minigames/logic/minigame_engine.dart';
import 'package:samay/features/minigames/logic/truth_dare.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
import 'package:samay/features/notifications/providers/notifications_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _sessionId = '33333333-3333-3333-3333-333333333333';

class MockUserService extends Mock implements UserService {}

/// In-memory [NotificationService] fake for the badge-derivation tests: the
/// rows are shaped like real `notifications` table rows so
/// [NotificationItem.fromJson] parses them.
class _FakeNotificationService implements NotificationService {
  _FakeNotificationService(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  RestClient get rest => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getNotifications() async =>
      List.of(rows);

  @override
  Future<void> markNotificationRead(String id) async {}

  @override
  Future<RealtimeChannel> subscribeToNotifications(
    void Function(Map<String, dynamic>) onInsert,
  ) async =>
      throw UnimplementedError();
}

/// A [NotificationService] whose list NEVER resolves — pins that the badge
/// derivation stays zero while the notifications list is still loading.
class _PendingNotificationsNever implements NotificationService {
  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  RestClient get rest => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getNotifications() =>
      Completer<List<Map<String, dynamic>>>().future;

  @override
  Future<void> markNotificationRead(String id) async {}

  @override
  Future<RealtimeChannel> subscribeToNotifications(
    void Function(Map<String, dynamic>) onInsert,
  ) async =>
      throw UnimplementedError();
}

Map<String, dynamic> _session({
  String id = _sessionId,
  String status = 'active',
  int wager = 0,
  String gameType = 'poke_chain',
}) {
  return {
    'id': id,
    'group_id': _groupId,
    'game_type': gameType,
    'status': status,
    'shard_wager': wager,
    'participants': [_userId],
    'winner_id': null,
    'created_at': '2026-08-09T21:00:00Z',
  };
}

Map<String, dynamic> _gameState({
  String sessionId = _sessionId,
  String phase = 'playing',
  int round = 0,
  String? subjectId = _userId,
  String? promptType,
  Map<String, dynamic>? prompt,
  Map<String, dynamic>? ready,
}) {
  return {
    'session_id': sessionId,
    'game_type': 'truth_dare',
    'state': {
      'judge_index': 0,
      'round': round,
      'phase': phase,
      'subject_id': subjectId,
      'prompt_type': promptType,
      'prompt': prompt,
    },
    'rounds': <dynamic>[],
    'ready': ready ?? const <String, dynamic>{},
    'created_at': '2026-08-28T10:00:00Z',
    'updated_at': '2026-08-28T10:00:00Z',
  };
}

class _FakeMinigameService implements MinigameService {
  _FakeMinigameService({
    this.sessions = const [],
    this.sessionError,
    this.createError,
  });

  List<Map<String, dynamic>> sessions;
  List<Map<String, dynamic>> pendingInvites = [];
  Object? sessionError;
  Object? createError;
  int listFetches = 0;
  int joinCalls = 0;
  int statusUpdates = 0;
  int acceptCalls = 0;
  int declineCalls = 0;
  MinigameType? lastCreatedType;
  int? lastCreatedWager;
  List<String>? lastInviteeIds;
  String? lastCreatedName;
  Map<String, dynamic>? inviteRow;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  RealtimeService get realtime => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listSessions(String groupId) async {
    listFetches++;
    if (sessionError != null) throw sessionError!;
    return List.of(sessions);
  }

  @override
  Future<List<Map<String, dynamic>>> listMySessions() async {
    listFetches++;
    if (sessionError != null) throw sessionError!;
    return List.of(sessions);
  }

  @override
  Future<Map<String, dynamic>?> getSession(String id) async {
    if (id != _sessionId) return null;
    return _session();
  }

  @override
  Future<String> createSession(
    String? groupId,
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
    String? name,
  }) async {
    if (createError != null) throw createError!;
    lastCreatedType = type;
    lastCreatedWager = wager;
    lastInviteeIds = inviteeIds;
    lastCreatedName = name;
    sessions = [_session(id: _sessionId), ...sessions];
    return _sessionId;
  }

  @override
  Future<void> joinSession(String id) async {
    joinCalls++;
  }

  @override
  Future<void> updateStatus(String id, MinigameStatus status) async {
    statusUpdates++;
  }

  @override
  Future<Map<String, dynamic>?> myInviteForSession(String sessionId) async {
    return inviteRow;
  }

  @override
  Future<List<Map<String, dynamic>>> listMyPendingInvites() async {
    listFetches++;
    if (sessionError != null) throw sessionError!;
    return List.of(pendingInvites);
  }

  @override
  Future<void> acceptInvite(String inviteId) async {
    acceptCalls++;
    inviteRow = {
      'id': inviteId,
      'session_id': _sessionId,
      'invitee_id': _userId,
      'created_by': _groupId,
      'status': 'accepted',
      'created_at': '2026-08-26T10:00:00Z',
    };
  }

  @override
  Future<void> declineInvite(String inviteId) async {
    declineCalls++;
    inviteRow = {
      'id': inviteId,
      'session_id': _sessionId,
      'invitee_id': _userId,
      'created_by': _groupId,
      'status': 'declined',
      'created_at': '2026-08-26T10:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>?> getMinigameGameState(String sessionId) async {
    return gameStateRow;
  }

  @override
  Future<Map<String, dynamic>> initMinigameGameState(String sessionId) async {
    initCalls++;
    gameStateRow = _gameState();
    return gameStateRow!;
  }

  @override
  Future<void> cancelMinigameStart(String sessionId) async {
    cancelCalls++;
    gameStateRow = _gameState(phase: 'setup', subjectId: null);
  }

  @override
  Future<Map<String, dynamic>> revealMinigamePrompt(
    String sessionId,
    String promptType,
  ) async {
    revealCalls++;
    lastPromptType = promptType;
    gameStateRow = _gameState(
      promptType: promptType,
      prompt: {'id': 'p-1', 'body': '¿Cuál fue tu primer beso?'},
    );
    return gameStateRow!;
  }

  @override
  Future<Map<String, dynamic>> advanceMinigameTurn(
    String sessionId,
    Map<String, dynamic> round,
  ) async {
    advanceCalls++;
    gameStateRow = _gameState(round: (gameStateRow?['state'] as Map?)?['round'] as int? ?? 0);
    return gameStateRow!;
  }

  @override
  Future<void> completeMinigameGame(String sessionId) async {
    completeCalls++;
    gameStateRow = _gameState(phase: 'finished');
  }

  @override
  Future<void> setReady(String sessionId, bool ready) async {
    readyCalls++;
    lastReady = ready;
    final currentReady = Map<String, dynamic>.from(
      (gameStateRow?['ready'] as Map?) ?? const {},
    );
    currentReady[_userId] = ready;
    gameStateRow = _gameState(ready: currentReady);
  }

  @override
  Future<List<Map<String, dynamic>>> getMinigameParticipants(
    String sessionId,
  ) async {
    participantsFetches++;
    return List.of(participantRows);
  }

  @override
  Future<void> removeParticipant(String sessionId, String userId) async {
    removeCalls++;
    lastRemovedId = userId;
    final ids = participantRows.map((r) => r['id']).toList();
    ids.remove(userId);
    participantRows = [
      for (final id in ids) {'id': id, 'username': 'u-$id'},
    ];
  }

  @override
  RealtimeChannel subscribeToSession(String id) =>
      throw UnimplementedError();

  @override
  RealtimeChannel subscribeToGameState(String sessionId) =>
      throw UnimplementedError();

  Map<String, dynamic>? gameStateRow;
  int initCalls = 0;
  int cancelCalls = 0;
  int revealCalls = 0;
  int advanceCalls = 0;
  int completeCalls = 0;
  int readyCalls = 0;
  int removeCalls = 0;
  int participantsFetches = 0;
  bool? lastReady;
  String? lastRemovedId;
  List<Map<String, dynamic>> participantRows = const [];
  String? lastPromptType;
}

void main() {
  group('minigameSessionsProvider (family by groupId)', () {
    test('loads the group sessions from the service', () async {
      final service = _FakeMinigameService(
        sessions: [_session(), _session(id: '99999999-9999-9999-9999-999999999999')],
      );
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(minigameSessionsProvider(_groupId).future);
      expect(state, hasLength(2));
      expect(service.listFetches, 1);
    });

    test('sessions are scoped per group (separate family members)', () async {
      final service = _FakeMinigameService();
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container.read(minigameSessionsProvider(_groupId).future);
      await container.read(
        minigameSessionsProvider('44444444-4444-4444-4444-444444444444').future,
      );
      expect(service.listFetches, 2);
    });

    test('exposes an AsyncError when the list fetch fails', () async {
      final service = _FakeMinigameService(
        sessionError: Exception('network down'),
      );
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(minigameSessionsProvider(_groupId).future),
        throwsA(isA<Exception>()),
      );
      expect(
        container.read(minigameSessionsProvider(_groupId)).hasError,
        isTrue,
      );
    });

    test('create calls the service, refreshes the list and returns the id',
        () async {
      final service = _FakeMinigameService(sessions: [_session()]);
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(minigameSessionsProvider(_groupId).future);

      final id = await container
          .read(minigameSessionsProvider(_groupId).notifier)
          .create(MinigameType.truthDare, 25);

      expect(id, _sessionId);
      expect(service.lastCreatedType, MinigameType.truthDare);
      expect(service.lastCreatedWager, 25);
      // The action invalidates the list; re-reading it re-runs the fetch.
      await container.read(minigameSessionsProvider(_groupId).future);
      expect(service.listFetches, 2);
    });

    test('create forwards the selected invitee ids to the service', () async {
      final service = _FakeMinigameService(sessions: [_session()]);
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(minigameSessionsProvider(_groupId).future);

      await container
          .read(minigameSessionsProvider(_groupId).notifier)
          .create(
            MinigameType.pokeChain,
            0,
            inviteeIds: const [
              'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
              'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            ],
          );

      expect(service.lastInviteeIds, [
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      ]);
    });

    test('create forwards the partida name to the service '
        '(160_minigame_names)', () async {
      final service = _FakeMinigameService(sessions: [_session()]);
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(minigameSessionsProvider(_groupId).future);

      await container
          .read(minigameSessionsProvider(_groupId).notifier)
          .create(MinigameType.truthDare, 10, name: 'La revancha');

      expect(service.lastCreatedName, 'La revancha');
    });

    test('maps the server rejection to a typed not-member error', () async {
      final service = _FakeMinigameService(
        createError: const MinigameSessionRejectedException(
          MinigameSessionRejection.notMember,
        ),
      );
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(minigameSessionsProvider(_groupId).notifier)
            .create(MinigameType.pokeChain, 10),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.notMember,
          ),
        ),
      );
      expect(service.listFetches, 1);
    });

    test('maps the server rejection to a typed insufficient-shards error',
        () async {
      final service = _FakeMinigameService(
        createError: const MinigameSessionRejectedException(
          MinigameSessionRejection.insufficientShards,
        ),
      );
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(minigameSessionsProvider(_groupId).notifier)
            .create(MinigameType.challenge, 9999),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.insufficientShards,
          ),
        ),
      );
    });

    test('maps the server rejection to a typed invalid-game-type error',
        () async {
      final service = _FakeMinigameService(
        createError: const MinigameSessionRejectedException(
          MinigameSessionRejection.invalidGameType,
        ),
      );
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(minigameSessionsProvider(_groupId).notifier)
            .create(MinigameType.drunkBottle, 0),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.invalidGameType,
          ),
        ),
      );
    });

    test('join calls the service and refreshes the list', () async {
      final service = _FakeMinigameService(sessions: [_session()]);
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(minigameSessionsProvider(_groupId).future);

      await container
          .read(minigameSessionsProvider(_groupId).notifier)
          .join(_sessionId);

      expect(service.joinCalls, 1);
      await container.read(minigameSessionsProvider(_groupId).future);
      expect(service.listFetches, 2);
    });
  });

  group('sessionStatusProvider (family by sessionId)', () {
    test('loads the session row from the service', () async {
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(_FakeMinigameService()),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container
          .read(sessionStatusProvider(_sessionId).future);
      expect(state['id'], _sessionId);
      expect(state['status'], 'active');
    });

    test('applies live realtime rows to the status (GMCR Realtime sync)',
        () async {
      final updates = StreamController<Map<String, dynamic>>();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(_FakeMinigameService()),
          _realtimeOverride(updates.stream),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(updates.close);

      final initial = await container
          .read(sessionStatusProvider(_sessionId).future);
      expect(initial['status'], 'active');

      updates.add(_session(status: 'finished'));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(sessionStatusProvider(_sessionId));
      expect(state.valueOrNull?['status'], 'finished');
    });
  });

  group('minigameInviteProvider (family by sessionId)', () {
    test('loads the current user\'s invite row for the session', () async {
      final service = _FakeMinigameService(
        sessions: [_session()],
      )..inviteRow = {
          'id': 'invite-1',
          'session_id': _sessionId,
          'invitee_id': _userId,
          'created_by': _groupId,
          'status': 'pending',
          'created_at': '2026-08-26T10:00:00Z',
        };
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(minigameInviteProvider(_sessionId).future);
      expect(state?['status'], 'pending');
    });

    test('is null when the user has no invite for the session', () async {
      final service = _FakeMinigameService();
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(minigameInviteProvider(_sessionId).future);
      expect(state, isNull);
    });

    test('accept calls the service and refreshes the invite + session status',
        () async {
      final service = _FakeMinigameService()
        ..inviteRow = {
          'id': 'invite-1',
          'session_id': _sessionId,
          'invitee_id': _userId,
          'created_by': _groupId,
          'status': 'pending',
          'created_at': '2026-08-26T10:00:00Z',
        };
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(minigameInviteProvider(_sessionId).future);

      await container.read(minigameInviteProvider(_sessionId).notifier).accept();

      expect(service.acceptCalls, 1);
      final state = await container.read(minigameInviteProvider(_sessionId).future);
      expect(state?['status'], 'accepted');
    });

    test('decline calls the service and refreshes the invite', () async {
      final service = _FakeMinigameService()
        ..inviteRow = {
          'id': 'invite-1',
          'session_id': _sessionId,
          'invitee_id': _userId,
          'created_by': _groupId,
          'status': 'pending',
          'created_at': '2026-08-26T10:00:00Z',
        };
      final container = ProviderContainer(
        overrides: [minigameServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(minigameInviteProvider(_sessionId).future);

      await container.read(minigameInviteProvider(_sessionId).notifier).decline();

      expect(service.declineCalls, 1);
      final state = await container.read(minigameInviteProvider(_sessionId).future);
      expect(state?['status'], 'declined');
    });
  });

  group('minigameInviteFriendsOnlyProvider', () {
    test('reads the persisted switch via UserService', () async {
      final users = MockUserService();
      when(() => users.getMinigameInviteFriendsOnly())
          .thenAnswer((_) async => true);
      final container = ProviderContainer(
        overrides: [userServiceProvider.overrideWithValue(users)],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(minigameInviteFriendsOnlyProvider.future),
        isTrue,
      );
    });

    test('persists the switch and flips the provider state', () async {
      final users = MockUserService();
      when(() => users.getMinigameInviteFriendsOnly())
          .thenAnswer((_) async => false);
      when(() => users.setMinigameInviteFriendsOnly(true))
          .thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [userServiceProvider.overrideWithValue(users)],
      );
      addTearDown(container.dispose);

      await container
          .read(minigameInviteFriendsOnlyProvider.notifier)
          .setFriendsOnly(true);

      expect(
        container.read(minigameInviteFriendsOnlyProvider).valueOrNull,
        isTrue,
      );
      verify(() => users.setMinigameInviteFriendsOnly(true)).called(1);
    });
  });

  group('pendingMinigameInvitesByTypeProvider (170_minigame_invite_badges)',
      () {
    Map<String, dynamic> notificationRow({
      String type = 'minigame_invite',
      bool read = false,
      Map<String, dynamic>? data,
    }) {
      return {
        'id': 'n-${DateTime.now().microsecondsSinceEpoch}',
        'type': type,
        'title': 'Invitación a minijuego',
        'body': 'Te invitaron a un minijuego',
        'data': data,
        'read': read,
        'created_at': '2026-08-30T10:00:00Z',
      };
    }

    test('groups unread minigame_invite notifications by gameType', () async {
      final fake = _FakeNotificationService([
        notificationRow(data: {'gameType': 'truth_dare'}),
        notificationRow(data: {'gameType': 'truth_dare'}),
        notificationRow(data: {'gameType': 'poke_chain'}),
        notificationRow(read: true, data: {'gameType': 'challenge'}),
        notificationRow(type: 'friend_request', data: null),
      ]);
      final container = ProviderContainer(
        overrides: [notificationServiceProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);

      await container.read(notificationsProvider.future);
      final byType = container.read(pendingMinigameInvitesByTypeProvider);

      expect(byType['truth_dare'], 2);
      expect(byType['poke_chain'], 1);
      expect(byType.containsKey('challenge'), isFalse,
          reason: 'read invites are excluded');
      expect(byType.containsKey(null), isFalse,
          reason: 'non-minigame types are excluded');
    });

    test('is empty while the notifications list is loading', () {
      final container = ProviderContainer(
        overrides: [
          notificationServiceProvider.overrideWithValue(
            _PendingNotificationsNever(),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(pendingMinigameInvitesByTypeProvider), isEmpty);
    });
  });

  group('myPendingInvitesProvider (170_minigame_invite_badges)', () {
    test('loads the pending invite sessions from the service', () async {
      final service = _FakeMinigameService()
        ..pendingInvites = [
          _session(id: _sessionId, gameType: 'truth_dare'),
        ];
      final fake = _FakeNotificationService(const []);
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          notificationServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(myPendingInvitesProvider.future);

      expect(state, hasLength(1));
      expect(state.single['id'], _sessionId);
    });

    test('refresh re-runs the service fetch', () async {
      final service = _FakeMinigameService();
      final fake = _FakeNotificationService(const []);
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          notificationServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);
      await container.read(myPendingInvitesProvider.future);

      await container.read(myPendingInvitesProvider.notifier).refresh();
      await container.read(myPendingInvitesProvider.future);

      expect(service.listFetches, 2);
    });
  });

  group('minigameGameStateProvider (150_minigame_play)', () {
    test('loads the state row and parses the nested skeleton', () async {
      final service = _FakeMinigameService()..gameStateRow = _gameState();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(minigameGameStateProvider(_sessionId).future);

      expect(state.sessionId, _sessionId);
      expect(state.gameType, 'truth_dare');
      expect(state.skeleton.subjectId, _userId);
      expect(state.isFinished, isFalse);
    });

    test('does NOT auto-initialize when no game-state row exists (180: '
        'Start is the creator''s explicit action)', () async {
      final service = _FakeMinigameService(); // gameStateRow = null → not_started
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(minigameGameStateProvider(_sessionId).future);

      // A not-started session stays a lobby: no init fired, empty skeleton.
      expect(service.initCalls, 0);
      expect(state.skeleton.phase, MinigamePhase.setup);
      expect(state.skeleton.subjectId, isNull);
    });

    test('start() calls init_minigame_game_state (creator-only, '
        'backend-enforced) and seeds the skeleton', () async {
      final service = _FakeMinigameService(); // gameStateRow = null → not_started
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(minigameGameStateProvider(_sessionId).future);

      await container
          .read(minigameGameStateProvider(_sessionId).notifier)
          .start();

      expect(service.initCalls, 1);
      final state = await container.read(minigameGameStateProvider(_sessionId).future);
      expect(state.skeleton.phase, MinigamePhase.playing);
      expect(state.skeleton.subjectId, _userId);
    });

    test('reveal calls the service with the kind wire value and reloads',
        () async {
      final service = _FakeMinigameService()..gameStateRow = _gameState();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(minigameGameStateProvider(_sessionId).future);

      await container
          .read(minigameGameStateProvider(_sessionId).notifier)
          .reveal(TruthDareKind.truth);

      expect(service.revealCalls, 1);
      expect(service.lastPromptType, 'verdad');
      final state = await container.read(minigameGameStateProvider(_sessionId).future);
      expect(state.skeleton.promptType, 'verdad');
      expect(state.hasPrompt, isTrue);
    });

    test('advance closes the round and advances the turn', () async {
      final service = _FakeMinigameService()..gameStateRow = _gameState();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(minigameGameStateProvider(_sessionId).future);

      await container
          .read(minigameGameStateProvider(_sessionId).notifier)
          .advance();

      expect(service.advanceCalls, 1);
    });

    test('complete settles the game and flips the finished phase', () async {
      final service = _FakeMinigameService()..gameStateRow = _gameState();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(const Stream<Map<String, dynamic>>.empty()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(minigameGameStateProvider(_sessionId).future);

      await container
          .read(minigameGameStateProvider(_sessionId).notifier)
          .complete();

      expect(service.completeCalls, 1);
      final state = await container.read(minigameGameStateProvider(_sessionId).future);
      expect(state.isFinished, isTrue);
    });

    test('merges live realtime rows on the game-state channel', () async {
      final updates = StreamController<Map<String, dynamic>>();
      final service = _FakeMinigameService()..gameStateRow = _gameState();
      final container = ProviderContainer(
        overrides: [
          minigameServiceProvider.overrideWithValue(service),
          _realtimeOverride(updates.stream),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(updates.close);

      final initial = await container.read(minigameGameStateProvider(_sessionId).future);
      expect(initial.isFinished, isFalse);

      updates.add(_gameState(phase: 'finished'));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(minigameGameStateProvider(_sessionId));
      expect(state.valueOrNull?.isFinished, isTrue);
    });
  });
}

Override _realtimeOverride(Stream<Map<String, dynamic>> stream) {
  return realtimeChannelProvider.overrideWith((ref, request) => stream);
}