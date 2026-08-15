import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/ban_service.dart';
import 'package:samay/core/services/telemetry_service.dart';
import 'package:samay/crypto/e2ee_key_store.dart';
import 'package:samay/crypto/interfaces.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

class _FakeAuthService extends Mock implements AuthService {}

class _FakeBanService extends Mock implements BanService {}

class _FakePrekeyService extends Mock implements E2eePrekeyService {}

const _user = {
  'id': '11111111-1111-1111-1111-111111111111',
  'email': 'a@b.com',
};

/// A fully-stubbed [AuthService] fake: auth stream never emits and the
/// profile probe fails closed (`AuthService.userHasProfile` returns false),
/// so every test is deterministic with zero network.
AuthService _stubbedService() {
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => const Stream.empty());
  when(() => service.userHasProfile(any())).thenAnswer((_) async => false);
  return service;
}

/// Ban gate stub: never banned, so auth proceeds in every existing test
/// (the I-35 ban scenarios live in `test/features/auth/banned_test.dart`).
BanService _stubbedBanService() {
  final service = _FakeBanService();
  when(
    () => service.checkBanStatus(force: any(named: 'force')),
  ).thenAnswer((_) async => BanStatus.notBanned);
  return service;
}

/// [AuthService] stub with a controllable auth-event stream (SEC-04 / H-22
/// token-refresh tests): `getCurrentUser` replays [userSequence] so tests can
/// start authenticated or not, and `refreshSession` fails closed by default
/// (returning null) unless a test overrides it.
AuthService _streamedService(
  StreamController<supabase.AuthState> controller, {
  List<Map<String, dynamic>?> userSequence = const [null],
}) {
  final queue = [...userSequence];
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => controller.stream);
  when(() => service.userHasProfile(any())).thenAnswer((_) async => false);
  when(() => service.refreshSession()).thenAnswer((_) async => null);
  when(() => service.getCurrentUser()).thenAnswer((_) => queue.removeAt(0));
  return service;
}

/// A gotrue [supabase.Session] carrying [user] — minimal but structurally
/// valid for the notifier's `session!.user.toJson()` path.
supabase.Session _session(Map<String, dynamic> user) => supabase.Session(
  accessToken: 'test-access-token',
  tokenType: 'bearer',
  refreshToken: 'test-refresh-token',
  user: supabase.User.fromJson(user)!,
);

/// Lets the notifier's async stream handler (`_onAuthStateChange`) complete.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// Recording fake for the [TelemetrySink] seam (I-68): asserts the notifier
/// emits the `auth_sign_in` event after a successful sign-in.
class _RecordingTelemetrySink implements TelemetrySink {
  final List<String> events = [];

  @override
  void track(String event, Map<String, dynamic> properties) {
    events.add(event);
  }

  @override
  void identify(String userId) {}

  @override
  void reset() {}
}

/// No-op prekey service stub: every auth test is deterministic with zero
/// network. The publish-on-profile-create / heal-on-restore tests override
/// the stubs below and assert the calls (E2EE §12.2 step 4 wiring).
E2eePrekeyService _stubbedPrekeys() {
  final prekeys = _FakePrekeyService();
  when(() => prekeys.publishAll()).thenAnswer((_) async {});
  when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
  when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);
  return prekeys;
}

