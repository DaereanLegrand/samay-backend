import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/otp_format.dart';

void main() {
  group('cleanOtpDigits', () {
    test('keeps pure digit strings unchanged', () {
      expect(cleanOtpDigits('123456'), '123456');
      expect(cleanOtpDigits(''), '');
      expect(cleanOtpDigits('0'), '0');
    });

    test('strips non-digit characters', () {
      expect(cleanOtpDigits('12-34 56'), '123456');
      expect(cleanOtpDigits('1a2b3c'), '123');
      expect(cleanOtpDigits('(123) 456'), '123456');
      expect(cleanOtpDigits('abc'), '');
    });

    test('caps the result at 6 digits (auto-submit length)', () {
      expect(cleanOtpDigits('1234567'), '123456');
      expect(cleanOtpDigits('1234567890'), '123456');
      expect(cleanOtpDigits('1-2-3-4-5-6-7-8'), '123456');
    });

    test('is safe with unicode and symbols', () {
      expect(cleanOtpDigits('a1\u00b22\u00b33'), '123');
      expect(cleanOtpDigits('6\u20136'), '66');
    });
  });
}
