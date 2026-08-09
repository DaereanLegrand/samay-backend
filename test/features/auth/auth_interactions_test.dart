import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/login_screen.dart';
import 'package:samay/features/auth/otp_verification_screen.dart';
import 'package:samay/features/auth/profile_setup_screen.dart';
import 'package:samay/features/auth/signup_contact_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// Deterministic auth notifier for the auth-screen interaction tests (I-45,
/// TST-07/M-14): records every `signIn`/`checkEmail`/`sendOtp`/`createProfile`
/// call and can be switched into failure mode. Injected via
/// `authStateProvider.overrideWith`, so no Supabase/network is ever touched.
class _RecordingAuthNotifier extends AuthNotifier {
  final List<(String, String)> signInCalls = [];
  final List<String> checkEmailCalls = [];
  final List<String> sendOtpCalls = [];
  final List<(String, String?)> createProfileCalls = [];

  /// When true, `signIn` resolves to an [AsyncError] with the invalid
  /// credentials message — the login error path under test.
  bool failSignIn = false;

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> signIn(String email, String password) async {
    signInCalls.add((email, password));
    if (failSignIn) {
      state = AsyncError(
        ValidationError('credenciales', 'Correo o contraseña inválidos'),
        StackTrace.current,
      );
      return;
    }
    state = const AsyncData(AuthState(authenticated: true, hasProfile: true));
  }

  @override
  Future<String> checkEmail(String email) async {
    checkEmailCalls.add(email);
    return 'signup';
  }

  @override
  Future<void> sendOtp(String email) async {
    sendOtpCalls.add(email);
    state = AsyncData(state.valueOrNull ?? const AuthState());
  }

  @override
  Future<void> createProfile(String username, {String? dateOfBirth}) async {
    createProfileCalls.add((username, dateOfBirth));
    final current = state.valueOrNull ?? const AuthState();
    state = AsyncData(current.copyWith(hasProfile: true));
  }
}

class _AuthHarness {
  _AuthHarness(this.container, this.router);

  final ProviderContainer container;
  final GoRouter router;
}

/// Pumps [child] (an auth screen) inside a router with the routes the screens
/// navigate to, and the recording notifier injected over [authStateProvider].
Future<_AuthHarness> _pump(
  WidgetTester tester,
  Widget child,
  _RecordingAuthNotifier notifier,
) async {
  final container = ProviderContainer(
    overrides: [authStateProvider.overrideWith(() => notifier)],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, _) => child),
      GoRoute(
        path: RoutePaths.verify,
        builder: (_, state) {
          final extra = VerifyExtra.fromState(state);
          return OtpVerificationScreen(
            email: extra?.email ?? '',
            password: extra?.password ?? '',
          );
        },
      ),
      GoRoute(
        path: RoutePaths.mainFeed,
        builder: (_, _) => const Scaffold(body: Text('main-feed-marker')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  return _AuthHarness(container, router);
}

/// Unmounts the tree so the OTP screen's 1s countdown timer is cancelled by
/// `dispose` — keeps `testWidgets` free of pending-timer failures.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  group('LoginScreen — interactions (TST-07/M-14)', () {
    testWidgets(
        'enterText email+password then tap "Iniciar sesión" calls signIn '
        'with the values and navigates to the feed', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret1');
      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(notifier.signInCalls, [('a@b.com', 'secret1')]);
      expect(find.text('main-feed-marker'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('empty fields do not fire signIn', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(notifier.signInCalls, isEmpty);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('failed signIn surfaces the AsyncError message inline and in '
        'the blocking dialog, staying on the screen', (tester) async {
      final notifier = _RecordingAuthNotifier()..failSignIn = true;
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'wrong1');
      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(notifier.signInCalls, [('a@b.com', 'wrong1')]);
      // Inline red text (auth.hasError) + the blocking dialog body.
      expect(find.text('Correo o contraseña inválidos'), findsWidgets);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('main-feed-marker'), findsNothing);
    });
  });

  group('SignupContactScreen — interactions (TST-07/M-14)', () {
    testWidgets('mismatching passwords show the validation message and never '
        'call checkEmail', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret1');
      await tester.enterText(find.byType(TextField).at(2), 'different1');
      await tester.tap(find.widgetWithText(TextButton, 'Crear cuenta'));
      await tester.pump();

      expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);
      expect(notifier.checkEmailCalls, isEmpty);
      expect(notifier.sendOtpCalls, isEmpty);
    });

    testWidgets('weak passwords show the strength message and never call '
        'checkEmail', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'abc');
      await tester.enterText(find.byType(TextField).at(2), 'abc');
      await tester.tap(find.widgetWithText(TextButton, 'Crear cuenta'));
      await tester.pump();

      expect(
        find.text(
            'La contraseña debe tener al menos 6 caracteres y contener un número.'),
        findsOneWidget,
      );
      expect(notifier.checkEmailCalls, isEmpty);
    });

    testWidgets('valid credentials call checkEmail + sendOtp and navigate to '
        'the OTP verification screen', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret1');
      await tester.enterText(find.byType(TextField).at(2), 'secret1');
      await tester.tap(find.widgetWithText(TextButton, 'Crear cuenta'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(notifier.checkEmailCalls, ['a@b.com']);
      expect(notifier.sendOtpCalls, ['a@b.com']);
      expect(find.byType(OtpVerificationScreen), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('ProfileSetupScreen — interactions (TST-07/M-14)', () {
    testWidgets('empty username: no createProfile call and no navigation',
        (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const ProfileSetupScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(notifier.createProfileCalls, isEmpty);
      expect(find.byType(ProfileSetupScreen), findsOneWidget);
      expect(find.text('main-feed-marker'), findsNothing);
    });

    testWidgets('saving a username calls createProfile with the sanitized '
        'values and navigates to the feed on success', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const ProfileSetupScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  dana  ');
      await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(notifier.createProfileCalls, [('dana', '2000-01-15')]);
      expect(find.text('main-feed-marker'), findsOneWidget);
    });
  });
}
