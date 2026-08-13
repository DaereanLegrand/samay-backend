import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static verification of the QR server-side contract (I-57):
///
/// 1. The `validate_qr_token` RPC migration exists in BOTH stacks
///    (`supabase/` + `supabase-testing/` mirror, per AGENT-RULES §2 / the
///    I-02 parity convention) with the required hardening: SECURITY DEFINER,
///    `SET search_path = ''`, SELECT FOR UPDATE serialization, PUBLIC
///    EXECUTE revoked, authenticated-only EXECUTE grant.
/// 2. The pgTAP suites (`schema_test.sql` in both stacks) stay
///    self-consistent: `plan(N)` equals the actual number of assertion
///    statements in the file (verified against the pre-existing file: 250
///    assertions → `plan(250)`), and both files contain the Section that
///    asserts the RPC (Section 42).
///
/// No database is required — this is a pure file-scan (static verification;
/// the dynamic RPC behavior is covered by the curl opt-tests when the stack
/// is up, and the client contract by `test/features/qr/event_qr_service_test.dart`).
void main() {
  final root = Directory.current.path;

  String read(String path) => File('$root/$path').readAsStringSync();

  final supabaseMigration =
      read('supabase/migrations/20260809000005_qr_validate_rpc.sql');
  final testingMigration =
      read('supabase-testing/migrations/20260809000005_qr_validate_rpc.sql');
  final supabaseSchema = read('supabase/tests/schema_test.sql');
  final testingSchema = read('supabase-testing/tests/schema_test.sql');

  group('validate_qr_token RPC migration (20260809000005)', () {
    test('exists in both the supabase/ and supabase-testing/ stacks', () {
      expect(supabaseMigration, isNotEmpty,
          reason: 'supabase/migrations/20260809000005_qr_validate_rpc.sql '
              'is missing or empty');
      expect(testingMigration, isNotEmpty,
          reason: 'supabase-testing/migrations/20260809000005_qr_validate_rpc.sql '
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
      expect(supabaseMigration, contains('public.validate_qr_token'),
          reason: 'function must be created with a fully-qualified name');
    });

    test('serializes concurrent scans with SELECT FOR UPDATE (MVP §6.4)', () {
      expect(
        supabaseMigration,
        contains('FROM public.event_qr_tokens'),
        reason: 'the token lookup must be fully qualified (search_path='')',
      );
      expect(
        supabaseMigration,
        contains('FOR UPDATE'),
        reason: 'SELECT FOR UPDATE on the token row prevents double-confirmation',
      );
      expect(
        supabaseMigration,
        contains('scanned_at = now(), attendance_confirmed = true'),
        reason: 'the atomic token update must mark the attendance confirmed',
      );
      expect(
        supabaseMigration,
        contains('INSERT INTO public.event_attendances'),
        reason: 'the attendance insert must be part of the same transaction',
      );
      expect(
        supabaseMigration,
        contains("SET status = 'attended'"),
        reason: "the invite status flip to 'attended' must be atomic",
      );
    });

    test('revokes PUBLIC EXECUTE and grants authenticated only', () {
      expect(
        supabaseMigration,
        contains(
          'REVOKE ALL ON FUNCTION public.validate_qr_token(uuid, text) FROM PUBLIC',
        ),
      );
      expect(
        supabaseMigration,
        contains(
          'GRANT EXECUTE ON FUNCTION public.validate_qr_token(uuid, text) TO authenticated',
        ),
      );
      expect(
        supabaseMigration,
        isNot(contains('TO anon')),
        reason: 'anon must never execute the validator',
      );
    });

    test('returns business outcomes as jsonb statuses (QRSC error contract)', () {
      for (final status in const [
        "'not_promotor'",
        "'not_in_window'",
        "'invalid_token'",
        "'expired'",
        "'already_scanned'",
        "'not_invited'",
        "'confirmed'",
      ]) {
        expect(
          supabaseMigration,
          contains(status),
          reason: 'status $status must be returned by the RPC',
        );
      }
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
      // count exactly one per assertion. The function-name pattern covers
      // every pgTAP assertion prefix used in this file (ok/is/has_* /hasnt_* /
      // col_* /policies_are /columns_are /trigger_is /volatility_is — the
      // last two from I-77's Section 46). Verified against the pre-existing
      // file: 250 assertions ↔ plan(250); Section 44 adds 4 → plan(254);
      // Section 46 adds 42 → plan(304) (I-78 re-verified the regex against
      // every `^SELECT <fn>(` prefix in the file).
      return RegExp(
        r'^SELECT (ok|is|has_|hasnt_|col_|trigger_is|volatility_is|policies_are|columns_are|results_eq|function_privs_are|table_privs_are|column_privs_are|any_column_privs_are|any_sequence_privs_are|throws_ok|lives_ok)[a-z_]*\(',
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

    test('both suites assert the validate_qr_token RPC in Section 44', () {
      for (final entry in {
        'supabase/tests/schema_test.sql': supabaseSchema,
        'supabase-testing/tests/schema_test.sql': testingSchema,
      }.entries) {
        final name = entry.key;
        final content = entry.value;
        expect(
          content,
          contains('SECTION 44'),
          reason: '$name must carry the validate_qr_token section header',
        );
        expect(
          content,
          contains(
            "has_function('validate_qr_token', ARRAY['uuid', 'text']",
          ),
          reason: '$name must assert the RPC signature',
        );
        expect(
          content,
          contains("'validate_qr_token sets search_path"),
          reason: '$name must assert the search_path hardening',
        );
        expect(
          content,
          contains(
            "'validate_qr_token is not PUBLIC-EXECUTABLE'",
          ),
          reason: '$name must assert the PUBLIC EXECUTE revocation',
        );
        expect(
          content,
          contains(
            "'validate_qr_token is authenticated-EXECUTABLE'",
          ),
          reason: '$name must assert the authenticated EXECUTE grant',
        );
      }
    });
  });
}
