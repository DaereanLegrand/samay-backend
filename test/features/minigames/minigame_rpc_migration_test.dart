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
/// 2. The pgTAP suites (`schema_test.sql` in both stacks) stay
///    self-consistent: `plan(N)` equals the actual number of assertion
///    statements in the file, and both files carry the Section that asserts
///    the RPC (Section 45).
///
/// The winner-settlement/refund RPCs (`minigame_win` / `minigame_refund`
/// ledger writes) are NOT part of this migration — they are the documented
/// server RPC gap handed off to I-77/S-03 (see
/// docs/development/phase-11-gamification-minigames/2026-08-09_I63-minigames.md).
void main() {
  final root = Directory.current.path;

  String read(String path) => File('$root/$path').readAsStringSync();

  final supabaseMigration =
      read('supabase/migrations/20260809000006_minigame_rpc.sql');
  final testingMigration =
      read('supabase-testing/migrations/20260809000006_minigame_rpc.sql');
  final supabaseSchema = read('supabase/tests/schema_test.sql');
  final testingSchema = read('supabase-testing/tests/schema_test.sql');

  group('create_minigame_session RPC migration (20260809000006)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(supabaseMigration, isNotEmpty,
          reason: 'supabase/migrations/20260809000006_minigame_rpc.sql '
              'is missing or empty');
      expect(testingMigration, isNotEmpty,
          reason: 'supabase-testing/migrations/20260809000006_minigame_rpc.sql '
              'is missing or empty');
    });

    test('supabase-testing mirror matches the canonical migration', () {
      expect(testingMigration, supabaseMigration,
          reason: 'supabase-testing must mirror supabase/ migration-for-migration '
              '(I-02 parity convention)');
    });

    test('is SECURITY DEFINER with SET search_path = \'\' (I-31 pattern)', () {
      expect(supabaseMigration, contains('SECURITY DEFINER'));
      expect(supabaseMigration, contains("SET search_path = ''"));
      expect(supabaseMigration, contains('public.create_minigame_session'),
          reason: 'function must be created with a fully-qualified name');
    });

    test('validates group membership via the is_group_member helper (I-32)',
        () {
      expect(
        supabaseMigration,
        contains('public.is_group_member(p_group_id)'),
        reason: 'the membership gate must delegate to the SECURITY DEFINER '
            'is_group_member helper (recursion-safe, active members only)',
      );
      expect(
        supabaseMigration,
        contains("'not_member'"),
        reason: 'non-members must get the typed not_member outcome (returned '
            'as jsonb per the I-57 status contract, never RAISE\'d)',
      );
    });

    test('rejects negative wagers and validates the game type', () {
      expect(
        supabaseMigration,
        contains('p_wager < 0'),
        reason: 'negative wagers must be rejected (GWAG: integer shards >= 0)',
      );
      expect(
        supabaseMigration,
        contains('::public.mini_game_type'),
        reason: 'p_game_type must be validated by a cast to the DB enum '
            '(invalid values raise invalid_text_representation, mapped to '
            'the invalid_game_type outcome)',
      );
    });

    test('deducts personal_shards atomically when the wager is > 0', () {
      expect(
        supabaseMigration,
        contains(
          'SET personal_shards = personal_shards - p_wager',
        ),
        reason: 'the wager must be deducted from the caller\'s balance',
      );
      expect(
        supabaseMigration,
        contains('personal_shards >= p_wager'),
        reason: 'the UPDATE must be guarded so insufficient balances are '
            'never overdrawn',
      );
      expect(
        supabaseMigration,
        contains("'insufficient_shards'"),
        reason: 'the insufficient-balance outcome must be a typed status',
      );
    });

    test('writes the minigame_wager ledger entry with the session reference',
        () {
      expect(
        supabaseMigration,
        contains('INSERT INTO public.shard_ledger'),
        reason: 'the ledger insert must be fully qualified (search_path='')',
      );
      expect(
        supabaseMigration,
        contains("'minigame_wager'"),
        reason: 'the wager deduction must be recorded as reason=minigame_wager '
            '(GWAG ledger contract)',
      );
      expect(
        supabaseMigration,
        contains('reference_id'),
        reason: 'the ledger row must carry reference_id for escrow '
            'verifiability (sum of minigame_wager entries per session)',
      );
    });

    test('inserts the session with the caller as first participant and '
        'returns the id', () {
      expect(
        supabaseMigration,
        contains('INSERT INTO public.minigame_sessions'),
        reason: 'the session insert must be fully qualified (search_path='')',
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
        reason: 'the created status must carry the session id (client '
            'contract: MinigameService.createSession)',
      );
      expect(
        supabaseMigration,
        contains('ARRAY[v_current_user]'),
        reason: 'the initiator must be the first participant (GMCR session '
            'creation, participant select is future work)',
      );
    });

    test('returns every business outcome as a jsonb status (I-57 contract)',
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
    });

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

  group('pgTAP schema_test.sql plan consistency', () {
    int planOf(String content) {
      final match = RegExp(r'^SELECT plan\((\d+)\);', multiLine: true)
          .firstMatch(content);
      expect(match, isNotNull, reason: 'schema_test.sql must declare plan(N)');
      return int.parse(match!.group(1)!);
    }

    int assertionCount(String content) {
      // Every pgTAP assertion is a statement starting at column 0 with
      // SELECT <assertion-fn>(. Multi-line assertions continue indented
      // (nested SQL inside ok(...) is also indented), so line-start matches
      // count exactly one per assertion. Same parser contract as I-57's
      // test/features/qr/qr_rpc_migration_test.dart (+ I-78's Section 46
      // prefixes trigger_is / volatility_is).
      return RegExp(
        r'^SELECT (ok|is|has_|hasnt_|col_|trigger_is|volatility_is|policies_are|columns_are|results_eq)[a-z_]*\(',
        multiLine: true,
      ).allMatches(content).length;
    }

    test('supabase/tests/schema_test.sql plan(N) matches its assertions', () {
      expect(planOf(supabaseSchema), assertionCount(supabaseSchema),
          reason: 'update plan(N) when adding/removing pgTAP assertions');
    });

    test('supabase-testing/tests/schema_test.sql plan(N) matches its assertions',
        () {
      expect(planOf(testingSchema), assertionCount(testingSchema),
          reason: 'update plan(N) when adding/removing pgTAP assertions');
    });

    test('supabase-testing pgTAP suite mirrors the canonical one', () {
      expect(testingSchema, supabaseSchema,
          reason: 'supabase-testing/tests/schema_test.sql must mirror the '
              'canonical pgTAP suite (I-02 parity convention)');
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
          contains(
            "'create_minigame_session sets search_path",
          ),
          reason: '$name must assert the search_path hardening',
        );
        expect(
          content,
          contains(
            "'create_minigame_session is not PUBLIC-EXECUTABLE'",
          ),
          reason: '$name must assert the PUBLIC EXECUTE revocation',
        );
        expect(
          content,
          contains(
            "'create_minigame_session is authenticated-EXECUTABLE'",
          ),
          reason: '$name must assert the authenticated EXECUTE grant',
        );
        expect(
          content,
          contains(
            "'create_minigame_session references is_group_member'",
          ),
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
  });
}
