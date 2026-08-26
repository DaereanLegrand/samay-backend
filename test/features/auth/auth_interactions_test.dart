import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/forgot_password_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// Deterministic auth notifier for the auth-screen interaction tests (I-45,
/// TST-07/M-14): records every `signIn`/`checkEmail`/`sendOtp`/`createProfile`
/// call and can be switched into failure mode. Injected via
/// `authStateProvider.overrideWith`, so no Supabase/network is ever touched.
class _RecordingAuthNotifier extends AuthNotifier {
  final List<(String, String)> signInCalls = [];
  final List<String> checkEmailCalls = [];
  final List<String> sendOtpCalls = [];
  final List<String> resetPasswordCalls = [];
  final List<(String, String?)> createProfileCalls = [];

  /// When true, `signIn` resolves to an [AsyncError] with the invalid
  /// credentials message — the login error path under test.
  bool failSignIn = false;

  /// When true, `resetPasswordForEmail` resolves to an [AsyncError] — the
  /// forgot-password error path under test.
  bool failResetPassword = false;

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
  Future<void> resetPasswordForEmail(String email) async {
    resetPasswordCalls.add(email);
    if (failResetPassword) {
      state = AsyncError(
        ValidationError('correo', 'No se pudo enviar el enlace'),
        StackTrace.current,
      );
      return;
    }
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
        path: RoutePaths.forgotPassword,
        builder: (_, _) => const ForgotPasswordScreen(),
      ),
      GoRoute(path: RoutePaths.login, builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: RoutePaths.mainFeed,
        builder: (_, _) => const Scaffold(body: Text('main-feed-marker')),
      ),
      GoRoute(
        path: RoutePaths.privacyTerms,
        builder: (_, _) => const Scaffold(body: Text('privacy-marker')),
      ),
      GoRoute(
        path: RoutePaths.profileSetup,
        builder: (_, _) => const Scaffold(body: Text('setup-marker')),
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
      'with the values and navigates to the feed',
      (tester) async {
        final notifier = _RecordingAuthNotifier();
        await _pump(tester, const LoginScreen(), notifier);
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
        await tester.enterText(find.byType(TextField).at(1), 'secret12');
        await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
        await tester.pumpAndSettle();

        expect(notifier.signInCalls, [('a@b.com', 'secret12')]);
        expect(find.text('main-feed-marker'), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing);
      },
    );

