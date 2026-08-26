import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/auth/logic/username_policy.dart';

/// Username policy contract (2026-08-24 fake-OTP-error fix): specific,
/// user-facing validation messages for the profile-setup username field,
/// returned as a LIST — multiple violations are reported together.
///
/// Rules mirror the real requirements (`shared/constants/auth_constants.dart`:
/// min 5 graphemes; presence). The policy validates the SANITIZED value —
/// callers pass `InputSanitizer.sanitizeUsername` output (whitespace/@ are
/// stripped silently upstream, so no charset rule exists here).
void main() {
  group('usernamePolicyErrors', () {
    test('valid username yields no errors', () {
      expect(usernamePolicyErrors('sofia'), isEmpty);
      expect(usernamePolicyErrors('a' * 20), isEmpty);
    });

    test('empty value reports every violated rule (multiple errors)', () {
      final errors = usernamePolicyErrors('');
      expect(errors, contains(usernameRequiredMessage));
      expect(errors, contains(usernameMinLengthMessage));
      expect(errors.length, 2);
    });

    test('too-short value reports only the length rule', () {
      expect(usernamePolicyErrors('abc'), [usernameMinLengthMessage]);
      expect(usernamePolicyErrors('a'), [usernameMinLengthMessage]);
    });

    test('boundary: exactly the minimum is valid', () {
      expect(
        usernamePolicyErrors('a' * 5),
        isEmpty,
      );
    });
  });
}
