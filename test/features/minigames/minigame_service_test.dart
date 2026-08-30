import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
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
          'p_invitees': <String>[],
          'p_name': null,
        });
      },
    );

    test('forwards the partida name as p_name (160_minigame_names)', () async {
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

      await service().createSession(
        _groupId,
        MinigameType.pokeChain,
        50,
        name: 'La revancha',
      );

      final params =
          verify(
                () => client.rpc(
                  'create_minigame_session',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params['p_name'], 'La revancha');
    });

    test(
      'forwards the selected invitee ids as p_invitees (140_minigame_invites)',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final rpc = ResolvingBuilder<dynamic>({
          'status': 'created',
          'sessionId': _sessionId,
          'invited': 2,
        });
        when(
          () => client.rpc(
            'create_minigame_session',
            params: any(named: 'params'),
          ),
        ).thenAnswer((_) => rpc);

        await service().createSession(
          _groupId,
          MinigameType.questions,
          0,
          inviteeIds: const [
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
          ],
        );

        final params =
            verify(
                  () => client.rpc(
                    'create_minigame_session',
                    params: captureAny(named: 'params'),
                  ),
                ).captured.single
                as Map<String, dynamic>;
        expect(params['p_invitees'], [
          'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        ]);
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

    test('maps the friends-only privacy rejection to a typed exception', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('create_minigame_session', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'invitee_friends_only'}),
      );

      expect(
        () => service().createSession(
          _groupId,
          MinigameType.pokeChain,
          0,
          inviteeIds: const ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'],
        ),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.inviteeFriendsOnly,
          ),
        ),
      );
    });

    test('propagates the invitee-not-allowed rejection', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('create_minigame_session', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'invitee_not_allowed'}),
      );

      expect(
        () => service().createSession(
          _groupId,
          MinigameType.pokeChain,
          0,
          inviteeIds: const ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'],
        ),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.inviteeNotAllowed,
          ),
        ),
      );
    });

    test('passes p_group_id as null for a DIRECT session (no group)',
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

      await service().createSession(null, MinigameType.questions, 0);

      final params =
          verify(
                () => client.rpc(
                  'create_minigame_session',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params['p_group_id'], isNull);
    });

    test('maps the player_limit_reached rejection (frozen player cap)',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'create_minigame_session',
          params: any(named: 'params'),
        ),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'player_limit_reached'}),
      );

      expect(
        () => service().createSession(null, MinigameType.questions, 0),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.playerLimitReached,
          ),
        ),
      );
    });
  });

  group('MinigameService.listMySessions (direct sessions)', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => table);
    });

    test('queries the caller\'s direct sessions (group_id is null + '
        'participant)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rows = ResolvingBuilder<PostgrestList>([_session()]);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final sessions = await service().listMySessions();

      expect(sessions, hasLength(1));
      expect(sessions.single['id'], _sessionId);
      // RecordedFilter equality is identity for list values, so the
      // participants containment filter is asserted via value matchers.
      expect(
        rows.filters,
        containsAllInOrder([
          const RecordedFilter('group_id', null),
          isA<RecordedFilter>()
              .having((f) => f.column, 'column', 'participants')
              .having((f) => f.value, 'value', [_userId]),
        ]),
      );
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().listMySessions(),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => table.select(any()));
    });
  });

  group('MinigameService.minigame invites (140_minigame_invites)', () {
    test('myInviteForSession reads the own invite row from minigame_invites',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('minigame_invites')).thenAnswer((_) => table);
      final rows = ResolvingBuilder<PostgrestList>({
        'id': 'invite-1',
        'session_id': _sessionId,
        'invitee_id': _userId,
        'created_by': '22222222-2222-2222-2222-222222222222',
        'status': 'pending',
        'created_at': '2026-08-26T10:00:00Z',
      });
      when(() => table.select(any())).thenAnswer((_) => rows);

      final invite = await service().myInviteForSession(_sessionId);

      expect(invite, isNotNull);
      expect(invite!['status'], 'pending');
      expect(
        rows.filters,
        containsAllInOrder([
          const RecordedFilter('session_id', _sessionId),
          const RecordedFilter('invitee_id', _userId),
        ]),
      );
    });

    test('acceptInvite invokes the accept_minigame_invite RPC', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('accept_minigame_invite', params: any(named: 'params')),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'accepted'}));

      await service().acceptInvite('invite-1');

      final params =
          verify(
                () => client.rpc(
                  'accept_minigame_invite',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_invite_id': 'invite-1'});
    });

    test('acceptInvite surfaces session_finished as a conflict', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('accept_minigame_invite', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'session_finished'}),
      );

      expect(
        () => service().acceptInvite('invite-1'),
        throwsA(isA<Exception>()),
      );
    });

    test('acceptInvite surfaces the player_limit_reached rejection', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('accept_minigame_invite', params: any(named: 'params')),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'player_limit_reached'}),
      );

      expect(
        () => service().acceptInvite('invite-1'),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.playerLimitReached,
          ),
        ),
      );
    });

    test('declineInvite declines the invite RPC', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () =>
            client.rpc('decline_minigame_invite', params: any(named: 'params')),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'declined'}));

      await service().declineInvite('invite-1');

      final params =
          verify(
                () => client.rpc(
                  'decline_minigame_invite',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_invite_id': 'invite-1'});
    });

    test('listMyPendingInvites reads pending invites then the session rows '
        '(170_minigame_invite_badges)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final invitesTable = MockQueryBuilder();
      when(() => client.from('minigame_invites')).thenAnswer((_) => invitesTable);
      final inviteRows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'invite-1',
          'session_id': _sessionId,
          'invitee_id': _userId,
          'created_by': '22222222-2222-2222-2222-222222222222',
          'status': 'pending',
          'created_at': '2026-08-26T10:00:00Z',
        },
      ]);
      when(() => invitesTable.select(any())).thenAnswer((_) => inviteRows);

      final sessionsTable = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => sessionsTable);
      when(
        () => sessionsTable.select(any()),
      ).thenAnswer((_) => ResolvingBuilder<PostgrestList>(_session()));

      final sessions = await service().listMyPendingInvites();

      expect(sessions, hasLength(1));
      expect(sessions.single['id'], _sessionId);
      expect(
        inviteRows.filters,
        containsAllInOrder([
          const RecordedFilter('invitee_id', _userId),
          const RecordedFilter('status', 'pending'),
        ]),
        reason: 'only the caller\'s PENDING invites are fetched (mi_read_own)',
      );
    });

    test('listMyPendingInvites skips sessions that are no longer visible '
        '(accepted/declined/finished)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final invitesTable = MockQueryBuilder();
      when(() => client.from('minigame_invites')).thenAnswer((_) => invitesTable);
      when(() => invitesTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'session_id': _sessionId},
          {'session_id': '99999999-9999-9999-9999-999999999999'},
        ]),
      );

      final sessionsTable = MockQueryBuilder();
      when(() => client.from('minigame_sessions')).thenAnswer((_) => sessionsTable);
      var sessionCalls = 0;
      when(() => sessionsTable.select(any())).thenAnswer((_) {
        sessionCalls++;
        // First lookup (the real _sessionId) resolves; the stale one does not
        // (accepted/declined/finished sessions drop out of the invitee read).
        return sessionCalls == 1
            ? ResolvingBuilder<PostgrestList>(_session())
            : ResolvingBuilder<PostgrestList>(null);
      });

      final sessions = await service().listMyPendingInvites();

      expect(sessions, hasLength(1));
      expect(sessions.single['id'], _sessionId);
      expect(sessionCalls, 2);
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

    test(
      'propagates the not_allowed rejection (bystander on a DIRECT session)',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        when(
          () =>
              client.rpc('join_minigame_session', params: any(named: 'params')),
        ).thenAnswer(
          (_) => ResolvingBuilder<dynamic>({'status': 'not_allowed'}),
        );

        expect(
          () => service().joinSession(_sessionId),
          throwsA(
            isA<MinigameSessionRejectedException>().having(
              (e) => e.rejection,
              'rejection',
              MinigameSessionRejection.notAllowed,
            ),
          ),
        );
      },
    );

    test(
      'propagates the player_limit_reached rejection for a full session',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        when(
          () =>
              client.rpc('join_minigame_session', params: any(named: 'params')),
        ).thenAnswer(
          (_) => ResolvingBuilder<dynamic>({'status': 'player_limit_reached'}),
        );

        expect(
          () => service().joinSession(_sessionId),
          throwsA(
            isA<MinigameSessionRejectedException>().having(
              (e) => e.rejection,
              'rejection',
              MinigameSessionRejection.playerLimitReached,
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

    test('propagates the not_allowed rejection (bystander settling a '
        'DIRECT session)', () async {
      when(
        () => client.rpc(
          'finish_minigame_session',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_allowed'}));

      expect(
        () => service().updateStatus(_sessionId, MinigameStatus.finished),
        throwsA(
          isA<MinigameSessionRejectedException>().having(
            (e) => e.rejection,
            'rejection',
            MinigameSessionRejection.notAllowed,
          ),
        ),
      );
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

  group('MinigameService game-state RPCs (150_minigame_play)', () {
    Map<String, dynamic> stateRow({String phase = 'playing'}) => {
      'session_id': _sessionId,
      'game_type': 'truth_dare',
      'state': {
        'judge_index': 0,
        'round': 0,
        'phase': phase,
        'subject_id': _userId,
        'prompt_type': null,
        'prompt': null,
      },
      'rounds': <dynamic>[],
      'created_at': '2026-08-28T10:00:00Z',
      'updated_at': '2026-08-28T10:00:00Z',
    };

    test('getMinigameGameState invokes the RPC and returns the state row',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'ok',
        'state': stateRow(),
      });
      when(
        () => client.rpc(
          'get_minigame_game_state',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => rpc);

      final state = await service().getMinigameGameState(_sessionId);

      expect(state, isNotNull);
      expect(state!['session_id'], _sessionId);
      final params =
          verify(
                () => client.rpc(
                  'get_minigame_game_state',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId});
    });

    test('getMinigameGameState returns null on not_started', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'get_minigame_game_state',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_started'}));

      expect(await service().getMinigameGameState(_sessionId), isNull);
    });

    test('getMinigameGameState maps the access denial', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'get_minigame_game_state',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_allowed'}));

      expect(
        () => service().getMinigameGameState(_sessionId),
        throwsA(isA<PermissionError>()),
      );
    });

    test('initMinigameGameState starts and returns the seeded row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'started',
        'state': stateRow(),
      });
      when(
        () => client.rpc(
          'init_minigame_game_state',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => rpc);

      final state = await service().initMinigameGameState(_sessionId);

      expect(state['session_id'], _sessionId);
      final params =
          verify(
                () => client.rpc(
                  'init_minigame_game_state',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId});
    });

    test('initMinigameGameState is idempotent on already_started', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'init_minigame_game_state',
          params: any(named: 'params'),
        ),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({
          'status': 'already_started',
          'state': stateRow(),
        }),
      );

      final state = await service().initMinigameGameState(_sessionId);
      expect(state['session_id'], _sessionId);
    });

    test('revealMinigamePrompt draws a random prompt of the kind', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'revealed',
        'prompt_type': 'verdad',
        'prompt': {'id': 'p-1', 'body': '¿Cuál fue tu primer beso?'},
        'state': stateRow(),
      });
      when(
        () => client.rpc(
          'reveal_minigame_prompt',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => rpc);

      final state = await service().revealMinigamePrompt(_sessionId, 'verdad');

      expect(state['session_id'], _sessionId);
      final params =
          verify(
                () => client.rpc(
                  'reveal_minigame_prompt',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId, 'p_prompt_type': 'verdad'});
    });

    test('revealMinigamePrompt surfaces invalid_prompt_type', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'reveal_minigame_prompt',
          params: any(named: 'params'),
        ),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({'status': 'invalid_prompt_type'}),
      );

      expect(
        () => service().revealMinigamePrompt(_sessionId, 'bogus'),
        throwsA(isA<ValidationError>()),
      );
    });

    test('advanceMinigameTurn passes the completed round jsonb', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'advanced',
        'state': stateRow(),
      });
      when(
        () => client.rpc(
          'advance_minigame_turn',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => rpc);

      final round = {
        'subject_id': _userId,
        'prompt_type': 'verdad',
        'outcome': 'done',
      };
      final state = await service().advanceMinigameTurn(_sessionId, round);

      expect(state['session_id'], _sessionId);
      final params =
          verify(
                () => client.rpc(
                  'advance_minigame_turn',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId, 'p_round': round});
    });

    test('completeMinigameGame settles and is idempotent', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'complete_minigame_game',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'finished'}));

      await service().completeMinigameGame(_sessionId);

      final params =
          verify(
                () => client.rpc(
                  'complete_minigame_game',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId});

      when(
        () => client.rpc(
          'complete_minigame_game',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'already_finished'}));
      await service().completeMinigameGame(_sessionId);
    });

    test('subscribeToGameState opens the game-state realtime channel', () {
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

      final result = service().subscribeToGameState(_sessionId);

      expect(result, channel);
      verify(
        () => realtime.subscribeToChannel(
          'minigame-game-state:$_sessionId',
          PostgresChangeEvent.update,
          'minigame_game_state',
          any(),
          onStatus: any(named: 'onStatus'),
        ),
      ).called(1);
    });
  });

  group('MinigameService partida lobby (180_minigame_lobby)', () {
    test('setReady invokes set_minigame_ready with the flag and returns on '
        'ready', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'set_minigame_ready',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'ready'}));

      await service().setReady(_sessionId, true);

      final params =
          verify(
                () => client.rpc(
                  'set_minigame_ready',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId, 'p_ready': true});
    });

    test('setReady surfaces typed rejections (not_allowed / '
        'session_not_active)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());

      when(
        () => client.rpc(
          'set_minigame_ready',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_allowed'}));
      await expectLater(
        service().setReady(_sessionId, true),
        throwsA(isA<PermissionError>()),
      );

      when(
        () => client.rpc(
          'set_minigame_ready',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) =>
          ResolvingBuilder<dynamic>({'status': 'session_not_active'}));
      await expectLater(
        service().setReady(_sessionId, true),
        throwsA(
          isA<ConflictError>().having((e) => e.code, 'code', 'session_not_active'),
        ),
      );
    });

    test('getMinigameParticipants returns the roster from the RPC payload',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'get_minigame_participants',
          params: any(named: 'params'),
        ),
      ).thenAnswer(
        (_) => ResolvingBuilder<dynamic>({
          'status': 'ok',
          'participants': [
            {'id': _userId, 'username': 'yo', 'avatar_url': null},
            {'id': _groupId, 'username': 'otro', 'avatar_url': 'a.png'},
          ],
        }),
      );

      final roster = await service().getMinigameParticipants(_sessionId);

      expect(roster, hasLength(2));
      expect(roster.first['username'], 'yo');
      final params =
          verify(
                () => client.rpc(
                  'get_minigame_participants',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {'p_session_id': _sessionId});
    });

    test('getMinigameParticipants throws not_allowed for a bystander',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'get_minigame_participants',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_allowed'}));
      await expectLater(
        service().getMinigameParticipants(_sessionId),
        throwsA(isA<PermissionError>()),
      );
    });

    test('removeParticipant invokes the RPC with the session + target',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'remove_minigame_participant',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'removed'}));

      await service().removeParticipant(_sessionId, _groupId);

      final params =
          verify(
                () => client.rpc(
                  'remove_minigame_participant',
                  params: captureAny(named: 'params'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(params, {
        'p_session_id': _sessionId,
        'p_user_id': _groupId,
      });
    });

    test('removeParticipant surfaces not_creator (backend-enforced host '
        'gate)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc(
          'remove_minigame_participant',
          params: any(named: 'params'),
        ),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>({'status': 'not_creator'}));
      await expectLater(
        service().removeParticipant(_sessionId, _groupId),
        throwsA(isA<PermissionError>()),
      );
    });
  });
}