    testWidgets('empty fields do not fire signIn', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(notifier.signInCalls, isEmpty);
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('whitespace-only password does not fire signIn (I-73 '
        'requiredValidator trim-empty)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), '   ');
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
      await tester.enterText(find.byType(TextField).at(1), 'wrong12');
      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(notifier.signInCalls, [('a@b.com', 'wrong12')]);
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
      await tester.enterText(find.byType(TextField).at(1), 'secret12');
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
          'La contraseña debe tener al menos 8 caracteres y contener un número.',
        ),
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
      await tester.enterText(find.byType(TextField).at(1), 'secret12');
      await tester.enterText(find.byType(TextField).at(2), 'secret12');
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
    testWidgets('empty username: no createProfile call and no navigation', (
      tester,
    ) async {
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

      // 'sofia' satisfies the username policy (min 5 graphemes) so the save
      // path reaches createProfile.
      await tester.enterText(find.byType(TextField), '  sofia  ');
      await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
      await tester.pumpAndSettle();

      expect(notifier.createProfileCalls, [('sofia', '2000-01-15')]);
      expect(find.text('main-feed-marker'), findsOneWidget);
    });
  });

  group('ForgotPasswordScreen — flow (U-14 R3)', () {
    testWidgets('login "Olvidé mi contraseña" navigates to the dedicated '
        'screen instead of calling reset inline', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Olvidé mi contraseña'));
      await tester.pumpAndSettle();

      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(notifier.resetPasswordCalls, isEmpty);
    });

    testWidgets('empty email does not fire resetPasswordForEmail', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Enviar enlace'));
      await tester.pumpAndSettle();

      expect(notifier.resetPasswordCalls, isEmpty);
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(find.text('REVISA TU CORREO'), findsNothing);
    });

    testWidgets('invalid email shape does not fire resetPasswordForEmail', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.widgetWithText(TextButton, 'Enviar enlace'));
      await tester.pumpAndSettle();

      expect(notifier.resetPasswordCalls, isEmpty);
      expect(
        find.text('Ingresa un correo electrónico válido.'),
        findsOneWidget,
      );
    });

    testWidgets('email → send → confirmation: the form is swapped for the '
        'success state and the snackbar appears', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a@b.com');
      await tester.tap(find.widgetWithText(TextButton, 'Enviar enlace'));
      // LUXE v2: looping display animations keep pumpAndSettle pumping past
      // the snackbar's 4s auto-dismiss — pump the async send and the snackbar
      // entrance deterministically instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(notifier.resetPasswordCalls, ['a@b.com']);
      // F14 in-place success: the form morphs into the confirmation, no route.
      expect(find.text('REVISA TU CORREO'), findsOneWidget);
      expect(
        find.text('Te enviamos un enlace para restablecer tu contraseña'),
        findsOneWidget,
        reason: 'floating snackbar on send (F7)',
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    });

    testWidgets('"Volver a iniciar sesión" from the success state returns to '
        'login', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a@b.com');
      await tester.tap(find.widgetWithText(TextButton, 'Enviar enlace'));
      await tester.pumpAndSettle();
      expect(find.text('REVISA TU CORREO'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(TextButton, 'Volver a iniciar sesión'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ForgotPasswordScreen), findsNothing);
    });

    testWidgets('failed send surfaces the error inline and keeps the form', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier()..failResetPassword = true;
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a@b.com');
      await tester.tap(find.widgetWithText(TextButton, 'Enviar enlace'));
      await tester.pumpAndSettle();

      expect(notifier.resetPasswordCalls, ['a@b.com']);
      expect(find.text('No se pudo enviar el enlace'), findsOneWidget);
      expect(find.text('REVISA TU CORREO'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.text('Te enviamos un enlace para restablecer tu contraseña'),
        findsNothing,
      );
    });
  });

  group('AgeGateScreen — legal-funnel interactions (U-14 R5 keep)', () {
    /// Opens the date picker and picks [year] from the year grid (the
    /// year-toggle + es Material "ACEPTAR" confirm; picked via plain texts).
    Future<void> pickDobYear(WidgetTester tester, String year) async {
      await tester.tap(find.text('Seleccionar fecha'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(RegExp(r'\d{4}')));
      await tester.pumpAndSettle();
      final yearFinder = find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text(year),
      );
      await tester.ensureVisible(yearFinder);
      await tester.pumpAndSettle();
      await tester.tap(yearFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ACEPTAR'));
      await tester.pumpAndSettle();
    }

    testWidgets('an underage birth date shows the §5.2 error and keeps '
        'Continuar disabled', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const AgeGateScreen(email: 'a@b.com'), notifier);
      await tester.pumpAndSettle();

      TextButton continueButton() => tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Continuar'),
      );
      expect(
        continueButton().onPressed,
        isNull,
        reason: 'no birth date → Continuar stays disabled',
      );

      await pickDobYear(tester, '2014');
      expect(
        find.text('Debes tener 18 años para usar Samay'),
        findsOneWidget,
        reason: 'the underage message is the legal-funnel gate (glowPink)',
      );
      expect(continueButton().onPressed, isNull);
    });

    testWidgets('an adult birth date enables Continuar, which pushes the '
        'privacy-terms screen with the extras', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const AgeGateScreen(email: 'a@b.com'), notifier);
      await tester.pumpAndSettle();

      await pickDobYear(tester, '2000');
      expect(
        find.textContaining('2000'),
        findsOneWidget,
        reason: 'the picker button renders the selected DOB (dd/mm/yyyy)',
      );
      final continueButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Continuar'),
      );
      expect(continueButton.onPressed, isNotNull);

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();

      expect(
        find.text('privacy-marker'),
        findsOneWidget,
        reason: 'the age gate hands off to the legal funnel (U-14 R5)',
      );
    });
  });

  group('PrivacyTermsScreen — consent interactions (U-14 R5 keep)', () {
    testWidgets('"Crear cuenta" stays disabled until BOTH consents are '
        'ticked, then navigates to profile setup', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-01'),
        notifier,
      );
      await tester.pumpAndSettle();

      TextButton cta() => tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Crear cuenta'),
      );
      expect(
        cta().onPressed,
        isNull,
        reason: 'no consent → the account-creation CTA is disabled',
      );

      await tester.tap(find.text('Crear cuenta'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        find.text('setup-marker'),
        findsNothing,
        reason: 'tapping the disabled CTA does nothing (U-23 F4 class)',
      );

      await tester.tap(find.text('Acepto la Política de Privacidad'));
      await tester.pump();
      expect(
        cta().onPressed,
        isNull,
        reason: 'one of two consents is not enough',
      );

      await tester.tap(find.text('Acepto los Términos de Servicio'));
      await tester.pump();
      expect(
        cta().onPressed,
        isNotNull,
        reason: 'both consents → the legal funnel CTA unlocks',
      );

      await tester.tap(find.text('Crear cuenta'));
      await tester.pumpAndSettle();

      expect(
        find.text('setup-marker'),
        findsOneWidget,
        reason: 'the legal funnel hands off to profile setup (U-14 R5)',
      );
    });
  });
}
