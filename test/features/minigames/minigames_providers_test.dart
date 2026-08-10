import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:samay/core/providers/realtime_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _sessionId = '33333333-3333-3333-3333-333333333333';

Map<String, dynamic> _session({
  String id = _sessionId,
  String status = 'active',
  int wager = 0,
}) {
  return {
    'id': id,
    'group_id': _groupId,
    'game_type': 'poke_chain',
    'status': status,
    'shard_wager': wager,
    'participants': [_userId],
    'winner_id': null,
    'created_at': '2026-08-09T21:00:00Z',
  };
}

class _FakeMinigameService implements MinigameService {
  _FakeMinigameService({
    this.sessions = const [],
    this.sessionError,
    this.createError,
  });

  List<Map<String, dynamic>> sessions;
  Object? sessionError;
  Object? createError;
  int listFetches = 0;
  int joinCalls = 0;
  int statusUpdates = 0;
  MinigameType? lastCreatedType;
  int? lastCreatedWager;

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
  Future<Map<String, dynamic>?> getSession(String id) async {
    if (id != _sessionId) return null;
    return _session();
  }

  @override
  Future<String> createSession(
    String groupId,
    MinigameType type,
    int wager,
  ) async {
    if (createError != null) throw createError!;
    lastCreatedType = type;
    lastCreatedWager = wager;
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
  RealtimeChannel subscribeToSession(String id) =>
      throw UnimplementedError();
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
}

Override _realtimeOverride(Stream<Map<String, dynamic>> stream) {
  return realtimeChannelProvider.overrideWith((ref, request) => stream);
}