import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// AuthService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18).
///
/// The RPC passthrough + fallback cases migrated from the deleted facade
/// suite (I-78: `supabase_service_test.dart` was removed with the
/// `SupabaseService` facade; the checkSignupEmail/upsertSignupTracker/
/// getCurrentUser/refreshSession coverage moved here) and the GoTrue
/// passthroughs (signIn/signUp/OTP/signOut/updateUser), the
/// `softDeleteUser`/`createUserProfile` table shapes and error propagation.
const _userId = '11111111-1111-1111-1111-111111111111';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;
  late MockConfigService config;

  setUpAll(() {
    // mocktail needs concrete values for `any()`/`captureAny()` on non-null
    // parameter types that cannot be synthesized (enums, data classes).
    registerFallbackValue(OtpType.email);
    registerFallbackValue(UserAttributes());
  });

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
    config = MockConfigService();
  });

  AuthService service() => AuthService(client: client, config: config);

  group('AuthService GoTrue passthroughs', () {
    test('signIn delegates to signInWithPassword', () async {
      when(
        () => auth.signInWithPassword(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().signIn('a@b.com', 'secret1');

      verify(
        () => auth.signInWithPassword(email: 'a@b.com', password: 'secret1'),
      ).called(1);
    });

    test('signUp delegates to gotrue signUp', () async {
      when(
        () => auth.signUp(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().signUp('a@b.com', 'secret1');

      verify(
        () => auth.signUp(email: 'a@b.com', password: 'secret1'),
      ).called(1);
    });

    test('sendOtp delegates to signInWithOtp', () async {
      when(
        () => auth.signInWithOtp(email: any(named: 'email')),
      ).thenAnswer((_) async => AuthResponse());

      await service().sendOtp('a@b.com');

      verify(() => auth.signInWithOtp(email: 'a@b.com')).called(1);
    });

    test('verifyOtp delegates with the email OTP type', () async {
      when(
        () => auth.verifyOTP(
          email: any(named: 'email'),
          token: any(named: 'token'),
          type: any(named: 'type'),
        ),
      ).thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().verifyOtp('a@b.com', '123456');

      verify(
        () => auth.verifyOTP(
          email: 'a@b.com',
          token: '123456',
          type: OtpType.email,
        ),
      ).called(1);
    });

    test('signOut delegates to gotrue', () async {
      when(() => auth.signOut()).thenAnswer((_) async {});

      await service().signOut();

      verify(() => auth.signOut()).called(1);
    });

    test('updateUser forwards the patch as UserAttributes', () async {
      when(
        () => auth.updateUser(any()),
      ).thenAnswer((_) async => UserResponse.fromJson({'id': _userId}));

      await service().updateUser({
        'password': 'nueva1',
        'data': {'theme': 'dark'},
      });

      final attributes = verify(
        () => auth.updateUser(captureAny()),
      ).captured.single;
      expect(attributes, isA<UserAttributes>());
      expect((attributes as UserAttributes).password, 'nueva1');
      expect(attributes.data, {'theme': 'dark'});
    });

    test(
      'propagates an invalid-credentials AuthException from signIn',
      () async {
        when(
          () => auth.signInWithPassword(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(
          const AuthException(
            'Invalid login credentials',
            code: 'invalid_credentials',
          ),
        );

        final err = await captureError(
          () => service().signIn('a@b.com', 'wrong'),
        );
        expect(err, isA<AuthException>());
        expectMapped(err, ValidationError);
      },
    );
  });

  group('AuthService.softDeleteUser', () {
    test('delegates to the delete_my_account RPC — no direct table write',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc('delete_my_account'),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().softDeleteUser();

      verify(() => client.rpc('delete_my_account')).called(1);
      verifyNever(() => client.from('users'));
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().softDeleteUser(), throwsA(isA<Exception>()));
    });
  });

  group('AuthService.createUserProfile', () {
    test(
      'delegates to the create_my_profile RPC + tracker(true) — '
      'no direct table writes, no client-side ledger',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        when(
          () => client.rpc(
            'create_my_profile',
            params: any(named: 'params'),
          ),
        ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));
        when(
          () =>
              client.rpc('upsert_signup_tracker', params: any(named: 'params')),
        ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

        await service().createUserProfile(
          username: '  Dana  ',
          dateOfBirth: '2000-01-01',
        );

        final profileParams =
            verify(
              () => client.rpc(
                'create_my_profile',
                params: captureAny(named: 'params'),
              ),
            ).captured.single as Map;
        // The username is sanitized CLIENT-side before the RPC (defense in
        // depth — the RPC sanitizes + validates again server-side).
        expect(profileParams['p_username'], 'Dana');
        expect(profileParams['p_date_of_birth'], '2000-01-01');

        verifyNever(() => client.from('users'));
        verifyNever(() => client.from('shard_ledger'));
        verifyNever(() => config.getSignupShardGrant());

        verify(
          () => client.rpc(
            'upsert_signup_tracker',
            params: {
              'p_email': _currentUser().email,
              'p_profile_created': true,
            },
          ),
        ).called(1);
      },
    );

    test('propagates a duplicate-username PostgrestException from the RPC',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(
        () => client.rpc('create_my_profile', params: any(named: 'params')),
      ).thenThrow(
        const PostgrestException(
          message:
              'duplicate key value violates unique constraint "users_username_key"',
          code: '23505',
        ),
      );

      final err = await captureError(
        () => service().createUserProfile(username: 'dana'),
      );
      expect(err, isA<PostgrestException>());
      expectMapped(err, ValidationError);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().createUserProfile(username: 'dana'),
          throwsA(isA<Exception>()));
    });
  });

  group('AuthService.userHasProfile', () {
    test('propagates check failures (no fail-closed fallback)', () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select('id')).thenThrow(
        const PostgrestException(message: 'connection refused', code: '28000'),
      );

      expect(
        () => service().userHasProfile(_userId),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group(
    'AuthService.signup RPC passthroughs (migrated from the facade suite)',
    () {
      test('checkSignupEmail returns the RPC result', () async {
        when(
          () => client.rpc('check_signup_email', params: any(named: 'params')),
        ).thenAnswer((_) => ResolvingBuilder<String>('signup'));

        expect(await service().checkSignupEmail('nuevo@test.com'), 'signup');
        verify(
          () => client.rpc(
            'check_signup_email',
            params: {'p_email': 'nuevo@test.com'},
          ),
        ).called(1);
      });

      test(
        'upsertSignupTracker writes via the pre-auth SECURITY DEFINER RPC',
        () async {
          when(
            () => client.rpc(
              'upsert_signup_tracker',
              params: any(named: 'params'),
            ),
          ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

          await service().upsertSignupTracker('a@test.com', true);

          verify(
            () => client.rpc(
              'upsert_signup_tracker',
              params: {'p_email': 'a@test.com', 'p_profile_created': true},
            ),
          ).called(1);
        },
      );
    },
  );

  group('AuthService session helpers (migrated from the facade suite)', () {
    test('getCurrentUser returns null when there is no session', () {
      when(() => auth.currentUser).thenReturn(null);

      expect(service().getCurrentUser(), isNull);
    });

    test('refreshSession returns null when there is no session', () async {
      when(() => auth.refreshSession()).thenAnswer((_) async => AuthResponse());

      expect(await service().refreshSession(), isNull);
    });

    test('refreshSession returns the refreshed user on success', () async {
      when(() => auth.refreshSession()).thenAnswer(
        (_) async => AuthResponse(
          session: Session.fromJson({
            'access_token': 't',
            'refresh_token': 'r',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {'id': _userId, 'email': 'a@b.com'},
          }),
        ),
      );

      expect((await service().refreshSession())?['id'], _userId);
    });
  });
}
