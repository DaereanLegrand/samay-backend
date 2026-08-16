import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static verification of the minigame server-side contract (I-63, GMCR/GWAG
/// foundation):
///
/// 1. The `create_minigame_session` RPC migration exists in BOTH stacks
///    (`supabase/` + `supabase-testing/` mirror, per AGENT-RULES §2 / the
///    I-02 parity convention) with the required hardening: SECURITY DEFINER,
///    `SET search_path = ''`, group-membership gate via the I-32
///    `is_group_member` helper, atomic wager deduction + `shard_ledger`
///    (`minigame_wager`) + session insert, PUBLIC EXECUTE revoked,
///    authenticated-only EXECUTE grant.
/// 2. The `join_minigame_session` / `finish_minigame_session` RPC migration
///    (20260813000001, R4) exists in BOTH stacks with the same hardening —
///    the I-77/S-03 server RPC gap closure.
/// 3. The pgTAP suites (`schema_test.sql` in both stacks) stay
///    self-consistent: `plan(N)` equals the actual number of assertion
///    statements in the file, and both files carry the Sections that assert
///    the RPCs (Section 45 + Section 49).
void main() {
  final root = Directory.current.path;

  String read(String path) => File('$root/$path').readAsStringSync();

  final supabaseMigration = read(
    'supabase/migrations/20260809000006_minigame_rpc.sql',
  );
  final testingMigration = read(
    'supabase-testing/migrations/20260809000006_minigame_rpc.sql',
  );
  final supabaseJoinFinishMigration = read(
    'supabase/migrations/20260813000001_minigame_join_finish_rpc.sql',
  );
  final testingJoinFinishMigration = read(
    'supabase-testing/migrations/20260813000001_minigame_join_finish_rpc.sql',
  );
  final supabaseSchema = read('supabase/tests/schema_test.sql');
  final testingSchema = read('supabase-testing/tests/schema_test.sql');

  group('create_minigame_session RPC migration (20260809000006)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(
        supabaseMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/20260809000006_minigame_rpc.sql '
            'is missing or empty',
      );
      expect(
        testingMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/20260809000006_minigame_rpc.sql '
            'is missing or empty',
      );
    });

    test('supabase-testing mirror matches the canonical migration', () {
      expect(
        testingMigration,
        supabaseMigration,
        reason:
            'supabase-testing must mirror supabase/ migration-for-migration '
            '(I-02 parity convention)',
      );
    });

    test('is SECURITY DEFINER with SET search_path = \'\' (I-31 pattern)', () {
      expect(supabaseMigration, contains('SECURITY DEFINER'));
      expect(supabaseMigration, contains("SET search_path = ''"));
      expect(
        supabaseMigration,
        contains('public.create_minigame_session'),
        reason: 'function must be created with a fully-qualified name',
      );
    });

    test(
      'validates group membership via the is_group_member helper (I-32)',
      () {
        expect(
          supabaseMigration,
          contains('public.is_group_member(p_group_id)'),
          reason:
              'the membership gate must delegate to the SECURITY DEFINER '
              'is_group_member helper (recursion-safe, active members only)',
        );
        expect(
          supabaseMigration,
          contains("'not_member'"),
          reason:
              'non-members must get the typed not_member outcome (returned '
              'as jsonb per the I-57 status contract, never RAISE\'d)',
        );
      },
    );

    test('rejects negative wagers and validates the game type', () {
      expect(
        supabaseMigration,
        contains('p_wager < 0'),
        reason: 'negative wagers must be rejected (GWAG: integer shards >= 0)',
      );
      expect(
        supabaseMigration,
        contains('::public.mini_game_type'),
        reason:
            'p_game_type must be validated by a cast to the DB enum '
            '(invalid values raise invalid_text_representation, mapped to '
            'the invalid_game_type outcome)',
      );
    });

    test('deducts personal_shards atomically when the wager is > 0', () {
      expect(
        supabaseMigration,
        contains('SET personal_shards = personal_shards - p_wager'),
        reason: 'the wager must be deducted from the caller\'s balance',
      );
      expect(
        supabaseMigration,
        contains('personal_shards >= p_wager'),
        reason:
            'the UPDATE must be guarded so insufficient balances are '
            'never overdrawn',
      );
      expect(
        supabaseMigration,
        contains("'insufficient_shards'"),
        reason: 'the insufficient-balance outcome must be a typed status',
      );
    });

    test(
      'writes the minigame_wager ledger entry with the session reference',
      () {
        expect(
          supabaseMigration,
          contains('INSERT INTO public.shard_ledger'),
          reason:
              'the ledger insert must be fully qualified (search_path='
              ')',
        );
        expect(
          supabaseMigration,
          contains("'minigame_wager'"),
          reason:
              'the wager deduction must be recorded as reason=minigame_wager '
              '(GWAG ledger contract)',
        );
        expect(
          supabaseMigration,
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
        supabaseMigration,
        contains('INSERT INTO public.minigame_sessions'),
        reason:
            'the session insert must be fully qualified (search_path='
            ')',
      );
      expect(
        supabaseMigration,
        contains("'active'"),
        reason: 'new sessions start with status=active (GMCR step 4)',
      );
      expect(
        supabaseMigration,
        contains('RETURNING id'),
        reason: 'the RPC must capture the created session id',
      );
      expect(
        supabaseMigration,
        contains("'created'"),
        reason: 'the success outcome must be the created status',
      );
      expect(
        supabaseMigration,
        contains("'sessionId'"),
        reason:
            'the created status must carry the session id (client '
            'contract: MinigameService.createSession)',
      );
      expect(
        supabaseMigration,
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
            supabaseMigration,
            contains(status),
            reason: 'status $status must be returned by the RPC',
          );
        }
      },
    );

    test('revokes PUBLIC EXECUTE and grants authenticated only', () {
      expect(
        supabaseMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.create_minigame_session'
          '(uuid, text, integer) FROM PUBLIC',
        ),
      );
      expect(
        supabaseMigration,
        contains(
          'GRANT EXECUTE ON FUNCTION public.create_minigame_session'
          '(uuid, text, integer) TO authenticated',
        ),
      );
      expect(
        supabaseMigration,
        isNot(contains('TO anon')),
        reason: 'anon must never create minigame sessions',
      );
    });

    test('keeps the winner-settlement RPC out of scope (documented gap)', () {
      // The migration implements only the create-side escrow (deduct +
      // minigame_wager ledger + session). Winner settlement (minigame_win
      // ledger + escrow credit) and draw refunds (minigame_refund) are the
      // documented server RPC gap — handoff I-77/S-03.
      expect(
        supabaseMigration,
        isNot(contains('personal_shards = personal_shards +')),
        reason: 'no escrow-credit path (minigame_win) may exist in scope',
      );
      expect(
        supabaseMigration,
        isNot(contains('winner_id')),
        reason: 'no winner-resolution write may exist in scope',
      );
    });
  });

  group('join/finish minigame session RPC migration (20260813000001)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(
        supabaseJoinFinishMigration,
        isNotEmpty,
        reason:
            'supabase/migrations/20260813000001_minigame_join_finish_rpc.sql '
            'is missing or empty',
      );
      expect(
        testingJoinFinishMigration,
        isNotEmpty,
        reason:
            'supabase-testing/migrations/20260813000001_minigame_join_finish_rpc.sql '
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

    test('both RPCs are SECURITY DEFINER with SET search_path = \'\' '
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
      expect(supabaseJoinFinishMigration, contains("SET search_path = ''"));
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
          'REVOKE ALL ON FUNCTION public.join_minigame_session(uuid) FROM PUBLIC',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'GRANT EXECUTE ON FUNCTION public.join_minigame_session(uuid) TO authenticated',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.finish_minigame_session(uuid, uuid, integer) FROM PUBLIC',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        contains(
          'GRANT EXECUTE ON FUNCTION public.finish_minigame_session(uuid, uuid, integer) TO authenticated',
        ),
      );
      expect(
        supabaseJoinFinishMigration,
        isNot(contains('TO anon')),
        reason: 'anon must never join or finish minigame sessions',
      );
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
            "ARRAY['uuid', 'text', 'integer']",
          ),
          reason: '$name must assert the RPC signature',
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
}
