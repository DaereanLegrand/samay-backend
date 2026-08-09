import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/auth/age_policy.dart';

void main() {
  group('isAdult', () {
    test('returns false for null birth dates', () {
      expect(isAdult(null, now: DateTime(2018, 5, 15)), isFalse);
    });

    test('is true exactly on the 18th birthday', () {
      expect(
        isAdult(DateTime(2000, 5, 15), now: DateTime(2018, 5, 15)),
        isTrue,
      );
    });

    test('is false one day before the 18th birthday (17y 364d)', () {
      expect(
        isAdult(DateTime(2000, 5, 15), now: DateTime(2018, 5, 14)),
        isFalse,
      );
    });

    test('is true the day after the 18th birthday', () {
      expect(
        isAdult(DateTime(2000, 5, 15), now: DateTime(2018, 5, 16)),
        isTrue,
      );
    });

    test('is false well before adulthood', () {
      expect(
        isAdult(DateTime(2010, 1, 1), now: DateTime(2018, 5, 15)),
        isFalse,
      );
    });

    test('is false for future dates', () {
      expect(
        isAdult(DateTime(2020, 5, 15), now: DateTime(2018, 5, 15)),
        isFalse,
      );
    });

    test('is true on the 18th birthday at the end of the year', () {
      expect(
        isAdult(DateTime(2000, 12, 31), now: DateTime(2018, 12, 31)),
        isTrue,
      );
    });

    test('is false the day before a year-end 18th birthday', () {
      expect(
        isAdult(DateTime(2000, 12, 31), now: DateTime(2018, 12, 30)),
        isFalse,
      );
    });

    test('leap-day birthdays do not turn 18 on Feb 28', () {
      expect(
        isAdult(DateTime(2000, 2, 29), now: DateTime(2018, 2, 28)),
        isFalse,
      );
    });

    test('leap-day birthdays turn 18 on Mar 1', () {
      expect(
        isAdult(DateTime(2000, 2, 29), now: DateTime(2018, 3, 1)),
        isTrue,
      );
    });

    test('uses DateTime.now() when now is omitted', () {
      final today = DateTime.now();
      expect(
        isAdult(DateTime(today.year - 20, today.month, today.day)),
        isTrue,
      );
      expect(
        isAdult(DateTime(today.year - 10, today.month, today.day)),
        isFalse,
      );
    });
  });

  group('formatDob', () {
    test('formats as day/month/year without zero padding', () {
      expect(formatDob(DateTime(2000, 5, 15)), '15/5/2000');
      expect(formatDob(DateTime(2000, 12, 1)), '1/12/2000');
      expect(formatDob(DateTime(1987, 3, 7)), '7/3/1987');
    });

    test('preserves single-digit day and month', () {
      expect(formatDob(DateTime(2000, 1, 2)), '2/1/2000');
    });
  });
}
