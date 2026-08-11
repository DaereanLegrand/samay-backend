import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/forgot_password_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/auth/screens/welcome_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_breathing_glow.dart';
import 'package:samay/shared/widgets/v_disco_divider.dart';

/// Auth-restyle ledger tests (U-07, DISCO-DESIGN-SYSTEM §3.2/§3.3/§5.1/§5.2).
///
/// Each test pins a *deliberate visual change* from the U-07 ledger — the
/// auth screens are restyled, not redesigned, so the text/l10n assertions of
/// `auth_screens_test.dart` / `auth_interactions_test.dart` stay the contract
/// for behavior and flow; this file only asserts the §5 visual contract:
///
/// 1. Welcome primary CTA is the filled `VButton.glowAccent` (§5.1 brand
///    moment) with the `VDiscoDivider` between the CTAs (U-06 widget).
/// 2. Auth big headers use Playfair Display italic `displayMedium` (§3.2/§3.3)
///    — signup, age_gate, otp, privacy_terms.
/// 3. The OTP field uses the `AppTypography.otpInputText` token (§3.3).
/// 4. Error texts render in `AppColors.error` (glowPink — never raw red on
///    black, §5.2), wired through `VInput.errorText` where it improves the
///    validation UX (login password, signup password/confirm, profile_setup
///    username).
class _RecordingAuthNotifier extends AuthNotifier {
  bool failSignIn = false;
  bool failCreateProfile = false;

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> signIn(String email, String password) async {
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
  Future<String> checkEmail(String email) async => 'signup';

  @override
  Future<void> sendOtp(String email) async {
    state = AsyncData(state.valueOrNull ?? const AuthState());
  }

  @override
  Future<void> createProfile(String username, {String? dateOfBirth}) async {
    if (failCreateProfile) {
      state = AsyncError(
        ValidationError('usuario', 'El nombre de usuario ya existe'),
        StackTrace.current,
      );
      return;
    }
    state = AsyncData(
      (state.valueOrNull ?? const AuthState()).copyWith(hasProfile: true),
    );
  }
}

class _AuthHarness {
  _AuthHarness(this.container, this.router);

  final ProviderContainer container;
  final GoRouter router;
}

/// Pumps [child] (an auth screen) inside the real Samay theme + the recording
/// notifier injected over [authStateProvider]. The Samay theme is essential:
/// the §3.2 headers resolve Playfair + glow through the theme roles, so the
/// assertions only make sense under `SamayTheme.dark` (the app's only theme —
/// `lib/app.dart`).
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
        theme: SamayTheme.dark,
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

/// Asserts [text] renders in the §3.2 auth-header role: Playfair Display
/// italic 700 at 40 with the glow-strong stack behind it.
void _expectPlayfairHeader(Text text, String label) {
  expect(
    text.style?.fontFamily,
    AppTypography.playfair,
    reason: '$label must be Playfair Display (§3.2)',
  );
  expect(
    text.style?.fontSize,
    AppTypography.displayMedium.fontSize,
    reason: '$label must be displayMedium 40px (§3.3)',
  );
  expect(
    text.style?.fontStyle,
    FontStyle.italic,
    reason: '$label must be Playfair italic (§3.1/§3.2)',
  );
  expect(
    text.style?.shadows,
    isNotEmpty,
    reason: '$label must carry the glow stack (§3.4)',
  );
}

void main() {
  group('WelcomeScreen — §5.1 brand-moment CTA (U-07)', () {
    testWidgets('primary CTA is the filled glowAccent (pink fill + black '
        'text)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      final style = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Crear cuenta'))
          .style;
      expect(
        style?.backgroundColor?.resolve({}),
        AppColors.glowPink,
        reason: 'primary CTA must be the pink glowAccent fill (§5.1)',
      );
      expect(
        style?.foregroundColor?.resolve({}),
        AppColors.discoBlack,
        reason: 'pink fill carries black text — 6.00:1 (§2.5 rule 2)',
      );
    });

