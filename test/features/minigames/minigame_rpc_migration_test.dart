import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static verification of the minigame server-side contract (I-63, GMCR/GWAG
/// foundation):
///
/// 1. The `create_minigame_session`, `join_minigame_session` and
///    `finish_minigame_session` RPCs live in BOTH stacks
///    (`supabase/migrations/100_minigames/sessions.sql` + the
///    `supabase-testing/` mirror, per the I-02 parity convention) with the
///    required hardening: SECURITY DEFINER, `SET search_path = ''`,
///    group-membership gate via the I-32 `is_group_member` helper, atomic
///    wager deduction + `shard_ledger` (`minigame_wager`) + session insert,
///    PUBLIC EXECUTE revoked, authenticated-only EXECUTE grant.
/// 2. The pgTAP suites (`schema_test.sql` in both stacks) stay
///    self-consistent: `plan(N)` equals the actual number of assertion
///    statements in the file, and both files carry the Sections that assert
///    the RPCs (Section 45 + Section 49).
void main() {
  final root = Directory.current.path;

  String read(String path) => File('$root/$path').readAsStringSync();

  /// The pg_dump baseline puts every RPC of a domain in one file; this
  /// slices one `CREATE FUNCTION public.<name>` body (up to the next
  /// function or EOF) so per-RPC negative assertions stay scoped.
  String functionSlice(String content, String functionName) {
    final start = content.indexOf('CREATE FUNCTION public.$functionName');
    expect(start, isNot(-1), reason: '$functionName must exist');
    final next = content.indexOf(
      'CREATE FUNCTION public.',
      start + 'CREATE FUNCTION public.'.length,
    );
    return content.substring(start, next == -1 ? content.length : next);
  }

  final supabaseMigration = read(
    'supabase/migrations/100_minigames/sessions.sql',
  );
  final testingMigration = read(
    'supabase-testing/migrations/100_minigames/sessions.sql',
  );
  final supabaseInvitesMigration = read(
    'supabase/migrations/140_minigame_invites/invites.sql',
  );
  final testingInvitesMigration = read(
    'supabase-testing/migrations/140_minigame_invites/invites.sql',
  );
  final supabaseJoinFinishMigration = supabaseMigration;
  final testingJoinFinishMigration = testingMigration;
  // The invite-aware create_minigame_session gained p_invitees in 140 (the
  // 3-arg baseline in 100 is DROP'd there) and then p_name in 160 (the 4-arg
  // is DROP'd in 160 — CREATE OR REPLACE cannot change the argument list),
  // so the current create-contract checks run against the names migration.
  final supabaseNamesMigration = read(
    'supabase/migrations/160_minigame_names/names.sql',
  );
  final testingNamesMigration = read(
    'supabase-testing/migrations/160_minigame_names/names.sql',
  );
  final supabaseCreateMigration = supabaseNamesMigration;
  // The invite-badge migration (170_minigame_invite_badges) redefines
  // create_minigame_session via CREATE OR REPLACE (same 5-arg signature as
  // 160) to compute + store the server-side auto_name, and redefines
  // notify_minigame_invite to fire for BOTH scopes with gameType/sessionName.
  final supabaseBadgesMigration = read(
    'supabase/migrations/170_minigame_invite_badges/invite_badges.sql',
  );
  final testingBadgesMigration = read(
    'supabase-testing/migrations/170_minigame_invite_badges/invite_badges.sql',
  );
  final supabaseSchema = read('supabase/tests/schema_test.sql');
  final testingSchema = read('supabase-testing/tests/schema_test.sql');

  group('create_minigame_session RPC migration (100_minigames + 140_minigame_invites + 160_minigame_names)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(
        supabaseMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/100_minigames/sessions.sql '
            'is missing or empty',
      );
      expect(
        testingMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/100_minigames/sessions.sql '
            'is missing or empty',
      );
      expect(
        supabaseInvitesMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/140_minigame_invites/invites.sql '
            'is missing or empty',
      );
      expect(
        testingInvitesMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/140_minigame_invites/invites.sql '
            'is missing or empty',
      );
      expect(
        supabaseNamesMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/160_minigame_names/names.sql '
            'is missing or empty',
      );
      expect(
        testingNamesMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/160_minigame_names/names.sql '
            'is missing or empty',
      );
    });

    test('supabase-testing mirrors match the canonical migrations', () {
      expect(
        testingMigration,
        supabaseMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention)',
      );
      expect(
        testingInvitesMigration,
        supabaseInvitesMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention, 140_minigame_invites)',
      );
      expect(
        testingNamesMigration,
        supabaseNamesMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention, 160_minigame_names)',
      );
    });

    test('is SECURITY DEFINER with SET search_path TO \'\' (I-31 pattern)', () {
      expect(supabaseCreateMigration, contains('SECURITY DEFINER'));
      expect(supabaseCreateMigration, contains("SET search_path TO ''"));
      expect(
        supabaseCreateMigration,
        contains('public.create_minigame_session'),
        reason: 'function must be created with a fully-qualified name',
      );
    });

    test(
      'validates group membership via the is_group_member helper (I-32)',
      () {
        expect(
          supabaseCreateMigration,
          contains('public.is_group_member(p_group_id)'),
          reason:
              'the membership gate must delegate to the SECURITY DEFINER '
              'is_group_member helper (recursion-safe, active members only)',
        );
        expect(
          supabaseCreateMigration,
          contains("'not_member'"),
          reason:
              'non-members must get the typed not_member outcome (returned '
              'as jsonb per the I-57 status contract, never RAISE\'d)',
        );
      },
    );

    test('rejects negative wagers and validates the game type', () {
      expect(
        supabaseCreateMigration,
        contains('p_wager < 0'),
        reason: 'negative wagers must be rejected (GWAG: integer shards >= 0)',
      );
      expect(
        supabaseCreateMigration,
        contains('::public.mini_game_type'),
        reason:
            'p_game_type must be validated by a cast to the DB enum '
            '(invalid values raise invalid_text_representation, mapped to '
            'the invalid_game_type outcome)',
      );
    });

    test('deducts personal_shards atomically when the wager is > 0', () {
      expect(
        supabaseCreateMigration,
        contains('SET personal_shards = personal_shards - p_wager'),
        reason: 'the wager must be deducted from the caller\'s balance',
      );
      expect(
        supabaseCreateMigration,
        contains('personal_shards >= p_wager'),
        reason:
            'the UPDATE must be guarded so insufficient balances are '
            'never overdrawn',
      );
      expect(
        supabaseCreateMigration,
        contains("'insufficient_shards'"),
        reason: 'the insufficient-balance outcome must be a typed status',
      );
    });

    test(
      'writes the minigame_wager ledger entry with the session reference',
      () {
        expect(
          supabaseCreateMigration,
          contains('INSERT INTO public.shard_ledger'),
          reason:
              'the ledger insert must be fully qualified (search_path='
              ')',
        );
        expect(
          supabaseCreateMigration,
          contains("'minigame_wager'"),
          reason:
              'the wager deduction must be recorded as reason=minigame_wager '
              '(GWAG ledger contract)',
        );
        expect(
          supabaseCreateMigration,
          contains('reference_id'),
          reason:
              'the ledger row must carry reference_id for escrow '
              'verifiability (sum of minigame_wager entries per session)',
        );
      },
    );

    test('inserts the session with the caller as first participant and '
        'returns the id', () {
      expect(
        supabaseCreateMigration,
        contains('INSERT INTO public.minigame_sessions'),
        reason:
            'the session insert must be fully qualified (search_path='
            ')',
      );
      expect(
        supabaseCreateMigration,
        contains("'active'"),
        reason: 'new sessions start with status=active (GMCR step 4)',
      );
      expect(
        supabaseCreateMigration,
        contains('RETURNING id'),
        reason: 'the RPC must capture the created session id',
      );
      expect(
        supabaseCreateMigration,
        contains("'created'"),
        reason: 'the success outcome must be the created status',
      );
      expect(
        supabaseCreateMigration,
        contains("'sessionId'"),
        reason:
            'the created status must carry the session id (client '
            'contract: MinigameService.createSession)',
      );
      expect(
        supabaseCreateMigration,
        contains('ARRAY[v_current_user]'),
        reason:
            'the initiator must be the first participant (GMCR session '
            'creation, participant select is future work)',
      );
    });

    test(
      'returns every business outcome as a jsonb status (I-57 contract)',
      () {
        for (final status in const [
          "'not_authenticated'",
          "'not_member'",
          "'invalid_wager'",
          "'invalid_game_type'",
          "'insufficient_shards'",
          "'created'",
        ]) {
          expect(
            supabaseCreateMigration,
            contains(status),
            reason: 'status $status must be returned by the RPC',
          );
        }
      },
    );

    test('revokes PUBLIC EXECUTE and grants authenticated only', () {
      expect(
        supabaseCreateMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.create_minigame_session'
          '(p_group_id uuid, p_game_type text, p_wager integer,'
              ' p_invitees uuid[], p_name text) FROM PUBLIC',
        ),
      );
      expect(
        supabaseCreateMigration,
        contains(
          'GRANT ALL ON FUNCTION public.create_minigame_session'
          '(p_group_id uuid, p_game_type text, p_wager integer,'
              ' p_invitees uuid[], p_name text) TO authenticated',
        ),
      );
      expect(
        supabaseCreateMigration,
        isNot(contains(
          'FUNCTION public.create_minigame_session'
          '(p_group_id uuid, p_game_type text, p_wager integer) TO anon',
        )),
        reason: 'anon must never create minigame sessions',
      );
    });

    test('keeps the winner-settlement RPC out of create_minigame_session '
        '(documented gap)', () {
      // The create RPC implements only the create-side escrow (deduct +
      // minigame_wager ledger + session). Winner settlement (minigame_win
      // ledger + escrow credit) and draw refunds (minigame_refund) live in
      // finish_minigame_session — assert the create function's own body
      // slice stays credit-free.
      final createBody = functionSlice(
        supabaseCreateMigration,
        'create_minigame_session',
      );
      expect(
        createBody,
        isNot(contains('personal_shards = personal_shards +')),
        reason: 'no escrow-credit path (minigame_win) may exist in scope',
      );
      expect(
        createBody,
        isNot(contains('winner_id')),
        reason: 'no winner-resolution write may exist in scope',
      );
    });
  });

  group('join/finish minigame session RPC migration (100_minigames)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(
        supabaseJoinFinishMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/100_minigames/sessions.sql '
            'is missing or empty',
      );
      expect(
        testingJoinFinishMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/100_minigames/sessions.sql '
            'is missing or empty',
      );
    });

    test('supabase-testing mirror matches the canonical migration', () {
      expect(
        testingJoinFinishMigration,
        supabaseJoinFinishMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention)',
      );
    });

    test('both RPCs are SECURITY DEFINER with SET search_path TO \'\' '
        '(I-31 pattern)', () {
      for (final fn in const [
        'join_minigame_session',
        'finish_minigame_session',
      ]) {
        expect(
          supabaseJoinFinishMigration,
          contains('public.$fn'),
          reason: '$fn must be created with a fully-qualified name',
        );
      }
      expect(supabaseJoinFinishMigration, contains('SECURITY DEFINER'));
      expect(
        supabaseJoinFinishMigration,
        contains("SET search_path TO ''"),
      );
    });

    test('join_minigame_session gates on the session + is_group_member', () {
      expect(
        supabaseJoinFinishMigration,
        contains('public.is_group_member(v_group_id)'),
        reason:
            'the membership gate must delegate to the SECURITY DEFINER '
            'is_group_member helper (recursion-safe, active members only)',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'session_not_found'"),
        reason:
            'a missing session must get the typed session_not_found '
            'outcome (returned as jsonb per the I-57 status contract)',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'joined'"),
        reason: 'a successful join must return the joined status',
      );
    });

    test('join_minigame_session is idempotent and serialized', () {
      expect(
        supabaseJoinFinishMigration,
        contains('FOR UPDATE'),
        reason:
            'the session row must be locked to serialize concurrent '
            'joins (no lost participants-array updates)',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('= ANY(v_participants)'),
        reason: 'repeat joins by an existing participant must be a no-op',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('participants || ARRAY[v_current_user]'),
        reason: 'the join must append the caller to the participants array',
      );
    });

    test('join_minigame_session mirrors create_minigame_session escrow', () {
      expect(
        supabaseJoinFinishMigration,
        contains('SET personal_shards = personal_shards - v_wager'),
        reason: 'joining a wagered session must deduct the caller\'s balance',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('personal_shards >= v_wager'),
        reason:
            'the UPDATE must be guarded so insufficient balances are '
            'never overdrawn',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'minigame_wager'"),
        reason:
            'the join deduction must be recorded as reason=minigame_wager '
            'with reference_id (GWAG escrow verifiability)',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'insufficient_shards'"),
        reason: 'the insufficient-balance outcome must be a typed status',
      );
    });

    test('finish_minigame_session settles the escrow (win + draw paths)', () {
      expect(
        supabaseJoinFinishMigration,
        contains("'minigame_win'"),
        reason:
            'the winner path must write reason=minigame_win (GWAG '
            'Wager Resolution)',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'minigame_refund'"),
        reason:
            'the draw path must write reason=minigame_refund per '
            'participant',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('personal_shards = personal_shards + v_escrow'),
        reason: 'the winner must receive the full escrow pot',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('personal_shards = personal_shards + v_wager'),
        reason: 'draw refunds must restore each participant\'s wager',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'invalid_winner'"),
        reason: 'a winner outside the participants list must be rejected',
      );
    });

    test('finish_minigame_session flips the session to finished', () {
      expect(
        supabaseJoinFinishMigration,
        contains("status = 'finished'"),
        reason: 'the RPC must set the session status to finished',
      );
      expect(
        supabaseJoinFinishMigration,
        contains('winner_id = p_winner_id'),
        reason: 'the winner must be recorded on the session row',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'already_finished'"),
        reason: 'repeat finishes must be idempotent (escrow paid once)',
      );
    });

    test('revokes PUBLIC EXECUTE and grants authenticated only', () {
      expect(
        supabaseJoinFinishMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.join_minigame_session'
          '(p_session_id uuid) FROM PUBLIC',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'GRANT ALL ON FUNCTION public.join_minigame_session'
          '(p_session_id uuid) TO authenticated',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.finish_minigame_session'
          '(p_session_id uuid, p_winner_id uuid, p_place integer) FROM PUBLIC',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'GRANT ALL ON FUNCTION public.finish_minigame_session'
          '(p_session_id uuid, p_winner_id uuid, p_place integer)'
          ' TO authenticated',
        ),
      );
      for (final fn in const [
        'join_minigame_session(p_session_id uuid)',
        'finish_minigame_session(p_session_id uuid, p_winner_id uuid,'
            ' p_place integer)',
      ]) {
        expect(
          supabaseJoinFinishMigration,
          isNot(contains('FUNCTION public.$fn TO anon')),
          reason: 'anon must never join or finish minigame sessions ($fn)',
        );
      }
    });

    test('records no result row (no minigame_results table in the schema)', () {
      // The RPC accepts p_place for the future result-row contract but the
      // schema has no results table to write — assert the reserved-parameter
      // posture.
      expect(
        supabaseJoinFinishMigration,
        contains('p_place'),
        reason:
            'p_place must be part of the signature (future result-row '
            'contract)',
      );
    });
  });

  group('minigame invites migration (140_minigame_invites)', () {
    test('exists and is mirrored byte-identical', () {
      expect(
        supabaseInvitesMigration,
        testingInvitesMigration,
        reason: '140_minigame_invites must mirror across stacks (I-02)',
      );
    });

    test('drops the 3-arg create overload before creating the 4-arg', () {
      expect(
        supabaseInvitesMigration,
        contains(
          'DROP FUNCTION public.create_minigame_session'
          '(p_group_id uuid, p_game_type text, p_wager integer)',
        ),
        reason:
            'CREATE OR REPLACE cannot change the argument list — the 3-arg '
            'baseline must be dropped first',
      );
      expect(
        supabaseInvitesMigration,
        contains('p_invitees uuid[]'),
        reason: 'the invite-aware overload must carry p_invitees uuid[]',
      );
    });

    test('defines the invites table with FORCE RLS and invitee/creator read',
        () {
      expect(supabaseInvitesMigration, contains('public.minigame_invites'));
      expect(
        supabaseInvitesMigration,
        contains('mini_game_invite_status'),
        reason: 'the pending/accepted/declined status enum must exist',
      );
      expect(
        supabaseInvitesMigration,
        contains('FORCE ROW LEVEL SECURITY'),
        reason: 'invites are a server-side contract — no client table writes',
      );
      expect(
        supabaseInvitesMigration,
        contains('mi_read_own'),
        reason: 'invitee/creator SELECT policy must exist',
      );
    });

    test('adds the friends-only privacy column defaulting to false', () {
      expect(
        supabaseInvitesMigration,
        contains('minigame_invite_friends_only boolean NOT NULL DEFAULT false'),
        reason: 'default OFF = non-friends may invite (user directive)',
      );
    });

    test('ships the accept/decline + privacy RPC family with hardening', () {
      for (final fn in const [
        'set_minigame_invite_friends_only',
        'accept_minigame_invite',
        'decline_minigame_invite',
      ]) {
        expect(
          supabaseInvitesMigration,
          contains('CREATE FUNCTION public.$fn'),
          reason: '$fn must exist as a public function',
        );
        expect(
          supabaseInvitesMigration,
          contains('SECURITY DEFINER'),
          reason: '$fn must be SECURITY DEFINER',
        );
        expect(
          supabaseInvitesMigration,
          contains("SET search_path TO ''"),
          reason: '$fn must harden search_path (I-31 pattern)',
        );
        expect(
          supabaseInvitesMigration,
          contains('REVOKE ALL ON FUNCTION public.$fn'),
          reason: '$fn must not be PUBLIC-executable',
        );
        expect(
          supabaseInvitesMigration,
          contains('GRANT ALL ON FUNCTION public.$fn'),
          reason: '$fn must grant the caller role',
        );
      }
    });

    test('accept_minigame_invite enforces the finished-session closure', () {
      expect(
        supabaseInvitesMigration,
        contains("'session_finished'"),
        reason:
            'accepting after the game finished must be rejected (product '
            'contract)',
      );
    });

    test('opens ms_read_invitee on minigame_sessions (non-member reads)', () {
      expect(
        supabaseInvitesMigration,
        contains('ms_read_invitee'),
        reason: 'invitees need the narrowest SELECT to render the session',
      );
    });

    test('joins notifications + minigame_invites to supabase_realtime', () {
      expect(
        supabaseInvitesMigration,
        contains('ADD TABLE public.notifications'),
        reason: 'GO-realtime: invites must land live in the notification center',
      );
      expect(
        supabaseInvitesMigration,
        contains('ADD TABLE public.minigame_invites'),
        reason: 'accept/decline streaming needs the invites table published',
      );
    });

    test('moves the invite trigger from minigame_sessions to minigame_invites',
        () {
      expect(
        supabaseInvitesMigration,
        contains(
          'DROP TRIGGER IF EXISTS notify_minigame_invite_trigger '
          'ON public.minigame_sessions',
        ),
        reason: 'the creator-as-participant notification is retired',
      );
      expect(
        supabaseInvitesMigration,
        contains(
          'CREATE TRIGGER notify_minigame_invite_trigger '
          'AFTER INSERT ON public.minigame_invites',
        ),
        reason: 'the invitee must be notified on minigame_invites INSERT',
      );
      expect(
        supabaseInvitesMigration,
        contains("'minigame_invite'"),
        reason: 'the notification type must stay minigame_invite',
      );
    });
  });

  group('minigame partida names (160_minigame_names)', () {
    test('adds the nullable name column to minigame_sessions', () {
      expect(
        supabaseNamesMigration,
        contains('ALTER TABLE public.minigame_sessions'),
        reason: '160 must alter the sessions table',
      );
      expect(
        supabaseNamesMigration,
        contains('ADD COLUMN name text'),
        reason: 'the optional partida title must be a plain text column',
      );
    });

    test('drops the 4-arg create overload before creating the 5-arg', () {
      expect(
        supabaseNamesMigration,
        contains(
          'DROP FUNCTION public.create_minigame_session'
          '(p_group_id uuid, p_game_type text, p_wager integer,'
          ' p_invitees uuid[])',
        ),
        reason:
            'CREATE OR REPLACE cannot change the argument list — the 4-arg '
            'overload must be dropped first',
      );
      expect(
        supabaseNamesMigration,
        contains('p_name text DEFAULT NULL'),
        reason: 'the name-aware overload must carry the optional p_name',
      );
    });

    test('stores p_name on the session row (auto partida-XX stays client-side)',
        () {
      expect(
        supabaseNamesMigration,
        contains('INSERT INTO public.minigame_sessions'),
        reason: 'the session insert must be fully qualified',
      );
      expect(
        supabaseNamesMigration,
        contains('participants, name'),
        reason: 'the insert column list must include the new name column',
      );
      expect(
        supabaseNamesMigration,
        contains('ARRAY[v_current_user], v_name'),
        reason: 'the initiator participant + trimmed partida name must be inserted',
      );
    });

    test('keeps the escrow + invite body intact across the signature change', () {
      for (final needle in const [
        'SET personal_shards = personal_shards - p_wager',
        "'insufficient_shards'",
        "'minigame_wager'",
        'INSERT INTO public.shard_ledger',
        'public.is_group_member(p_group_id)',
        'RETURNING id',
      ]) {
        expect(
          supabaseNamesMigration,
          contains(needle),
          reason: 'the 5-arg create must retain the $needle contract',
        );
      }
    });

    test('pgTAP pins the 160_minigame_names contract in both stacks', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49d'),
          reason: '$name must carry the partida-names section header',
        );
        expect(
          content,
          contains("has_column('minigame_sessions', 'name'"),
          reason: '$name must assert the nullable name column',
        );
        expect(
          content,
          contains(
            "has_function('create_minigame_session', "
            "ARRAY['uuid', 'text', 'integer', 'uuid[]', 'text']",
          ),
          reason: '$name must assert the 5-arg p_name RPC signature',
        );
        expect(
          content,
          contains("'minigame_sessions.name is NULLABLE"),
          reason: '$name must assert the nullable auto-name fallback',
        );
      }
    });
  });

  group('minigame invite badges (170_minigame_invite_badges)', () {
    test('exists in both stacks and is mirrored byte-identical', () {
      expect(
        supabaseBadgesMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/170_minigame_invite_badges/invite_badges.sql '
            'is missing or empty',
      );
      expect(
        testingBadgesMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/170_minigame_invite_badges/'
            'invite_badges.sql is missing or empty',
      );
      expect(
        testingBadgesMigration,
        supabaseBadgesMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention, 170_minigame_invite_badges)',
      );
    });

    test('adds the nullable auto_name column to minigame_sessions', () {
      expect(
        supabaseBadgesMigration,
        contains('ALTER TABLE public.minigame_sessions'),
        reason: '170 must alter the sessions table',
      );
      expect(
        supabaseBadgesMigration,
        contains('ADD COLUMN auto_name text'),
        reason:
            'the server-computed partida-N must be a plain text column',
      );
    });

    test('redefines create_minigame_session via CREATE OR REPLACE (same '
        '5-arg signature) and stores auto_name', () {
      expect(
        supabaseBadgesMigration,
        contains('CREATE OR REPLACE FUNCTION public.create_minigame_session'),
        reason:
            'CREATE OR REPLACE is legal because the 160 signature is unchanged',
      );
      expect(
        supabaseBadgesMigration,
        contains('p_name text DEFAULT NULL'),
        reason: 'the 5-arg p_name signature must be preserved',
      );
      expect(
        supabaseBadgesMigration,
        contains('v_auto_name text'),
        reason: 'the function must declare the auto-name variable',
      );
      expect(
        supabaseBadgesMigration,
        contains('WHERE game_type = v_game_type AND status = \'active\''),
        reason:
            'auto_name is the running partida-N per game_type among ACTIVE '
            'sessions',
      );
      expect(
        supabaseBadgesMigration,
        contains('participants, name, auto_name'),
        reason: 'the insert column list must include the new auto_name column',
      );
    });

    test('notify_minigame_invite fires for BOTH scopes and carries '
        'gameType + sessionName', () {
      expect(
        supabaseBadgesMigration,
        contains('CREATE OR REPLACE FUNCTION public.notify_minigame_invite()'),
        reason: '170 must redefine the invite notify function',
      );
      expect(
        supabaseBadgesMigration,
        isNot(contains('v_group_id IS NULL THEN')),
        reason:
            'the direct-session early-return must be gone — direct invites '
            'must also notify',
      );
      expect(
        supabaseBadgesMigration,
        contains("'gameType'"),
        reason: 'the payload must carry the game type for per-game badges',
      );
      expect(
        supabaseBadgesMigration,
        contains("'sessionName'"),
        reason:
            'the payload must carry the partida display name so the invitee '
            'can render "partida-N" without a round-trip',
      );
    });

    test('pgTAP pins the 170_minigame_invite_badges contract in both stacks',
        () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49f'),
          reason: '$name must carry the invite-badges section header',
        );
        expect(
          content,
          contains("has_column('minigame_sessions', 'auto_name'"),
          reason: '$name must assert the auto_name column',
        );
        expect(
          content,
          contains('gameType'),
          reason: '$name must assert the notify payload carries gameType',
        );
      }
    });
  });

  group('minigame play engine (150_minigame_play)', () {
    final supabasePlayMigration = read(
      'supabase/migrations/150_minigame_play/play.sql',
    );
    final testingPlayMigration = read(
      'supabase-testing/migrations/150_minigame_play/play.sql',
    );

    test('exists in both stacks and is mirrored byte-identical', () {
      expect(
        supabasePlayMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/150_minigame_play/play.sql is missing or empty',
      );
      expect(
        testingPlayMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/150_minigame_play/play.sql '
            'is missing or empty',
      );
      expect(
        testingPlayMigration,
        supabasePlayMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention, 150_minigame_play)',
      );
    });

    test('defines minigame_game_state with FORCE RLS and the participant '
        'SELECT policy', () {
      expect(
        supabasePlayMigration,
        contains('public.minigame_game_state'),
        reason: 'the game-state table must exist',
      );
      expect(
        supabasePlayMigration,
        contains('session_id uuid NOT NULL'),
        reason: 'session_id is the PK column (one game-state row per session)',
      );
      expect(
        supabasePlayMigration,
        contains(
          'minigame_game_state_pkey PRIMARY KEY (session_id)',
        ),
        reason: 'session_id must be the primary key',
      );
      expect(
        supabasePlayMigration,
        contains('REFERENCES public.minigame_sessions(id) ON DELETE CASCADE'),
        reason: 'session_id must cascade from minigame_sessions (FK)',
      );
      expect(
        supabasePlayMigration,
        contains('FORCE ROW LEVEL SECURITY'),
        reason: 'no client table writes — every mutation is an RPC contract',
      );
      expect(
        supabasePlayMigration,
        contains('mgs_read_participant'),
        reason: 'the single participant/invitee/group-member SELECT policy',
      );
      expect(
        supabasePlayMigration,
        contains("'judge_index'"),
        reason: 'the state payload carries the generic judge_index rotation',
      );
    });

    test('defines minigame_prompts with FORCE RLS and active-prompt reads', () {
      expect(
        supabasePlayMigration,
        contains('public.minigame_prompts'),
        reason: 'the prompt bank table must exist',
      );
      expect(
        supabasePlayMigration,
        contains('prompt_type text NOT NULL'),
        reason: 'prompt_type (verdad/reto, quick/challenge, ...) must exist',
      );
      expect(
        supabasePlayMigration,
        contains('mgs_prompts_select'),
        reason: 'the active-prompt SELECT policy must exist',
      );
      expect(
        supabasePlayMigration,
        contains('is_active = true'),
        reason: 'mgs_prompts_select must gate on is_active = true',
      );
    });

    test('seeds the es-first Verdad o Reto prompt bank idempotently', () {
      for (final body in const [
        '¿Cuál fue tu primer beso?',
        '¿Quién fue tu primer amor?',
        'Di la inicial de quien te gusta',
        'Envía una foto de tu perro',
        'Hazte una selfie con un objeto',
        'Haz un challenge',
      ]) {
        expect(
          supabasePlayMigration,
          contains(body),
          reason: 'the seed must include the prompt: $body',
        );
      }
      expect(
        supabasePlayMigration,
        contains('ON CONFLICT (id) DO NOTHING'),
        reason: 'seeds must be idempotent (deterministic ids, ON CONFLICT)',
      );
    });

    test('ships the five play-engine RPCs with SECURITY DEFINER + '
        'SET search_path TO \'\' + ACL revocation', () {
      for (final fn in const [
        'get_minigame_game_state',
        'init_minigame_game_state',
        'reveal_minigame_prompt',
        'advance_minigame_turn',
        'complete_minigame_game',
      ]) {
        expect(
          supabasePlayMigration,
          contains('CREATE FUNCTION public.$fn'),
          reason: '$fn must exist as a public function',
        );
        expect(
          supabasePlayMigration,
          contains('SECURITY DEFINER'),
          reason: '$fn must be SECURITY DEFINER',
        );
        expect(
          supabasePlayMigration,
          contains("SET search_path TO ''"),
          reason: '$fn must harden search_path (I-31 pattern)',
        );
        expect(
          supabasePlayMigration,
          contains('REVOKE ALL ON FUNCTION public.$fn'),
          reason: '$fn must not be PUBLIC-executable',
        );
        expect(
          supabasePlayMigration,
          contains('GRANT ALL ON FUNCTION public.$fn'),
          reason: '$fn must grant the caller role',
        );
      }
    });

    test('implements the server-random subject contract (players do NOT '
        'self-select)', () {
      expect(
        supabasePlayMigration,
        contains('random()'),
        reason:
            'the subject pick must be server-random (init picks the first '
            'subject, advance picks the next subject)',
      );
      expect(
        supabasePlayMigration,
        contains('ORDER BY random()'),
        reason: 'reveal_minigame_prompt draws a random active prompt',
      );
      expect(
        supabasePlayMigration,
        contains('subject_id'),
        reason: 'the current subject is carried in the state payload',
      );
    });

    test('complete_minigame_game settles the wager like finish_minigame_session '
        'NULL-winner (draw refund)', () {
      expect(
        supabasePlayMigration,
        contains("'minigame_refund'"),
        reason:
            'the draw path must write reason=minigame_refund per participant',
      );
      expect(
        supabasePlayMigration,
        contains('public.shard_ledger'),
        reason: 'settlement must write the shard_ledger',
      );
      expect(
        supabasePlayMigration,
        contains('status = \'finished\''),
        reason: 'the session status must flip to finished',
      );
    });

    test('joins minigame_game_state to supabase_realtime', () {
      expect(
        supabasePlayMigration,
        contains('ADD TABLE public.minigame_game_state'),
        reason: 'game-state changes must stream live to participants',
      );
    });

    test('pgTAP pins the 150_minigame_play contract in both stacks', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49c'),
          reason: '$name must carry the game-state section header',
        );
        expect(
          content,
          contains("has_table('minigame_game_state'"),
          reason: '$name must assert the game-state table exists',
        );
        expect(
          content,
          contains("has_table('minigame_prompts'"),
          reason: '$name must assert the prompts bank exists',
        );
        expect(
          content,
          contains(
            "'minigame_game_state has FORCE ROW LEVEL SECURITY",
          ),
          reason: '$name must assert the FORCE RLS posture',
        );
        expect(
          content,
          contains("has_function('reveal_minigame_prompt', ARRAY['uuid', 'text']"),
          reason: '$name must assert the reveal RPC signature',
        );
        expect(
          content,
          contains("has_function('advance_minigame_turn', ARRAY['uuid', 'jsonb']"),
          reason: '$name must assert the advance RPC signature',
        );
        expect(
          content,
          contains(
            "'minigame_game_state joins the supabase_realtime publication",
          ),
          reason: '$name must assert the realtime membership',
        );
      }
    });
  });

  group('direct sessions (2026-08-27 direct-minigames)', () {
    test('minigame_sessions.group_id is NULLABLE and player_limit is frozen',
        () {
      expect(
        supabaseMigration,
        contains('group_id uuid,'),
        reason:
            'group_id must be nullable so DIRECT sessions (no group) exist '
            'alongside group sessions',
      );
      expect(
        supabaseMigration,
        contains('player_limit integer DEFAULT 8 NOT NULL'),
        reason:
            'the subscription-scaled player cap must be stored on the session '
            'and default to 8 (free tier)',
      );
    });

    test('create_minigame_session allows NULL p_group_id and gates groups only',
        () {
      expect(
        supabaseInvitesMigration,
        contains(
          'IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id)',
        ),
        reason:
            'a NULL p_group_id (direct session) must NOT require group '
            'membership; a non-null group keeps the is_group_member gate',
      );
      expect(
        supabaseInvitesMigration,
        contains("'not_member'"),
        reason: 'the typed not_member status must survive for group sessions',
      );
    });

    test('the frozen player cap is computed from the creator tier + enforced',
        () {
      expect(
        supabaseInvitesMigration,
        contains('minigame.free_max_players'),
        reason: 'the free-tier cap key must be read from app_config',
      );
      expect(
        supabaseInvitesMigration,
        contains('minigame.pro_max_players'),
        reason: 'the PRO-tier cap key must be read from app_config',
      );
      expect(
        supabaseInvitesMigration,
        contains('minigame.vip_max_players'),
        reason: 'the VIP-tier cap key must be read from app_config',
      );
      expect(
        supabaseInvitesMigration,
        contains("'player_limit_reached'"),
        reason: 'over-cap creates must be rejected with the typed status',
      );
      expect(
        supabaseInvitesMigration,
        contains('player_limit'),
        reason: 'the frozen cap must be stored on the session row',
      );
    });

    test('join and accept enforce the cap; join/finish gate direct sessions',
        () {
      expect(
        supabaseJoinFinishMigration,
        contains("'player_limit_reached'"),
        reason: 'join must reject a full direct session atomically',
      );
      expect(
        supabaseJoinFinishMigration,
        contains("'not_allowed'"),
        reason: 'join/finish must reject bystanders on direct sessions',
      );
      expect(
        supabaseInvitesMigration,
        contains("'player_limit_reached'"),
        reason: 'accept must enforce the same frozen cap',
      );
    });

    test('adds ms_read_direct_participant (direct-session participant reads)',
        () {
      expect(
        supabaseMigration,
        contains('ms_read_direct_participant'),
        reason: 'direct sessions must be readable by their participants',
      );
      expect(
        supabaseMigration,
        contains('group_id IS NULL'),
        reason: 'the direct-read policy must require group_id IS NULL',
      );
      expect(
        supabaseMigration,
        contains('ANY (minigame_sessions.participants)'),
        reason: 'only a participant may read a direct session',
      );
    });

    test('pgTAP pins the direct-session contract in both stacks', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains("'minigame_sessions.group_id is NULLABLE"),
          reason: '$name must assert the nullable group_id',
        );
        expect(
          content,
          contains("'minigame_sessions.player_limit is NOT NULL"),
          reason: '$name must assert the frozen player cap',
        );
        expect(
          content,
          contains(
            "'ms_read_direct_participant requires group_id IS NULL",
          ),
          reason: '$name must assert the direct-session read policy contract',
        );
        expect(
          content,
          contains(
            "'create_minigame_session allows NULL p_group_id",
          ),
          reason: '$name must assert the conditional membership gate',
        );
        expect(
          content,
          contains("'join_minigame_session gates DIRECT sessions"),
          reason: '$name must assert the direct join gate',
        );
      }
    });
  });

  group('pgTAP schema_test.sql plan consistency', () {
    int planOf(String content) {
      final match = RegExp(
        r'^SELECT plan\((\d+)\);',
        multiLine: true,
      ).firstMatch(content);
      expect(match, isNotNull, reason: 'schema_test.sql must declare plan(N)');
      return int.parse(match!.group(1)!);
    }

    int assertionCount(String content) {
      // Every pgTAP assertion is a statement starting at column 0 with
      // SELECT <assertion-fn>(. Multi-line assertions continue indented
      // (nested SQL inside ok(...) is also indented), so line-start matches
      // count exactly one per assertion. Same parser contract as I-57's
      // test/features/qr/qr_rpc_migration_test.dart (+ I-78's Section 46
      // prefixes trigger_is / volatility_is; + 2026-08-16 the _ok suffix
      // family fk_ok/pk_ok — Section 57 introduced fk_ok).
      return RegExp(
        r'^SELECT (ok|is|has_|hasnt_|col_|trigger_is|volatility_is|policies_are|columns_are|results_eq|function_privs_are|table_privs_are|column_privs_are|any_column_privs_are|any_sequence_privs_are|throws_ok|lives_ok|fk_ok|pk_ok)[a-z_]*\(',
        multiLine: true,
      ).allMatches(content).length;
    }

    test('supabase/tests/schema_test.sql plan(N) matches its assertions', () {
      expect(
        planOf(supabaseSchema),
        assertionCount(supabaseSchema),
        reason: 'update plan(N) when adding/removing pgTAP assertions',
      );
    });

    test(
      'supabase-testing/tests/schema_test.sql plan(N) matches its assertions',
      () {
        expect(
          planOf(testingSchema),
          assertionCount(testingSchema),
          reason: 'update plan(N) when adding/removing pgTAP assertions',
        );
      },
    );

    test('supabase-testing pgTAP suite mirrors the canonical one', () {
      expect(
        testingSchema,
        supabaseSchema,
        reason:
            'supabase-testing/tests/schema_test.sql must mirror the '
            'canonical pgTAP suite (I-02 parity convention)',
      );
    });

    test('both suites assert the RPC in Section 45', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 45'),
          reason: '$name must carry the create_minigame_session section header',
        );
        expect(
          content,
          contains(
            "has_function('create_minigame_session', "
            "ARRAY['uuid', 'text', 'integer', 'uuid[]']",
          ),
          reason: '$name must assert the invite-aware 4-arg RPC signature',
        );
        expect(
          content,
          contains("'create_minigame_session sets search_path"),
          reason: '$name must assert the search_path hardening',
        );
        expect(
          content,
          contains("'create_minigame_session is not PUBLIC-EXECUTABLE'"),
          reason: '$name must assert the PUBLIC EXECUTE revocation',
        );
        expect(
          content,
          contains("'create_minigame_session is authenticated-EXECUTABLE'"),
          reason: '$name must assert the authenticated EXECUTE grant',
        );
        expect(
          content,
          contains("'create_minigame_session references is_group_member'"),
          reason: '$name must assert the membership gate body contract',
        );
        expect(
          content,
          contains(
            "'create_minigame_session writes the minigame_wager ledger'",
          ),
          reason: '$name must assert the GWAG ledger body contract',
        );
        expect(
          content,
          contains(
            "'create_minigame_session writes one minigame_invites row per invitee",
          ),
          reason: '$name must assert the invites-table body contract',
        );
        expect(
          content,
          contains(
            "'create_minigame_session enforces the friends-only invite privacy switch",
          ),
          reason: '$name must assert the friends-only privacy gate body contract',
        );
      }
    });

    test('both suites assert the minigame-invites contract in Section 49b', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49b'),
          reason: '$name must carry the minigame-invites section header',
        );
        expect(
          content,
          contains("has_table('minigame_invites'"),
          reason: '$name must assert the invites table exists',
        );
        expect(
          content,
          contains("has_function('accept_minigame_invite', ARRAY['uuid']"),
          reason: '$name must assert the accept RPC signature',
        );
        expect(
          content,
          contains("has_function('decline_minigame_invite', ARRAY['uuid']"),
          reason: '$name must assert the decline RPC signature',
        );
        expect(
          content,
          contains("'minigame_invites has FORCE ROW LEVEL SECURITY"),
          reason: '$name must assert the FORCE RLS posture',
        );
        expect(
          content,
          contains(
            "'notifications joins the supabase_realtime publication",
          ),
          reason:
              '$name must assert notifications is realtime-published (GO-realtime invites)',
        );
      }
    });

    test('both suites assert the join/finish RPCs in Section 49', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49'),
          reason: '$name must carry the join/finish RPC section header',
        );
        expect(
          content,
          contains("has_function('join_minigame_session', ARRAY['uuid']"),
          reason: '$name must assert the join_minigame_session signature',
        );
        expect(
          content,
          contains(
            "has_function('finish_minigame_session', "
            "ARRAY['uuid', 'uuid', 'integer']",
          ),
          reason: '$name must assert the finish_minigame_session signature',
        );
        expect(
          content,
          contains("'join_minigame_session is authenticated-EXECUTABLE'"),
          reason: '$name must assert the join EXECUTE grant',
        );
        expect(
          content,
          contains("'finish_minigame_session is authenticated-EXECUTABLE'"),
          reason: '$name must assert the finish EXECUTE grant',
        );
        expect(
          content,
          contains(
            "'finish_minigame_session credits the winner via the minigame_win ledger'",
          ),
          reason: '$name must assert the winner-settlement body contract',
        );
      }
    });
  });

  group('minigame partida lobby (180_minigame_lobby)', () {
    final supabaseMigration =
        read('supabase/migrations/180_minigame_lobby/lobby.sql');
    final testingMigration =
        read('supabase-testing/migrations/180_minigame_lobby/lobby.sql');

    test('the lobby migration mirrors byte-identical into both stacks', () {
      expect(
        testingMigration,
        equals(supabaseMigration),
        reason: '180_minigame_lobby must be mirrored byte-identical '
            '(M-10 parity rule)',
      );
    });

    test('pgTAP pins the 180_minigame_lobby contract in both stacks', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 49g'),
          reason: '$name must carry the partida-lobby section header',
        );
        expect(
          content,
          contains("has_column('minigame_game_state', 'ready'"),
          reason: '$name must assert the ready map column',
        );
        expect(
          content,
          contains("has_function('set_minigame_ready', ARRAY['uuid', 'boolean']"),
          reason: '$name must assert the set_minigame_ready signature',
        );
        expect(
          content,
          contains("has_function('get_minigame_participants', ARRAY['uuid']"),
          reason: '$name must assert the get_minigame_participants signature',
        );
        expect(
          content,
          contains(
            "has_function('remove_minigame_participant', ARRAY['uuid', 'uuid']",
          ),
          reason: '$name must assert the remove_minigame_participant signature',
        );
        expect(
          content,
          contains(
            "'init_minigame_game_state is CREATOR-ONLY, backend-enforced via "
            "participants[0] (not_creator, 180_minigame_lobby)'",
          ),
          reason: '$name must assert the creator-only Start gate',
        );
        expect(
          content,
          contains("'minigame_sessions joins supabase_realtime"),
          reason: '$name must assert minigame_sessions is realtime-published',
        );
      }
    });
  });
}
