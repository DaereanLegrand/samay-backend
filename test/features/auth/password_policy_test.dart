import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/auth/logic/password_policy.dart';

void main() {
  group('isPasswordValid', () {
    test('requires at least 8 characters (S-05, NIST 800-63B)', () {
      expect(isPasswordValid('abc12345'), isTrue);
      expect(isPasswordValid('abcdefg1'), isTrue);
      expect(isPasswordValid('abcdefg'), isFalse);
      expect(isPasswordValid('abc123'), isFalse);
      expect(isPasswordValid(''), isFalse);
    });

    test('requires at least one digit', () {
      expect(isPasswordValid('abcdef'), isFalse);
      expect(isPasswordValid('abcdefg'), isFalse);
      expect(isPasswordValid('a1b2c3d4'), isTrue);
      expect(isPasswordValid('abcdefg1'), isTrue);
    });

    test('digits-only passwords are valid once long enough', () {
      expect(isPasswordValid('12345678'), isTrue);
      expect(isPasswordValid('00000000'), isTrue);
    });

    test('a single digit anywhere satisfies the digit rule', () {
      expect(isPasswordValid('1abcdefg'), isTrue);
      expect(isPasswordValid('abcdefg9'), isTrue);
    });
  });

  group('passwordError', () {
    test('returns null for valid passwords', () {
      expect(passwordError('abc12345'), isNull);
      expect(passwordError('a1b2c3d4'), isNull);
    });

    test('returns the exact Spanish message for short passwords', () {
      expect(
        passwordError('abc'),
        'La contraseña debe tener al menos 8 caracteres y contener un número.',
      );
    });

    test('returns the exact Spanish message for digit-less passwords', () {
      expect(
        passwordError('abcdef'),
        'La contraseña debe tener al menos 8 caracteres y contener un número.',
      );
    });

    test('returns the message for empty input', () {
      expect(passwordError(''), isNotNull);
    });
  });
}