    testWidgets('secondary CTA stays the outlined white variant', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      final style = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Iniciar sesión'))
          .style;
      expect(style?.backgroundColor?.resolve({}), Colors.transparent);
      expect(
        style?.side?.resolve({}),
        const BorderSide(color: AppColors.white),
      );
    });

    testWidgets('shows the VDiscoDivider between the CTAs (U-06)', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      expect(find.byType(VDiscoDivider), findsOneWidget);
    });

    testWidgets('wordmark stays Playfair displayLarge with the glow (§3.2)', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('VIVE'));
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontSize, AppTypography.displayLarge.fontSize);
      expect(text.style?.fontStyle, FontStyle.italic);
      expect(text.style?.shadows, isNotEmpty);
    });
  });

  group('Auth big headers — Playfair displayMedium (§3.2/§3.3)', () {
    testWidgets('signup header renders Playfair with the glow', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      _expectPlayfairHeader(
        tester.widget<Text>(find.text('Crea tu cuenta')),
        'signup header',
      );
    });

    testWidgets('age_gate header renders Playfair with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const AgeGateScreen(email: 'test@test.com'),
        notifier,
      );
      await tester.pumpAndSettle();

      _expectPlayfairHeader(
        tester.widget<Text>(find.text('¿Cuál es tu fecha de nacimiento?')),
        'age_gate header',
      );
    });

    testWidgets('otp header renders Playfair with the glow', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const OtpVerificationScreen(email: 'a@b.com', password: 'secret1'),
        notifier,
      );
      await tester.pump();

      _expectPlayfairHeader(
        tester.widget<Text>(find.text('Ingresa el código de verificación')),
        'otp header',
      );
      await _unmount(tester);
    });

    testWidgets('privacy_terms header renders Playfair with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();

      _expectPlayfairHeader(
        tester.widget<Text>(find.text('Acepta los términos para continuar')),
        'privacy_terms header',
      );
    });

    testWidgets('forgot-password header renders Playfair with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      _expectPlayfairHeader(
        tester.widget<Text>(find.text('¿Olvidaste tu contraseña?')),
        'forgot-password header',
      );
    });
  });

  group('ForgotPasswordScreen — §5.1 brand-moment CTA (U-14 R3)', () {
    testWidgets('primary CTA is the filled glowAccent (pink fill + black '
        'text)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      final style = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Enviar enlace'))
          .style;
      expect(
        style?.backgroundColor?.resolve({}),
        AppColors.glowPink,
        reason: 'primary CTA must be the pink glowAccent fill (§5.1)',
      );
      expect(
        style?.foregroundColor?.resolve({}),
        AppColors.discoBlack,
        reason: 'pink fill carries black text — 6.00:1 (§2.5 rule 2)',
      );
    });

    testWidgets('the recovery form rides the VInput underline (VInput '
        'errorText for auth errors)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.labelText, 'Correo electrónico');
    });
  });

  group('OTP input — AppTypography.otpInputText (§3.3)', () {
    testWidgets('the code field uses the otpInputText token + white fill', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const OtpVerificationScreen(email: 'a@b.com', password: 'secret1'),
        notifier,
      );
      await tester.pump();

      final style = tester.widget<TextField>(find.byType(TextField)).style;
      expect(
        style?.fontSize,
        AppTypography.otpInputText.fontSize,
        reason: '30px (§3.3 otpInputText)',
      );
      expect(
        style?.letterSpacing,
        AppTypography.otpInputText.letterSpacing,
        reason: '8.0 (§3.3 otpInputText)',
      );
      expect(
        style?.fontWeight,
        AppTypography.otpInputText.fontWeight,
        reason: 'w800 (§3.3 otpInputText)',
      );
      expect(
        style?.color,
        AppColors.white,
        reason: 'code digits stay white on black (§1 P2)',
      );
      await _unmount(tester);
    });
  });

  group('Error texts — AppColors.error, never raw red (§5.2)', () {
    testWidgets('login surfaces the auth error as the password field '
        'errorText in glowPink', (tester) async {
      final notifier = _RecordingAuthNotifier()..failSignIn = true;
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'wrong1');
      await tester.tap(find.widgetWithText(TextButton, 'Iniciar sesión'));
      await tester.pumpAndSettle();

      final passwordField = tester.widget<TextField>(
        find.byType(TextField).at(1),
      );
      expect(
        passwordField.decoration?.errorText,
        'Correo o contraseña inválidos',
        reason: 'field-level errorText (U-07 ledger, handoff 4)',
      );
      expect(
        passwordField.decoration?.errorStyle?.color,
        AppColors.error,
        reason: 'glowPink — §5.2 bans raw Colors.red on black',
      );
    });

    testWidgets('signup shows the password-policy error as the password field '
        'errorText in glowPink', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'abc');
      await tester.enterText(find.byType(TextField).at(2), 'abc');
      await tester.tap(find.widgetWithText(TextButton, 'Crear cuenta'));
      await tester.pump();

      final passwordField = tester.widget<TextField>(
        find.byType(TextField).at(1),
      );
      expect(
        passwordField.decoration?.errorText,
        'La contraseña debe tener al menos 6 caracteres y contener un número.',
      );
      expect(passwordField.decoration?.errorStyle?.color, AppColors.error);
    });

    testWidgets('signup shows the mismatch error as the confirm field '
        'errorText in glowPink', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret1');
      await tester.enterText(find.byType(TextField).at(2), 'different1');
      await tester.tap(find.widgetWithText(TextButton, 'Crear cuenta'));
      await tester.pump();

      final confirmField = tester.widget<TextField>(
        find.byType(TextField).at(2),
      );
      expect(
        confirmField.decoration?.errorText,
        'Las contraseñas no coinciden.',
      );
      expect(confirmField.decoration?.errorStyle?.color, AppColors.error);
    });

    testWidgets('profile_setup surfaces the server error as the username '
        'field errorText in glowPink', (tester) async {
      final notifier = _RecordingAuthNotifier()..failCreateProfile = true;
      await _pump(
        tester,
        const ProfileSetupScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'dana');
      await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
      await tester.pumpAndSettle();

      final usernameField = tester.widget<TextField>(find.byType(TextField));
      expect(
        usernameField.decoration?.errorText,
        'El nombre de usuario ya existe',
      );
      expect(usernameField.decoration?.errorStyle?.color, AppColors.error);
    });

    testWidgets('age_gate underage message renders in glowPink', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const AgeGateScreen(email: 'test@test.com'),
        notifier,
      );
      await tester.pumpAndSettle();

      // Open the M3 date picker, switch to text-entry mode and enter an
      // underage date — the underage message is only rendered after a pick.
      await tester.tap(find.text('Seleccionar fecha'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1/1/2020');
      // es MaterialLocalizations okButtonLabel is uppercase ("ACEPTAR").
      await tester.tap(find.text('ACEPTAR'));
      await tester.pumpAndSettle();

      final message = tester.widget<Text>(
        find.text('Debes tener 18 años para usar Samay'),
      );
      expect(
        message.style?.color,
        AppColors.error,
        reason: 'glowPink — §5.2 bans raw Colors.red on black',
      );
    });
  });

  group('§6.2 breathing auth headers (U-23 — closing U-18\'s flagged gap)',
      () {
    void expectBreathingHeader(String label) {
      final glow = find.byType(VBreathingGlow);
      expect(glow, findsOneWidget,
          reason: '§6.2 — exactly one breathing element per screen');
      expect(
        find.descendant(of: glow, matching: find.text(label)),
        findsOneWidget,
        reason: '$label is the screen\'s breathing auth header',
      );
    }

    testWidgets('signup header is the breathing element', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();
      expectBreathingHeader('Crea tu cuenta');
    });

    testWidgets('age_gate header is the breathing element', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const AgeGateScreen(email: 'test@test.com'),
        notifier,
      );
      await tester.pumpAndSettle();
      expectBreathingHeader('¿Cuál es tu fecha de nacimiento?');
    });

    testWidgets('privacy_terms header is the breathing element', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();
      expectBreathingHeader('Acepta los términos para continuar');
    });

    testWidgets('forgot-password header breathes in the form state', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();
      expectBreathingHeader('¿Olvidaste tu contraseña?');
    });
  });
}
