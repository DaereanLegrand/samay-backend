import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

/// MinigameService contract tests (I-63, GMCR/GWAG foundation):
///
/// * `listSessions` / `getSession` — typed reads on `minigame_sessions`
///   (RLS `ms_read_group_member`: group members only).
/// * `createSession` — invokes the `create_minigame_session` RPC (migration
///   20260809000006): server validates membership + balance and performs the
///   atomic deduct + ledger + session insert; the client only maps the enum
///   values to the RPC params.
/// * `joinSession` / `updateStatus` — server-side contracts via the
///   `join_minigame_session` / `finish_minigame_session` SECURITY DEFINER
///   RPCs (migration 20260813000001, I-77/S-03 gap closed): the client sends
///   only the session id; membership, escrow deduction/settlement and the
///   status flip happen in the RPC transaction (minigame_sessions has no
///   UPDATE policy under FORCE RLS).
/// * `subscribeToSession` — realtime channel on `minigame_sessions`
///   (GMCR Realtime sync).
const _userId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _sessionId = '33333333-3333-3333-3333-333333333333';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

class MockRealtimeService extends Mock implements RealtimeService {}

Map<String, dynamic> _session({
  String id = _sessionId,
  String status = 'active',
  int wager = 0,
  List<String> participants = const [_userId],
}) {
  return {
    'id': id,
    'group_id': _groupId,
    'game_type': 'poke_chain',
    'status': status,
    'shard_wager': wager,
    'participants': participants,
    'winner_id': null,
    'created_at': '2026-08-09T21:00:00Z',
  };
}

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;
  late MockRealtimeService realtime;

  setUp(() {
    registerFallbackValue(PostgresChangeEvent.insert);
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    realtime = MockRealtimeService();
    when(() => client.auth).thenReturn(auth);
  });

  MinigameService service() =>
      MinigameService(client: client, realtime: realtime);

  group('MinigameType / MinigameStatus enum values', () {
    test('map to the DB enum strings (mini_game_type / mini_game_status)', () {
      expect(MinigameType.pokeChain.value, 'poke_chain');
      expect(MinigameType.questions.value, 'questions');
      expect(MinigameType.truthDare.value, 'truth_dare');
      expect(MinigameType.drunkBottle.value, 'drunk_bottle');
      expect(MinigameType.challenge.value, 'challenge');
      expect(MinigameStatus.active.value, 'active');
      expect(MinigameStatus.finished.value, 'finished');
    });
  });

  group('MinigameService.listSessions', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => table);
    });

    test(
      'queries the group sessions newest first (RLS ms_read_group_member)',
      () async {
        final rows = ResolvingBuilder<PostgrestList>([_session()]);
        when(() => table.select(any())).thenAnswer((_) => rows);

        final sessions = await service().listSessions(_groupId);

        expect(sessions, hasLength(1));
        expect(sessions.single['id'], _sessionId);
        expect(
          rows.filters,
          containsAllInOrder([const RecordedFilter('group_id', _groupId)]),
        );
      },
    );

    test('propagates a PostgrestException (e.g. FORCE-RLS denial)', () async {
      when(() => table.select(any())).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      expect(
        () => service().listSessions(_groupId),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('MinigameService.getSession', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => table);
    });

    test('returns the row by id via maybeSingle', () async {
      when(
        () => table.select(any()),
      ).thenAnswer((_) => ResolvingBuilder<PostgrestList>(_session()));

      final session = await service().getSession(_sessionId);

      expect(session, isNotNull);
      expect(session!['status'], 'active');
      expect(session['participants'], [_userId]);
    });

    test('returns null when the session does not exist', () async {
      when(
        () => table.select(any()),
      ).thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getSession(_sessionId), isNull);
    });
  });

  group('MinigameService.createSession', () {
    test(
      'invokes the create_minigame_session RPC and returns the id',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final rpc = ResolvingBuilder<dynamic>({
          'status': 'created',
          'sessionId': _sessionId,
        });
        when(
          () => client.rpc(
            'create_minigame_session',
            params: any(named: 'params'),
          ),
        ).thenAnswer((_) => rpc);

        final id = await service().createSession(
          _groupId,
          MinigameType.pokeChain,
          50,
        );

        expect(id, _sessionId);
        final params =
            verify(
                  () => client.rpc(
                    'create_minigame_session',
                    params: captureAny(named: 'params'),
                  ),
                ).captured.single
                as Map<String, dynamic>;
        expect(params, {
          'p_group_id': _groupId,
          'p_game_type': 'poke_chain',
          'p_wager': 50,
        });
      },
    );

    test('supports a zero wager (social games, GWAG: 0 = no wager)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'created',
        'sessionId': _sessionId,
      });
      when(
        () =>
            client.rpc('create_minigame_session', params: any(named: 'params')),
      ).thenAnswer((_) => rpc);

      await service().createSession(_groupId, MinigameType.drunkBottle, 0);

      final params =
          verify(
                () => client.rpc(
                  'create_minigame_session',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params['p_wager'], 0);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().createSession(_groupId, MinigameType.questions, 10),
        throwsA(isA<Exception>()),
      );
      verifyNever(
        () =>
            client.rpc('create_minigame_session', params: any(named: 'params')),
      );
    });

    test('propagates the server balance rejection', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('create_minigame_session', params: any(named: 'params')),
      ).thenThrow(
        const PostgrestException(message: 'Insufficient shards', code: 'P0001'),
      );

      expect(
        () => service().createSession(_groupId, MinigameType.challenge, 5000),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('MinigameService.joinSession', () {
    test('invokes the join_minigame_session RPC (server-side join, I-77/S-03 '
        'gap closed)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({'status': 'joined'});
      when(
        () => client.rpc('join_minigame_session', params: any(named: 'params')),
      ).thenAnswer((_) => rpc);

      await service().joinSession(_sessionId);

      final params =
          verify(
                () => client.rpc(
                  'join_minigame_session',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId});
      verifyNever(() => client.from('minigame_sessions').update(any()));
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().joinSession(_sessionId),
        throwsA(isA<Exception>()),
      );
      verifyNever(
        () => client.rpc('join_minigame_session', params: any(named: 'params')),
      );
    });

    test(
      'propagates the server membership rejection as a typed exception',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        when(
          () =>
              client.rpc('join_minigame_session', params: any(named: 'params')),
        ).thenAnswer(
          (_) => ResolvingBuilder<dynamic>({'status': 'not_member'}),
        );

        expect(
          () => service().joinSession(_sessionId),
          throwsA(
            isA<MinigameSessionRejectedException>().having(
              (e) => e.rejection,
              'rejection',
              MinigameSessionRejection.notMember,
            ),
          ),
        );
      },
    );

    test(
      'propagates the server balance rejection as a typed exception',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        when(
          () =>
              client.rpc('join_minigame_session', params: any(named: 'params')),
        ).thenAnswer(
          (_) => ResolvingBuilder<dynamic>({'status': 'insufficient_shards'}),
        );

        expect(
          () => service().joinSession(_sessionId),
          throwsA(
            isA<MinigameSessionRejectedException>().having(
              (e) => e.rejection,
              'rejection',
              MinigameSessionRejection.insufficientShards,
            ),
          ),
        );
      },
    );

    test('throws when the server reports the session missing', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc('join_minigame_session', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'session_not_found'}),
      );

      expect(
        () => service().joinSession(_sessionId),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('MinigameService.updateStatus', () {
    test('finishing invokes the finish_minigame_session RPC with a null '
        'winner (draw settlement)', () async {
      when(
        () =>
            client.rpc('finish_minigame_session', params: any(named: 'params')),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'finished'}));

      await service().updateStatus(_sessionId, MinigameStatus.finished);

      final params =
          verify(
                () => client.rpc(
                  'finish_minigame_session',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {
        'p_session_id': _sessionId,
        'p_winner_id': null,
        'p_place': null,
      });
      verifyNever(() => client.from('minigame_sessions').update(any()));
    });

    test('treats already_finished as an idempotent no-op', () async {
      when(
        () =>
            client.rpc('finish_minigame_session', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'already_finished'}),
      );

      await service().updateStatus(_sessionId, MinigameStatus.finished);
    });

    test('rejects reactivation (no server contract for active)', () async {
      expect(
        () => service().updateStatus(_sessionId, MinigameStatus.active),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => client.rpc(any(), params: any(named: 'params')));
    });

    test('throws when the server reports the session missing', () async {
      when(
        () =>
            client.rpc('finish_minigame_session', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'session_not_found'}),
      );

      expect(
        () => service().updateStatus(_sessionId, MinigameStatus.finished),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('MinigameService.subscribeToSession', () {
    test(
      'opens a realtime channel on minigame_sessions updates (GMCR sync)',
      () {
        final channel = MockRealtimeChannel();
        when(
          () => realtime.subscribeToChannel(
            any(),
            any(),
            any(),
            any(),
            onStatus: any(named: 'onStatus'),
          ),
        ).thenReturn(channel);

        final result = service().subscribeToSession(_sessionId);

        expect(result, channel);
        verify(
          () => realtime.subscribeToChannel(
            'minigame-session:$_sessionId',
            PostgresChangeEvent.update,
            'minigame_sessions',
            any(),
            onStatus: any(named: 'onStatus'),
          ),
        ).called(1);
      },
    );
  });
}
