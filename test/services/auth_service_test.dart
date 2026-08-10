
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
      when(() => auth.signInWithPassword(email: any(named: 'email'), password: any(named: 'password')))
          .thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().signIn('a@b.com', 'secret1');

      verify(() => auth.signInWithPassword(email: 'a@b.com', password: 'secret1'))
          .called(1);
    });

    test('signUp delegates to gotrue signUp', () async {
      when(() => auth.signUp(email: any(named: 'email'), password: any(named: 'password')))
          .thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().signUp('a@b.com', 'secret1');

      verify(() => auth.signUp(email: 'a@b.com', password: 'secret1')).called(1);
    });

    test('sendOtp delegates to signInWithOtp', () async {
      when(() => auth.signInWithOtp(email: any(named: 'email')))
          .thenAnswer((_) async => AuthResponse());

      await service().sendOtp('a@b.com');

      verify(() => auth.signInWithOtp(email: 'a@b.com')).called(1);
    });

    test('verifyOtp delegates with the email OTP type', () async {
      when(() => auth.verifyOTP(
            email: any(named: 'email'),
            token: any(named: 'token'),
            type: any(named: 'type'),
          )).thenAnswer((_) async => AuthResponse(user: _currentUser()));

      await service().verifyOtp('a@b.com', '123456');

      verify(() => auth.verifyOTP(
            email: 'a@b.com',
            token: '123456',
            type: OtpType.email,
          )).called(1);
    });

    test('signOut delegates to gotrue', () async {
      when(() => auth.signOut()).thenAnswer((_) async {});

      await service().signOut();

      verify(() => auth.signOut()).called(1);
    });

    test('updateUser forwards the patch as UserAttributes', () async {
      when(() => auth.updateUser(any())).thenAnswer(
        (_) async => UserResponse.fromJson({'id': _userId}),
      );

      await service().updateUser({
        'password': 'nueva1',
        'data': {'theme': 'dark'},
      });

      final attributes =
          verify(() => auth.updateUser(captureAny())).captured.single;
      expect(attributes, isA<UserAttributes>());
      expect((attributes as UserAttributes).password, 'nueva1');
      expect(attributes.data, {'theme': 'dark'});
    });

    test('propagates an invalid-credentials AuthException from signIn',
        () async {
      when(() => auth.signInWithPassword(
              email: any(named: 'email'), password: any(named: 'password')))
          .thenThrow(const AuthException(
        'Invalid login credentials',
        code: 'invalid_credentials',
      ));

      final err = await captureError(() => service().signIn('a@b.com', 'wrong'));
      expect(err, isA<AuthException>());
      expectMapped(err, ValidationError);
    });
  });

  group('AuthService.softDeleteUser', () {
    test('nulls out the profile and stamps deleted_at', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => users.update(any())).thenAnswer((_) => update);

      await service().softDeleteUser();

      final payload = verify(() => users.update(captureAny()))
          .captured
          .single as Map;
      expect(payload['deleted_at'], isNotEmpty);
      expect(payload['username'], 'deleted_user_$_userId');
      expect(payload['avatar_url'], isNull);
      expect(payload['bio'], isNull);
      expect(update.filters.single.value, _userId);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().softDeleteUser(), throwsA(isA<Exception>()));
    });
  });

  group('AuthService.createUserProfile', () {
    test('inserts the users row with the config grant + ledger + tracker',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => config.getSignupShardGrant()).thenAnswer((_) async => 256);
      final users = MockQueryBuilder();
      final ledger = MockQueryBuilder();
      final tracker = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => client.from('shard_ledger')).thenAnswer((_) => ledger);
      when(() => client.from('signup_tracker')).thenAnswer((_) => tracker);
      when(() => users.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => ledger.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => tracker.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().createUserProfile(
        username: '  Dana  ',
        avatarUrl: 'https://cdn.example/a.png',
        dateOfBirth: '2000-01-01',
      );

      final userPayload =
          verify(() => users.insert(captureAny())).captured.single as Map;
      expect(userPayload['id'], _userId);
      expect(userPayload['username'], 'Dana',
          reason: 'username goes through InputSanitizer.sanitizeUsername');
      expect(userPayload['avatar_url'], 'https://cdn.example/a.png');
      expect(userPayload['date_of_birth'], '2000-01-01');
      expect(userPayload['personal_shards'], 256);
      expect(userPayload['preshards'], 0);
      expect(userPayload['subscription_tier'], 'free');
      expect(userPayload['banned_at'], isNull);
      expect(userPayload['deleted_at'], isNull);

      final ledgerPayload =
          verify(() => ledger.insert(captureAny())).captured.single as Map;
      expect(ledgerPayload['user_id'], _userId);
      expect(ledgerPayload['delta'], 256);
      expect(ledgerPayload['reason'], 'admin_grant');

      verify(() => tracker.upsert(any(), onConflict: any(named: 'onConflict')))
          .called(1);
    });

    test('propagates a duplicate-username PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => config.getSignupShardGrant()).thenAnswer((_) async => 256);
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.insert(any())).thenThrow(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint "users_username_key"',
          code: '23505',
        ),
      );

      final err = await captureError(
        () => service().createUserProfile(username: 'dana'),
      );
      expect(err, isA<PostgrestException>());
      expectMapped(err, ValidationError);
    });
  });

  group('AuthService.userHasProfile', () {
    test('returns false on any check failure (fail-closed helper)', () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select('id')).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      expect(await service().userHasProfile(_userId), isFalse);
    });
  });

  group('AuthService.signup RPC passthroughs (migrated from the facade suite)',
      () {
    test('checkSignupEmail returns the RPC result', () async {
      when(() => client.rpc('check_signup_email',
              params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<String>('signup'));

      expect(await service().checkSignupEmail('nuevo@test.com'), 'signup');
      verify(() => client.rpc('check_signup_email',
              params: {'p_email': 'nuevo@test.com'}))
          .called(1);
    });

    test('upsertSignupTracker upserts the tracker row', () async {
      final tracker = MockQueryBuilder();
      when(() => client.from('signup_tracker')).thenAnswer((_) => tracker);
      when(() => tracker.upsert(any(), onConflict: any(named: 'onConflict')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().upsertSignupTracker('a@test.com', true);

      final payload = verify(() => tracker.upsert(captureAny(),
              onConflict: any(named: 'onConflict')))
          .captured
          .single as Map;
      expect(payload['email'], 'a@test.com');
      expect(payload['profile_created'], isTrue);
    });
  });

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
