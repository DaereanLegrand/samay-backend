import 'dart:convert';

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

  group('RouteExtra value equality (U-29)', () {
    test('VerifyExtra is value-equal on both fields', () {
      expect(
        const VerifyExtra(email: 'a@b.com', password: 'x'),
        const VerifyExtra(email: 'a@b.com', password: 'x'),
      );
      expect(
        const VerifyExtra(email: 'a@b.com', password: 'x') ==
            const VerifyExtra(email: 'a@b.com', password: 'y'),
        isFalse,
      );
      expect(
        const VerifyExtra(email: 'a@b.com', password: 'x') ==
            const VerifyExtra(email: 'b@b.com', password: 'x'),
        isFalse,
      );
    });

    test('AgeGateExtra is value-equal on the email', () {
      expect(
        const AgeGateExtra(email: 'a@b.com'),
        const AgeGateExtra(email: 'a@b.com'),
      );
      expect(
        const AgeGateExtra(email: 'a@b.com') ==
            const AgeGateExtra(email: 'b@b.com'),
        isFalse,
      );
    });

    test('PrivacyTermsExtra is value-equal on both fields', () {
      expect(
        const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
      );
      expect(
        const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01') ==
            const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '1999-01-01'),
        isFalse,
      );
    });

    test('ProfileSetupExtra is value-equal on both fields', () {
      expect(
        const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
      );
      expect(
        const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '2000-01-01') ==
            const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '1999-01-01'),
        isFalse,
      );
    });

    test('hashCode follows the fields', () {
      expect(
        const VerifyExtra(email: 'a@b.com', password: 'x').hashCode,
        Object.hash('a@b.com', 'x'),
      );
      expect(const AgeGateExtra(email: 'a@b.com').hashCode, 'a@b.com'.hashCode);
    });
  });

  group('RouteExtraCodec (U-29)', () {
    const codec = RouteExtraCodec();

    test('round-trips each typed extra through JSON with the fields intact', () {
      final cases = <Object?>[
        const VerifyExtra(email: 'a@b.com', password: 'x'),
        const AgeGateExtra(email: 'a@b.com'),
        const PrivacyTermsExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        const ProfileSetupExtra(email: 'a@b.com', dateOfBirth: '2000-01-01'),
      ];
      for (final extra in cases) {
        final encoded = codec.encode(extra);
        // The encoded form must survive go_router's JSON serialization into
        // the engine state (that is the whole point of the codec).
        expect(jsonEncode(encoded), isNot(contains('null')));
        expect(codec.decode(encoded), extra);
      }
    });

    test('decode returns the typed class so router equality holds', () {
      const extra = VerifyExtra(email: 'a@b.com', password: 'x');
      expect(codec.decode(codec.encode(extra)), isA<VerifyExtra>());
      expect(codec.decode(codec.encode(extra)), extra);
    });

    test('passthrough for JSON-able extras (null, String, plain maps)', () {
      expect(codec.decode(codec.encode(null)), isNull);
      const groupName = 'Disco Crew';
      expect(codec.decode(codec.encode(groupName)), groupName);
      final plain = {'foo': 'bar'};
      expect(codec.decode(codec.encode(plain)), plain);
    });
  });
}
