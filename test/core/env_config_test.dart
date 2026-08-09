import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/env_config.dart';

/// EnvConfig is now compile-time (--dart-define / --dart-define-from-file),
/// so `String.fromEnvironment` constants resolve at build time. In the test
/// environment they default to `''` — the validated getters therefore throw,
/// and the pure [EnvConfig.validate] seam is what carries the missing-var
/// behavior unit tests (SEC-03 / SEC-09 / M-31 / SUP-05).
void main() {
  group('EnvConfig.validate', () {
    test('returns the value unchanged when it is non-empty', () {
      const url = 'https://supabase.samay.example.com';
      const key = 'sb_publishable_placeholder';
      expect(EnvConfig.validate(url, 'SUPABASE_URL'), url);
      expect(EnvConfig.validate(key, 'SUPABASE_ANON_KEY'), key);
    });

    test('throws StateError for an empty value (missing dart-define)', () {
      expect(
        () => EnvConfig.validate('', 'SUPABASE_URL'),
        throwsStateError,
      );
      expect(
        () => EnvConfig.validate('', 'SUPABASE_ANON_KEY'),
        throwsStateError,
      );
    });

    test('throws StateError naming the missing key', () {
      try {
        EnvConfig.validate('', 'SUPABASE_ANON_KEY');
        fail('expected a StateError');
      } on StateError catch (e) {
        expect(e.message, contains('SUPABASE_ANON_KEY'));
        expect(e.message, contains('Missing required env variable'));
      }
    });

    test('throws StateError for whitespace-only values', () {
      expect(() => EnvConfig.validate('   ', 'SUPABASE_URL'), throwsStateError);
    });
  });

  group('EnvConfig compile-time getters (test env)', () {
    test('raw const getters default to empty strings without --dart-define',
        () {
      // `flutter test` runs without --dart-define; the const defaults ('')
      // are baked in at compile time.
      expect(EnvConfig.supabaseUrlRaw, isEmpty);
      expect(EnvConfig.supabaseAnonKeyRaw, isEmpty);
    });

    test('validated getters fail fast with StateError in the test env', () {
      // Mirrors the old flutter_dotenv missing-var behavior: a build without
      // the defines must fail loudly at startup, not ship misconfigured.
      expect(() => EnvConfig.supabaseUrl, throwsStateError);
      expect(() => EnvConfig.supabaseAnonKey, throwsStateError);
    });
  });
}
