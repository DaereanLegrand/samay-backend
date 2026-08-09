import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/input_sanitizer.dart';

/// Unit tests for the shared [InputSanitizer] (finding SEC-06 / H-24).
///
/// The sanitizer is applied at every write boundary (profile setup, bio edit,
/// group create, invite/friend search, donate amount, chat message), so the
/// guarantees below — trim, control-char stripping, grapheme-safe length caps,
/// NFKC normalization — are what every user-visible string eventually passes.
void main() {
  group('InputSanitizer.sanitize', () {
    test('valid input is returned unchanged', () {
      expect(InputSanitizer.sanitize('Hello World'), 'Hello World');
      expect(InputSanitizer.sanitize('Ana'), 'Ana');
      expect(InputSanitizer.sanitize('Día de fiesta 🎉'), 'Día de fiesta 🎉');
    });

    test('trims leading and trailing whitespace', () {
      expect(InputSanitizer.sanitize('  Ana  '), 'Ana');
      expect(InputSanitizer.sanitize('\tGuns\nN Roses\r'), 'GunsN Roses');
    });

    test('strips C0 control characters (\\u0000-\\u001F)', () {
      expect(InputSanitizer.sanitize('a\u0000b'), 'ab');
      expect(InputSanitizer.sanitize('a\u0001b\u0002c'), 'abc');
      expect(InputSanitizer.sanitize('\u0007'), '');
    });

    test('strips DEL (\\u007F)', () {
      expect(InputSanitizer.sanitize('a\u007Fb'), 'ab');
    });

    test('strips C1 control characters (\\u0080-\\u009F)', () {
      expect(InputSanitizer.sanitize('a\u0085b'), 'ab');
      expect(InputSanitizer.sanitize('a\u009Fb'), 'ab');
    });

    test('strips zero-width format characters (\\u200B-\\u200F)', () {
      expect(InputSanitizer.sanitize('a\u200Bb'), 'ab');
      expect(InputSanitizer.sanitize('a\u200Cb'), 'ab');
      expect(InputSanitizer.sanitize('a\u200Db'), 'ab');
      expect(InputSanitizer.sanitize('a\u200Eb'), 'ab');
      expect(InputSanitizer.sanitize('a\u200Fb'), 'ab');
    });

    test('strips bidi override characters (Cf category, U+202A-U+202E)', () {
      expect(InputSanitizer.sanitize('a\u202Eb'), 'ab');
      expect(InputSanitizer.sanitize('a\u202Db'), 'ab');
    });

    test('caps length by grapheme clusters, not UTF-16 code units', () {
      // 😀 is 2 UTF-16 code units but 1 grapheme: a naive substring(0, 2)
      // would produce a broken surrogate pair.
      expect(InputSanitizer.sanitize('😀😀😀', maxLength: 2), '😀😀');
      expect(InputSanitizer.sanitize('abc', maxLength: 2), 'ab');
      expect(InputSanitizer.sanitize('abc', maxLength: 10), 'abc');
    });

    test('length cap applies after trimming and control-char stripping', () {
      expect(
        InputSanitizer.sanitize('  abcdef  ', maxLength: 3),
        'abc',
      );
      expect(
        InputSanitizer.sanitize('a\u200Bbcd', maxLength: 3),
        'abc',
      );
    });

    test('empty input stays empty', () {
      expect(InputSanitizer.sanitize(''), '');
    });

    test('input that is only control characters becomes empty', () {
      expect(InputSanitizer.sanitize('\u0000\u0001\u200B'), '');
    });

    test('does not normalize NFKC by default', () {
      expect(InputSanitizer.sanitize('①Ａ'), '①Ａ');
    });

    test('normalizes NFKC when requested', () {
      expect(
        InputSanitizer.sanitize('①Ａ', normalizeNfkc: true),
        '1A',
      );
      // Canonical equivalence: e + combining acute -> é
      expect(
        InputSanitizer.sanitize('e\u0301', normalizeNfkc: true),
        'é',
      );
    });

    test('is idempotent — sanitizing a sanitized string is a no-op', () {
      const dirty = '  a\u0000b\u200B c  ';
      final once = InputSanitizer.sanitize(dirty);
      expect(InputSanitizer.sanitize(once), once);
    });
  });

  group('InputSanitizer.sanitizeOptional', () {
    test('returns null for null input', () {
      expect(InputSanitizer.sanitizeOptional(null), isNull);
    });

    test('returns null when the sanitized result is empty', () {
      expect(InputSanitizer.sanitizeOptional('   '), isNull);
      expect(InputSanitizer.sanitizeOptional('\u0000'), isNull);
    });

    test('returns the sanitized value otherwise', () {
      expect(
        InputSanitizer.sanitizeOptional('  Hola\u0000 mundo  '),
        'Hola mundo',
      );
    });
  });

  group('InputSanitizer.sanitizeUsername', () {
    test('valid usernames are unchanged (case preserved)', () {
      expect(InputSanitizer.sanitizeUsername('AnaPerez'), 'AnaPerez');
      expect(InputSanitizer.sanitizeUsername('Lucas_88'), 'Lucas_88');
      expect(InputSanitizer.sanitizeUsername('Fiesta'), 'Fiesta');
    });

    test('strips whitespace everywhere, not just at the edges', () {
      expect(InputSanitizer.sanitizeUsername('  Ana  Perez '), 'AnaPerez');
      expect(InputSanitizer.sanitizeUsername('Lucas\tRamos'), 'LucasRamos');
    });

    test('strips at-signs', () {
      expect(InputSanitizer.sanitizeUsername('@AnaPerez'), 'AnaPerez');
      expect(InputSanitizer.sanitizeUsername('Ana@Perez@'), 'AnaPerez');
    });

    test('strips control characters', () {
      expect(InputSanitizer.sanitizeUsername('An\u0000a\u200BPerez'), 'AnaPerez');
    });

    test('caps length', () {
      final long = List.filled(40, 'a').join();
      expect(InputSanitizer.sanitizeUsername(long).length, 20);
    });

    test('normalizes NFKC by default (compatibility lookalikes)', () {
      expect(InputSanitizer.sanitizeUsername('Ｆｉｅｓｔａ'), 'Fiesta');
    });

    test('empty input stays empty', () {
      expect(InputSanitizer.sanitizeUsername(''), '');
      expect(InputSanitizer.sanitizeUsername(' @  '), '');
    });
  });

  group('InputSanitizer.sanitizeAmount', () {
    test('valid digit strings are unchanged', () {
      expect(InputSanitizer.sanitizeAmount('512'), '512');
      expect(InputSanitizer.sanitizeAmount('0'), '0');
    });

    test('keeps digits only', () {
      expect(InputSanitizer.sanitizeAmount('12a34'), '1234');
      expect(InputSanitizer.sanitizeAmount('abc'), '');
      expect(InputSanitizer.sanitizeAmount(' 10 '), '10');
      expect(InputSanitizer.sanitizeAmount('1.5'), '15');
    });

    test('caps at 9 digits (int-safe)', () {
      expect(
        InputSanitizer.sanitizeAmount('123456789012345'),
        '123456789',
      );
    });

    test('empty input stays empty', () {
      expect(InputSanitizer.sanitizeAmount(''), '');
    });
  });

  group('length constants', () {
    test('field caps are defined and positive', () {
      expect(InputSanitizer.usernameMaxLength, greaterThan(0));
      expect(InputSanitizer.bioMaxLength, greaterThan(0));
      expect(InputSanitizer.groupNameMaxLength, greaterThan(0));
      expect(InputSanitizer.groupDescriptionMaxLength, greaterThan(0));
      expect(InputSanitizer.messageMaxLength, greaterThan(0));
      expect(InputSanitizer.searchQueryMaxLength, greaterThan(0));
    });
  });
}
