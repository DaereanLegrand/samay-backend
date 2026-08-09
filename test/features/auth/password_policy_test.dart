import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/auth/password_policy.dart';

void main() {
  group('isPasswordValid', () {
    test('requires at least 6 characters', () {
      expect(isPasswordValid('abc123'), isTrue);
      expect(isPasswordValid('abcde1'), isTrue);
      expect(isPasswordValid('abcde'), isFalse);
      expect(isPasswordValid('abc12'), isFalse);
      expect(isPasswordValid(''), isFalse);
    });

    test('requires at least one digit', () {
      expect(isPasswordValid('abcdef'), isFalse);
      expect(isPasswordValid('abcdefg'), isFalse);
      expect(isPasswordValid('a1b2c3'), isTrue);
      expect(isPasswordValid('abcdef1'), isTrue);
    });

    test('digits-only passwords are valid once long enough', () {
      expect(isPasswordValid('123456'), isTrue);
      expect(isPasswordValid('000000'), isTrue);
    });

    test('a single digit anywhere satisfies the digit rule', () {
      expect(isPasswordValid('1abcde'), isTrue);
      expect(isPasswordValid('abcde9'), isTrue);
    });
  });

  group('passwordError', () {
    test('returns null for valid passwords', () {
      expect(passwordError('abc123'), isNull);
      expect(passwordError('a1b2c3d4'), isNull);
    });

    test('returns the exact Spanish message for short passwords', () {
      expect(
        passwordError('abc'),
        'La contraseña debe tener al menos 6 caracteres y contener un número.',
      );
    });

    test('returns the exact Spanish message for digit-less passwords', () {
      expect(
        passwordError('abcdef'),
        'La contraseña debe tener al menos 6 caracteres y contener un número.',
      );
    });

    test('returns the message for empty input', () {
      expect(passwordError(''), isNotNull);
    });
  });
}
