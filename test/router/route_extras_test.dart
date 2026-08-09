import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/router/route_extras.dart';

void main() {
  group('VerifyExtra', () {
    test('fromObject returns null when extra is missing', () {
      expect(VerifyExtra.fromObject(null), isNull);
    });

    test('fromObject returns null when extra has the wrong type', () {
      expect(VerifyExtra.fromObject(42), isNull);
    });

    test('fromObject returns null when a required field is missing', () {
      expect(VerifyExtra.fromObject({'email': 'a@b.com'}), isNull);
    });

    test('fromObject returns null when a field has the wrong type', () {
      expect(
        VerifyExtra.fromObject({'email': 42, 'password': 'x'}),
        isNull,
      );
    });

    test('fromObject returns null when a field is empty', () {
      expect(VerifyExtra.fromObject({'email': '', 'password': 'x'}), isNull);
    });

    test('fromObject parses a legacy map extra', () {
      final extra = VerifyExtra.fromObject(
        {'email': 'a@b.com', 'password': 'secret1'},
      );
      expect(extra, isNotNull);
      expect(extra!.email, 'a@b.com');
      expect(extra.password, 'secret1');
    });

    test('fromObject returns a typed extra unchanged', () {
      const typed = VerifyExtra(email: 'a@b.com', password: 'secret1');
      expect(VerifyExtra.fromObject(typed), same(typed));
    });
  });

  group('PrivacyTermsExtra', () {
    test('fromObject parses a legacy map extra', () {
      final extra = PrivacyTermsExtra.fromObject(
        {'email': 'a@b.com', 'dateOfBirth': '2000-01-01'},
      );
      expect(extra, isNotNull);
      expect(extra!.email, 'a@b.com');
      expect(extra.dateOfBirth, '2000-01-01');
    });

    test('fromObject returns null on a wrong-typed extra', () {
      expect(PrivacyTermsExtra.fromObject('nope'), isNull);
    });

    test('fromObject returns a typed extra unchanged', () {
      const typed = PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01');
      expect(PrivacyTermsExtra.fromObject(typed), same(typed));
    });
  });

  group('ProfileSetupExtra', () {
    test('fromObject parses a legacy map extra', () {
      final extra = ProfileSetupExtra.fromObject(
        {'email': 'a@b.com', 'dateOfBirth': '2000-01-01'},
      );
      expect(extra, isNotNull);
      expect(extra!.dateOfBirth, '2000-01-01');
    });

    test('fromObject returns null when dateOfBirth is missing', () {
      expect(ProfileSetupExtra.fromObject({'email': 'a@b.com'}), isNull);
    });

    test('fromObject returns null on a wrong-typed extra', () {
      expect(ProfileSetupExtra.fromObject(3.14), isNull);
    });
  });

  group('AgeGateExtra', () {
    test('fromObject parses a legacy String extra as email', () {
      final extra = AgeGateExtra.fromObject('a@b.com');
      expect(extra, isNotNull);
      expect(extra!.email, 'a@b.com');
    });

    test('fromObject returns null on a wrong-typed extra', () {
      expect(AgeGateExtra.fromObject(42), isNull);
    });

    test('fromObject returns null on an empty String extra', () {
      expect(AgeGateExtra.fromObject(''), isNull);
    });
  });

  group('RouteParams', () {
    test('fromMap returns null for a missing path param', () {
      expect(RouteParams.fromMap(const {}, 'groupId'), isNull);
    });

    test('fromMap returns the param value when present', () {
      expect(RouteParams.fromMap(const {'groupId': 'g1'}, 'groupId'), 'g1');
    });
  });
}
