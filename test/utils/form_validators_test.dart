import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/form_validators.dart';

void main() {
  group('requiredValidator', () {
    test('fails on null, empty and whitespace-only input (trim-empty check)',
        () {
      expect(requiredValidator(null), isNotNull);
      expect(requiredValidator(''), isNotNull);
      expect(requiredValidator('   '), isNotNull);
      expect(requiredValidator('\t\n '), isNotNull);
    });

    test('passes non-empty input', () {
      expect(requiredValidator('a'), isNull);
      expect(requiredValidator(' a '), isNull);
    });

    test('returns the default message when none is provided', () {
      expect(requiredValidator(''), formRequiredMessage);
    });

    test('returns the custom message verbatim', () {
      const msg = 'custom required message';
      expect(requiredValidator('', message: msg), msg);
    });
  });

  group('emailValidator', () {
    test('passes common valid addresses', () {
      for (final email in [
        'a@b.com',
        'user.name+tag@sub.domain.co',
        'x@y.io',
        'USER@B.COM',
        'a@b.c',
      ]) {
        expect(emailValidator(email), isNull, reason: email);
      }
    });

    test('fails on malformed addresses', () {
      for (final email in [
        null,
        '',
        '   ',
        'a',
        'a@',
        '@b.com',
        'a b@c.com',
        'a@b..com',
        'a@.b.com',
        'a@b.',
        'a@-b.com',
        ' a@b.com',
        'a@b.com ',
      ]) {
        expect(emailValidator(email), isNotNull, reason: '$email');
      }
    });

    test('returns the default message when none is provided', () {
      expect(emailValidator('a@'), formEmailMessage);
    });

    test('returns the custom message verbatim', () {
      const msg = 'custom email message';
      expect(emailValidator('a@', message: msg), msg);
    });
  });

  group('lengthValidator', () {
    test('fails below min and passes at/above it', () {
      expect(lengthValidator('ab', min: 3), isNotNull);
      expect(lengthValidator('abc', min: 3), isNull);
      expect(lengthValidator('abcd', min: 3), isNull);
    });

    test('fails above max and passes at/below it', () {
      expect(lengthValidator('abc', min: 0, max: 2), isNotNull);
      expect(lengthValidator('abc', min: 0, max: 3), isNull);
      expect(lengthValidator('a', min: 0, max: 3), isNull);
    });

    test('null/empty fail with min > 0 and pass with min == 0 (optional '
        'field shape)', () {
      expect(lengthValidator(null, min: 1), isNotNull);
      expect(lengthValidator('', min: 1), isNotNull);
      expect(lengthValidator(null, min: 0), isNull);
      expect(lengthValidator('', min: 0), isNull);
    });

    test('counts raw characters — no implicit trimming', () {
      expect(lengthValidator('   ', min: 1), isNull);
    });

    test('returns the default and custom messages', () {
      expect(lengthValidator('ab', min: 3), formLengthMessage);
      const msg = 'custom length message';
      expect(lengthValidator('ab', min: 3, message: msg), msg);
    });
  });

  group('numericValidator', () {
    test('passes integers, with optional min/max bounds (inclusive)', () {
      expect(numericValidator('5'), isNull);
      expect(numericValidator('5', min: 1), isNull);
      expect(numericValidator('5', min: 5), isNull);
      expect(numericValidator('5', max: 5), isNull);
      expect(numericValidator('0', min: 0, max: 10), isNull);
    });

    test('fails on null, empty and non-integer input', () {
      for (final v in [null, '', 'abc', '5.5', '-']) {
        expect(numericValidator(v), isNotNull, reason: '$v');
      }
    });

    test('fails below min and above max', () {
      expect(numericValidator('0', min: 1), isNotNull);
      expect(numericValidator('-3', min: 1), isNotNull);
      expect(numericValidator('6', max: 5), isNotNull);
      expect(numericValidator('-1', min: 0), isNotNull);
    });

    test('negative integers parse when no min is set', () {
      expect(numericValidator('-3'), isNull);
      expect(numericValidator('-3', min: -3), isNull);
    });

    test('returns the default and custom messages', () {
      expect(numericValidator('abc'), formNumericMessage);
      const msg = 'custom numeric message';
      expect(numericValidator('abc', message: msg), msg);
    });
  });

  group('compose', () {
    test('returns null when every validator passes', () {
      final v = compose([requiredValidator, emailValidator]);
      expect(v('a@b.com'), isNull);
    });

    test('first failure wins — later validators are never consulted', () {
      final v = compose([
        (x) => lengthValidator(x, min: 4),
        emailValidator,
      ]);
      expect(v('ab'), formLengthMessage,
          reason: 'the short input fails length before email is consulted');
      expect(v('abcd'), formEmailMessage,
          reason: 'length-valid input falls through to the email rule');
      expect(v('a@b.com'), isNull);
    });

    test('null entries in the list are skipped', () {
      final v = compose([null, requiredValidator, null]);
      expect(v('x'), isNull);
      expect(v(''), isNotNull);
    });

    test('an empty or all-null list always passes', () {
      expect(compose([])('anything'), isNull);
      expect(compose([null, null])(''), isNull);
    });

    test('composed validators are reusable', () {
      final v = compose([requiredValidator, emailValidator]);
      expect(v(''), isNotNull);
      expect(v('a@b.com'), isNull);
      expect(v('nope'), isNotNull);
    });
  });

  group('FormState', () {
    test('validate stores the per-field results', () {
      final form = FormState()
        ..validate({
          'email': emailValidator,
          'username': requiredValidator,
        }, {
          'email': 'a@b.com',
          'username': '   ',
        });
      expect(form.errors['email'], isNull);
      expect(form.errors['username'], isNotNull);
      expect(form.isValid, isFalse);
    });

    test('isValid is true when every field validates', () {
      final form = FormState()
        ..validate({
          'email': emailValidator,
          'username': requiredValidator,
        }, {
          'email': 'a@b.com',
          'username': 'ana',
        });
      expect(form.isValid, isTrue);
      expect(form.errors, {'email': null, 'username': null});
    });

    test('validate discards stale errors from the previous run', () {
      final form = FormState()
        ..validate({'email': emailValidator}, {'email': 'broken'});
      expect(form.isValid, isFalse);

      form.validate({'email': emailValidator}, {'email': 'a@b.com'});
      expect(form.isValid, isTrue);
      expect(form.errors['email'], isNull);
    });

    test('no rules means everything is valid', () {
      expect(FormState().isValid, isTrue);
    });
  });
}
