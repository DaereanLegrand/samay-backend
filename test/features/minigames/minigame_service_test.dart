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
/// * `joinSession` / `updateStatus` — client-side contracts on the row
///   (documented server RPC gap: minigame_sessions has no UPDATE policy
///   under FORCE RLS — settlement/join RPCs are the I-77/S-03 handoff).
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

  MinigameService service() => MinigameService(client: client, realtime: realtime);

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

    test('queries the group sessions newest first (RLS ms_read_group_member)',
        () async {
      final rows = ResolvingBuilder<PostgrestList>([_session()]);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final sessions = await service().listSessions(_groupId);

      expect(sessions, hasLength(1));
      expect(sessions.single['id'], _sessionId);
      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('group_id', _groupId),
      ]));
    });

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
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(_session()));

      final session = await service().getSession(_sessionId);

      expect(session, isNotNull);
      expect(session!['status'], 'active');
      expect(session['participants'], [_userId]);
    });

    test('returns null when the session does not exist', () async {
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getSession(_sessionId), isNull);
    });
  });

  group('MinigameService.createSession', () {
    test('invokes the create_minigame_session RPC and returns the id', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({'status': 'created', 'sessionId': _sessionId});
      when(() => client.rpc('create_minigame_session', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      final id = await service().createSession(
        _groupId,
        MinigameType.pokeChain,
        50,
      );

      expect(id, _sessionId);
      final params =
          verify(() => client.rpc('create_minigame_session', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params, {
        'p_group_id': _groupId,
        'p_game_type': 'poke_chain',
        'p_wager': 50,
      });
    });

    test('supports a zero wager (social games, GWAG: 0 = no wager)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({'status': 'created', 'sessionId': _sessionId});
      when(() => client.rpc('create_minigame_session', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      await service().createSession(_groupId, MinigameType.drunkBottle, 0);

      final params =
          verify(() => client.rpc('create_minigame_session', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params['p_wager'], 0);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().createSession(_groupId, MinigameType.questions, 10),
        throwsA(isA<Exception>()),
      );
      verifyNever(
        () => client.rpc('create_minigame_session', params: any(named: 'params')),
      );
    });

    test('propagates the server balance rejection', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => client.rpc('create_minigame_session', params: any(named: 'params')))
          .thenThrow(
        const PostgrestException(
          message: 'Insufficient shards',
          code: 'P0001',
        ),
      );

      expect(
        () => service().createSession(_groupId, MinigameType.challenge, 5000),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('MinigameService.joinSession', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => table);
    });

    test('appends the current user to the participants array (self only)',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(
                _session(participants: const []),
              ));
      when(() => table.update(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(<Map<String, dynamic>>[]),
      );

      await service().joinSession(_sessionId);

      final update = Map<String, dynamic>.from(
        verify(() => table.update(captureAny())).captured.single as Map,
      );
      expect(update['participants'], [_userId]);
    });

    test('is a no-op when the user is already a participant', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(_session()));

      await service().joinSession(_sessionId);

      verifyNever(
        () => table.update(any()),
      );
    });

    test('throws when the session does not exist', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(() => service().joinSession(_sessionId), throwsA(isA<Exception>()));
      verifyNever(
        () => table.update(any()),
      );
    });
  });

  group('MinigameService.updateStatus', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => table);
    });

    test('patches the status column for the session id', () async {
      final rows = ResolvingBuilder<PostgrestList>(<Map<String, dynamic>>[]);
      when(() => table.update(any())).thenAnswer((_) => rows);

      await service().updateStatus(_sessionId, MinigameStatus.finished);

      final update = Map<String, dynamic>.from(
        verify(() => table.update(captureAny())).captured.single as Map,
      );
      expect(update, {'status': 'finished'});
    });
  });

  group('MinigameService.subscribeToSession', () {
    test('opens a realtime channel on minigame_sessions updates (GMCR sync)',
        () {
      final channel = MockRealtimeChannel();
      when(() => realtime.subscribeToChannel(
            any(),
            any(),
            any(),
            any(),
            onStatus: any(named: 'onStatus'),
          )).thenReturn(channel);

      final result = service().subscribeToSession(_sessionId);

      expect(result, channel);
      verify(() => realtime.subscribeToChannel(
            'minigame-session:$_sessionId',
            PostgresChangeEvent.update,
            'minigame_sessions',
            any(),
            onStatus: any(named: 'onStatus'),
          )).called(1);
    });
  });
}