ProviderContainer _newContainer(
  AuthService service, {
  List<Override> extraOverrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(service),
      banServiceProvider.overrideWithValue(_stubbedBanService()),
      e2eePrekeyServiceProvider.overrideWithValue(_stubbedPrekeys()),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('AuthProvider (AsyncNotifier)', () {
    test('initial state is loading while build is in flight', () {
      final container = _newContainer(_stubbedService());
      final state = container.read(authStateProvider);
      expect(state, isA<AsyncLoading<AuthState>>());
      expect(state.isLoading, isTrue);
    });

    test('initial state is unauthenticated', () async {
      final container = _newContainer(_stubbedService());
      await container.read(authStateProvider.future);
      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isFalse);
    });

    test('initial state is not loading', () async {
      final container = _newContainer(_stubbedService());
      await container.read(authStateProvider.future);
      expect(container.read(authStateProvider).isLoading, isFalse);
    });

    test('initial user is null', () async {
      final container = _newContainer(_stubbedService());
      await container.read(authStateProvider.future);
      expect(container.read(authStateProvider).valueOrNull?.user, isNull);
    });

    test('signIn sets authenticated state with the signed-in user', () async {
      final service = _stubbedService();
      when(() => service.signIn(any(), any())).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');

      final state = container.read(authStateProvider);
      expect(state, isA<AsyncData<AuthState>>());
      expect(state.hasError, isFalse);
      expect(state.valueOrNull?.authenticated, isTrue);
      expect(state.valueOrNull?.user?['id'], _user['id']);
    });

    test(
      'signIn failure surfaces an AsyncError with a user-facing message',
      () async {
        final service = _stubbedService();
        when(() => service.signIn(any(), any())).thenThrow(
          const AuthException(
            'Invalid login credentials',
            code: 'invalid_credentials',
          ),
        );
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signIn('a@b.com', 'wrong1');

        final state = container.read(authStateProvider);
        expect(state, isA<AsyncError<AuthState>>());
        expect(state.hasError, isTrue);
        expect(state.errorMessage, 'Correo o contraseña inválidos');
        expect(state.valueOrNull?.authenticated, isFalse);
      },
    );

    test(
      'signIn reports the auth_sign_in telemetry event on success',
      () async {
        final service = _stubbedService();
        when(() => service.signIn(any(), any())).thenAnswer((_) async {});
        when(() => service.getCurrentUser()).thenReturn(_user);
        final sink = _RecordingTelemetrySink();
        final container = _newContainer(
          service,
          extraOverrides: [
            telemetryServiceProvider.overrideWithValue(
              TelemetryService(
                apiKey: 'phc_test_key',
                host: 'https://posthog.samay.example.com',
                sink: sink,
              ),
            ),
          ],
        );
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signIn('a@b.com', 'secret1');

        expect(sink.events, ['auth_sign_in']);
      },
    );

    test(
      'signIn failure does not report the auth_sign_in telemetry event',
      () async {
        final service = _stubbedService();
        when(() => service.signIn(any(), any())).thenThrow(
          const AuthException(
            'Invalid login credentials',
            code: 'invalid_credentials',
          ),
        );
        final sink = _RecordingTelemetrySink();
        final container = _newContainer(
          service,
          extraOverrides: [
            telemetryServiceProvider.overrideWithValue(
              TelemetryService(apiKey: 'phc_test_key', sink: sink),
            ),
          ],
        );
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signIn('a@b.com', 'wrong1');

        expect(sink.events, isEmpty);
      },
    );

    test('refresh() invalidates and re-runs build()', () async {
      final service = _stubbedService();
      var calls = 0;
      when(() => service.getCurrentUser()).thenAnswer((_) {
        calls++;
        return calls == 1 ? null : _user;
      });
      final container = _newContainer(service);
      await container.read(authStateProvider.future);
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isFalse,
      );

      final seen = <AsyncValue<AuthState>>[];
      final sub = container.listen<AsyncValue<AuthState>>(
        authStateProvider,
        (_, next) => seen.add(next),
      );
      addTearDown(sub.close);

      final notifier = container.read(authStateProvider.notifier);
      await notifier.refresh();
      container.read(authStateProvider);
      await container.read(authStateProvider.future);

      expect(seen.any((s) => s.isLoading), isTrue);
      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isTrue);
      expect(calls, 2);
    });
  });

  group('AuthProvider — token refresh (SEC-04 / H-22)', () {
    test(
      'TOKEN_REFRESHED with a valid session keeps the user authenticated',
      () async {
        final controller = StreamController<supabase.AuthState>();
        addTearDown(controller.close);
        final service = _streamedService(controller);
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        controller.add(
          supabase.AuthState(
            supabase.AuthChangeEvent.tokenRefreshed,
            _session(_user),
          ),
        );
        await _settle();

        final state = container.read(authStateProvider);
        expect(state.hasError, isFalse);
        expect(state.valueOrNull?.authenticated, isTrue);
        expect(state.valueOrNull?.user?['id'], _user['id']);
      },
    );

    test(
      'TOKEN_REFRESHED without a session transitions to unauthenticated',
      () async {
        final controller = StreamController<supabase.AuthState>();
        addTearDown(controller.close);
        final service = _streamedService(controller, userSequence: [_user]);
        final container = _newContainer(service);
        await container.read(authStateProvider.future);
        expect(
          container.read(authStateProvider).valueOrNull?.authenticated,
          isTrue,
        );

        controller.add(
          const supabase.AuthState(
            supabase.AuthChangeEvent.tokenRefreshed,
            null,
          ),
        );
        await _settle();

        final state = container.read(authStateProvider);
        expect(state.hasValue, isTrue);
        expect(state.valueOrNull?.authenticated, isFalse);
        expect(state.valueOrNull?.user, isNull);
      },
    );

    test(
      'refreshSession() success updates the state with the new user',
      () async {
        final controller = StreamController<supabase.AuthState>();
        addTearDown(controller.close);
        final service = _streamedService(controller);
        when(() => service.refreshSession()).thenAnswer((_) async => _user);
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        await container.read(authStateProvider.notifier).refreshSession();

        final state = container.read(authStateProvider);
        expect(state.hasValue, isTrue);
        expect(state.valueOrNull?.authenticated, isTrue);
        expect(state.valueOrNull?.user?['id'], _user['id']);
        verify(() => service.refreshSession()).called(1);
      },
    );

    test('refreshSession() failure transitions to unauthenticated', () async {
      final controller = StreamController<supabase.AuthState>();
      addTearDown(controller.close);
      final service = _streamedService(controller, userSequence: [_user]);
      when(() => service.refreshSession()).thenAnswer((_) async => null);
      final container = _newContainer(service);
      await container.read(authStateProvider.future);
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isTrue,
      );

      await container.read(authStateProvider.notifier).refreshSession();

      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isFalse);
    });
  });

  group('AuthProvider — lifecycle mutations (TST-03/H-16 + TST-05/H-18)', () {
    test('signUp sets the authenticated state with the new user', () async {
      final service = _stubbedService();
      when(() => service.signUp(any(), any())).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signUp('nuevo@b.com', 'secret1');

      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isTrue);
      expect(state.valueOrNull?.user?['id'], _user['id']);
    });

    test(
      'signUp failure surfaces an AsyncError with the mapped message',
      () async {
        final service = _stubbedService();
        when(() => service.signUp(any(), any())).thenThrow(
          const AuthException(
            'A user with this email address has already been registered',
            code: 'user_already_exists',
          ),
        );
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        await container
            .read(authStateProvider.notifier)
            .signUp('nuevo@b.com', 'secret1');

        final state = container.read(authStateProvider);
        expect(state, isA<AsyncError<AuthState>>());
        // user_already_exists is code-mapped to a validation error (error-codes
        // doc), not the old blanket UnauthorizedError.
        expect(state.error, isA<ValidationError>());
        expect(
          (state.error as ValidationError).field,
          'correo',
        );
        expect(state.valueOrNull?.authenticated, isFalse);
      },
    );

    test(
      'sendOtp rate-limit failure maps to RateLimitError and rethrows',
      () async {
        final service = _stubbedService();
        when(() => service.sendOtp(any())).thenThrow(
          const AuthException(
            'rate limited',
            code: 'over_email_send_rate_limit',
          ),
        );
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        // The notifier rethrows the RAW exception (screens map it themselves
        // via Object.toAppError — see SignupContactScreen._signup) so the
        // funnel never navigates past a failed sendOtp.
        await expectLater(
          container.read(authStateProvider.notifier).sendOtp('a@b.com'),
          throwsA(isA<AuthException>()),
        );

        final state = container.read(authStateProvider);
        expect(state, isA<AsyncError<AuthState>>());
        expect(state.error, isA<RateLimitError>());
        expect(
          state.errorMessage,
          'Demasiadas solicitudes. Espera un momento.',
        );
      },
    );

    test(
      'sendOtp rethrows when the pre-OTP signup_tracker write fails',
      () async {
        final service = _stubbedService();
        when(() => service.sendOtp(any())).thenAnswer((_) async {});
        when(() => service.upsertSignupTracker(any(), any())).thenThrow(
          const PostgrestException(
            message: 'permission denied for table signup_tracker',
            code: '42501',
          ),
        );
        final container = _newContainer(service);
        await container.read(authStateProvider.future);

        await expectLater(
          container.read(authStateProvider.notifier).sendOtp('a@b.com'),
          throwsA(isA<PostgrestException>()),
        );

        // The funnel must NOT navigate: the OTP screen never renders the stale
        // "No tienes permiso para realizar esta acción." under the code input.
        final state = container.read(authStateProvider);
        expect(state.error, isA<PermissionError>());
      },
    );

    test('sendOtp succeeds without changing the auth state', () async {
      final service = _stubbedService();
      when(() => service.sendOtp(any())).thenAnswer((_) async {});
      when(
        () => service.upsertSignupTracker(any(), any()),
      ).thenAnswer((_) async {});
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container.read(authStateProvider.notifier).sendOtp('a@b.com');

      final state = container.read(authStateProvider);
      expect(state.hasError, isFalse);
      expect(state.valueOrNull?.authenticated, isFalse);
      verify(() => service.upsertSignupTracker('a@b.com', false)).called(1);
    });

    test('verifyOtp failure maps the error and signs out', () async {
      final service = _stubbedService();
      when(
        () => service.verifyOtp(any(), any()),
      ).thenThrow(const AuthException('OTP has expired', code: 'otp_expired'));
      when(() => service.signOut()).thenAnswer((_) async {});
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .verifyOtp('a@b.com', '000000');

      final state = container.read(authStateProvider);
      expect(state, isA<AsyncError<AuthState>>());
      expect(state.error, isA<ValidationError>());
      verify(() => service.signOut()).called(1);
    });

    test('createProfile failure surfaces an AsyncError', () async {
      final service = _stubbedService();
      when(
        () => service.createUserProfile(
          username: any(named: 'username'),
          dateOfBirth: any(named: 'dateOfBirth'),
        ),
      ).thenThrow(
        const PostgrestException(
          message: 'permission denied for table users',
          code: '42501',
        ),
      );
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container.read(authStateProvider.notifier).createProfile('dana');

      final state = container.read(authStateProvider);
      expect(state, isA<AsyncError<AuthState>>());
      expect(state.error, isA<PermissionError>());
      expect(
        state.errorMessage,
        'No tienes permiso para realizar esta acción.',
      );
    });

    test('createProfile success flips hasProfile', () async {
      final service = _stubbedService();
      when(
        () => service.createUserProfile(
          username: any(named: 'username'),
          dateOfBirth: any(named: 'dateOfBirth'),
        ),
      ).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');
      await container.read(authStateProvider.notifier).createProfile('dana');

      final state = container.read(authStateProvider);
      expect(state.hasError, isFalse);
      expect(state.valueOrNull?.hasProfile, isTrue);
      expect(state.valueOrNull?.authenticated, isTrue);
    });

    test('createProfile publishes the E2EE prekey bundle after the profile '
        'row (E2EE §12.2 step 4)', () async {
      final service = _stubbedService();
      when(
        () => service.createUserProfile(
          username: any(named: 'username'),
          dateOfBirth: any(named: 'dateOfBirth'),
        ),
      ).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      final prekeys = _FakePrekeyService();
      when(() => prekeys.publishAll()).thenAnswer((_) async {});
      when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
      when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);
      final container = _newContainer(service, extraOverrides: [
        e2eePrekeyServiceProvider.overrideWithValue(prekeys),
      ]);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');
      await container.read(authStateProvider.notifier).createProfile('dana');

      verify(() => prekeys.publishAll()).called(1);
      expect(
        container.read(authStateProvider).valueOrNull?.hasProfile,
        isTrue,
      );
    });

    test('createProfile key-publish failure does not fail the profile '
        '(best-effort; heal retries on next restore)', () async {
      final service = _stubbedService();
      when(
        () => service.createUserProfile(
          username: any(named: 'username'),
          dateOfBirth: any(named: 'dateOfBirth'),
        ),
      ).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      final prekeys = _FakePrekeyService();
      when(() => prekeys.publishAll()).thenThrow(
        const PostgrestException(message: 'connection refused', code: '28000'),
      );
      when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
      when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);
      final container = _newContainer(service, extraOverrides: [
        e2eePrekeyServiceProvider.overrideWithValue(prekeys),
      ]);
      await container.read(authStateProvider.future);

      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');
      await container.read(authStateProvider.notifier).createProfile('dana');

      final state = container.read(authStateProvider);
      expect(state.hasError, isFalse);
      expect(state.valueOrNull?.hasProfile, isTrue);
    });

    test('session restore heals a legacy account: handleMissingSession is '
        'called when the bundle may be missing (E2EE §12.2 step 4)', () async {
      final prekeys = _FakePrekeyService();
      when(() => prekeys.publishAll()).thenAnswer((_) async {});
      when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
      when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);
      final controller = StreamController<supabase.AuthState>();
      final service = _streamedService(
        controller,
        userSequence: [_user],
      );
      final container = _newContainer(service, extraOverrides: [
        e2eePrekeyServiceProvider.overrideWithValue(prekeys),
      ]);
      await container.read(authStateProvider.future);

      verify(() => prekeys.handleMissingSession()).called(1);
      verifyNever(() => prekeys.publishAll());
    });

    test('restore key-heal failure never breaks auth (logged, stays put)',
        () async {
      final prekeys = _FakePrekeyService();
      when(() => prekeys.publishAll()).thenAnswer((_) async {});
      when(() => prekeys.handleMissingSession()).thenThrow(
        const PostgrestException(message: 'connection refused', code: '28000'),
      );
      when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);
      final controller = StreamController<supabase.AuthState>();
      final service = _streamedService(
        controller,
        userSequence: [_user],
      );
      final container = _newContainer(service, extraOverrides: [
        e2eePrekeyServiceProvider.overrideWithValue(prekeys),
      ]);
      await container.read(authStateProvider.future);

      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isTrue);
    });

    test('signOut clears the session state', () async {
      final service = _stubbedService();
      when(() => service.signIn(any(), any())).thenAnswer((_) async {});
      when(() => service.getCurrentUser()).thenReturn(_user);
      when(() => service.signOut()).thenAnswer((_) async {});
      final container = _newContainer(service);
      await container.read(authStateProvider.future);
      await container
          .read(authStateProvider.notifier)
          .signIn('a@b.com', 'secret1');
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isTrue,
      );

      await container.read(authStateProvider.notifier).signOut();

      final state = container.read(authStateProvider);
      expect(state.hasValue, isTrue);
      expect(state.valueOrNull?.authenticated, isFalse);
      expect(state.valueOrNull?.user, isNull);
      verify(() => service.signOut()).called(1);
    });

    test('deleteAccount soft-deletes the user and signs out', () async {
      final service = _stubbedService();
      when(() => service.softDeleteUser()).thenAnswer((_) async {});
      when(() => service.signOut()).thenAnswer((_) async {});
      final container = _newContainer(service);
      await container.read(authStateProvider.future);

      await container.read(authStateProvider.notifier).deleteAccount();

      verify(() => service.softDeleteUser()).called(1);
      verify(() => service.signOut()).called(1);
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isFalse,
      );
    });

    test('signOut KEEPS E2EE key + session material (Signal model §7.6 — '
        'the identity is bound to the account, not the session)', () async {
      final service = _stubbedService();
      when(() => service.signOut()).thenAnswer((_) async {});
      final keys = MemoryE2eeKeyStore();
      final identityBefore = await keys.loadOrCreateIdentity();
      await keys.currentSignedPrekey();
      await keys.generateOneTimePrekeys(2);
      final sessions = MemoryE2eeSessionStore();
      await sessions.saveSession('chat-1', '{"version":1,"peer":"x"}');

      final container = _newContainer(service, extraOverrides: [
        e2eeKeyStoreProvider.overrideWithValue(keys),
        e2eeSessionStoreProvider.overrideWithValue(sessions),
      ]);
      await container.read(authStateProvider.future);

      await container.read(authStateProvider.notifier).signOut();

      // The identity, prekeys and sessions SURVIVE a plain sign-out — a
      // same-account re-sign-in decrypts old chats without re-key.
      final identityAfter = await keys.loadOrCreateIdentity();
      expect(identityAfter.ikDhPublic, identityBefore.ikDhPublic,
          reason: 'sign-out must not regenerate the identity (Signal model)');
      expect(await keys.oneTimePrekeyCount(), 2);
      expect(await keys.loadSignedPrekeyPrivate(0), isNotNull);
      expect(await sessions.loadSession('chat-1'), isNotNull);
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isFalse,
      );
    });

    test('an ACCOUNT SWITCH wipes the previous account\'s E2EE material '
        '(Signal model — keys are per-account)', () async {
      const userB = {
        'id': '22222222-2222-2222-2222-222222222222',
        'email': 'c@d.com',
      };
      final controller = StreamController<supabase.AuthState>();
      final service = _streamedService(controller, userSequence: [null]);
      final keys = MemoryE2eeKeyStore();
      await keys.loadOrCreateIdentity();
      await keys.currentSignedPrekey();
      await keys.generateOneTimePrekeys(2);
      final sessions = MemoryE2eeSessionStore();
      await sessions.saveSession('chat-1', '{"version":1,"peer":"x"}');
      final prekeys = _FakePrekeyService();
      when(() => prekeys.publishAll()).thenAnswer((_) async {});
      when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
      when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);

      final container = _newContainer(service, extraOverrides: [
        e2eeKeyStoreProvider.overrideWithValue(keys),
        e2eeSessionStoreProvider.overrideWithValue(sessions),
        e2eePrekeyServiceProvider.overrideWithValue(prekeys),
      ]);
      await container.read(authStateProvider.future);

      // Account A signs in → claims ownership of the key material.
      controller.add(
        supabase.AuthState(
          supabase.AuthChangeEvent.signedIn,
          _session(_user),
        ),
      );
      await _settle();
      expect(await keys.ownerUid(), _user['id']);

      // Sign out (material SURVIVES — the Signal model), then account B
      // signs in → the A-material is wiped and B claims ownership.
      controller.add(
        const supabase.AuthState(
          supabase.AuthChangeEvent.signedOut,
          null,
        ),
      );
      await _settle();
      expect(await keys.ownerUid(), _user['id'],
          reason: 'a plain sign-out keeps the material');

      controller.add(
        supabase.AuthState(
          supabase.AuthChangeEvent.signedIn,
          _session(userB),
        ),
      );
      await _settle();

      expect(await keys.oneTimePrekeyCount(), 0,
          reason: 'account switch must wipe the previous keys');
      expect(await sessions.loadSession('chat-1'), isNull,
          reason: 'account switch must wipe the previous sessions');
      expect(await keys.ownerUid(), userB['id']);
    });

    test('deleteAccount wipes E2EE key + session material (E2EE §7.6)', () async {
      final service = _stubbedService();
      when(() => service.softDeleteUser()).thenAnswer((_) async {});
      when(() => service.signOut()).thenAnswer((_) async {});
      final keys = MemoryE2eeKeyStore();
      await keys.loadOrCreateIdentity();
      await keys.currentSignedPrekey();
      final sessions = MemoryE2eeSessionStore();
      await sessions.saveSession('chat-1', '{"version":1,"peer":"x"}');

      final container = _newContainer(service, extraOverrides: [
        e2eeKeyStoreProvider.overrideWithValue(keys),
        e2eeSessionStoreProvider.overrideWithValue(sessions),
      ]);
      await container.read(authStateProvider.future);

      await container.read(authStateProvider.notifier).deleteAccount();

      expect(await keys.oneTimePrekeyCount(), 0);
      expect(await keys.loadSignedPrekeyPrivate(0), isNull);
      expect(await sessions.loadSession('chat-1'), isNull);
      expect(
        container.read(authStateProvider).valueOrNull?.authenticated,
        isFalse,
      );
    });

    test('checkEmail passes through the service verdict', () async {
      final service = _stubbedService();
      when(
        () => service.checkSignupEmail(any()),
      ).thenAnswer((_) async => 'exists');
      final container = _newContainer(service);

      expect(
        await container.read(authStateProvider.notifier).checkEmail('a@b.com'),
        'exists',
      );
    });

    test('checkEmail propagates the error when the probe throws '
        '(no fallback to signup)', () async {
      final service = _stubbedService();
      when(() => service.checkSignupEmail(any())).thenThrow(
        const PostgrestException(message: 'connection refused', code: '28000'),
      );
      final container = _newContainer(service);

      expect(
        () => container.read(authStateProvider.notifier).checkEmail('a@b.com'),
        throwsA(isA<PostgrestException>()),
      );
    });
  });
}
