import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
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
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_disco_divider.dart';
import 'package:samay/shared/widgets/v_display_text.dart';

/// Auth-restyle ledger tests (U-07, DESIGN.md §3.2/§3.3/§5.1/§5.2,
/// LUXE v2 the LUXE restyle pass (historical) "Gradient family → screen map").
///
/// Each test pins a *deliberate visual change* from the U-07 ledger + the
/// LUXE v2 overhaul — the auth screens are restyled, not redesigned, so the
/// text/l10n assertions of `auth_screens_test.dart` /
/// `auth_interactions_test.dart` stay the contract for behavior and flow;
/// this file only asserts the §5 visual contract:
///
/// 1. Welcome primary CTA is the filled `VButton.glowAccent` (§5.1 brand
///    moment) carrying the **violet** welcome family gradient (NO pink mains
///    — 2026-08-12 directive); the secondary "Iniciar sesión" entry is a
///    plain muted text link (the login-screen secondary pattern) — the
///    VDiscoDivider is gone (XL-19: redundant ornament on a brand screen).
/// 2. Auth big headers render through the LUXE `VDisplayText` hero — Playfair
///    bold (no italics — user directive 2026-08-14), ALWAYS UPPERCASE,
///    family gradient fill (cyan-family screens render white glyphs — user
///    directive 2026-08-14) + slow pulsing glow — one hero per screen
///    (§3.2/§3.3, directive #6/#8).
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

/// Asserts [label] renders through the LUXE v2 auth-header role: the screen's
/// one [VDisplayText] hero — Playfair Display italic bold, ALWAYS UPPERCASE,
/// with the [family] gradient fill and the pulsing halo (§3.2/§3.3, LUXE
/// directive #6/#8).
void _expectDisplayHeader(
  WidgetTester tester,
  String label,
  AppGradient family,
) {
  final display = tester.widget<VDisplayText>(find.byType(VDisplayText));
  expect(
    display.text,
    label,
    reason: '$label must be the VDisplayText hero (one per screen)',
  );
  expect(
    display.gradient,
    family,
    reason: '$label must carry the screen\'s $family gradient family',
  );
  final glyph = tester.widget<Text>(find.text(label.toUpperCase()));
  expect(
    glyph.style?.fontFamily,
    AppTypography.playfair,
    reason: '$label must be Playfair Display (§3.2)',
  );
  expect(
    glyph.style?.fontSize,
    AppTypography.displayMedium.fontSize,
    reason: '$label must be displayMedium 40px (§3.3)',
  );
  expect(
    glyph.style?.fontStyle,
    isNull,
    reason: '$label must be Playfair non-italic (user directive 2026-08-14)',
  );
}

/// Asserts the LUXE brand-moment CTA: the filled `glowAccent` carrying the
/// screen's [family] gradient (NO pink mains — 2026-08-12 directive) with
/// black text (6.00:1 against the pastel-first fill).
void _expectFilledGlowAccent(
  WidgetTester tester,
  String label,
  AppGradient family,
) {
  final button = tester.widget<VButton>(find.widgetWithText(VButton, label));
  expect(
    button.variant,
    VButtonVariant.glow,
    reason: '$label is the glowAccent variant (§5.1)',
  );
  expect(
    button.filled,
    isTrue,
    reason: '$label is the filled brand-moment CTA (§5.1)',
  );
  expect(
    button.gradient,
    family,
    reason: '$label must carry the screen\'s $family gradient — never pink',
  );
  final style = tester
      .widget<TextButton>(find.widgetWithText(TextButton, label))
      .style;
  expect(
    style?.foregroundColor?.resolve({}),
    AppColors.discoBlack,
    reason: '$label fill carries black text — 6.00:1 (§2.5 rule 2)',
  );
}

void main() {
  group('WelcomeScreen — §5.1 brand-moment CTA (U-07, LUXE v2)', () {
    testWidgets('primary CTA is the filled glowAccent with the violet '
        'welcome family (no pink)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      _expectFilledGlowAccent(
        tester,
        'Crear cuenta',
        AppGradients.familyOf('welcome'),
      );
    });

    testWidgets('secondary CTA is a plain muted text link (login-screen '
        'pattern)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Iniciar sesión'),
      );
      expect(
        button.style?.backgroundColor?.resolve({}),
        isNull,
        reason: 'no background — a plain text link, not a bordered button',
      );
      expect(
        button.style?.side?.resolve({}),
        null,
        reason:
            'XL-19: no border — the secondary entry demotes to a '
            'muted text link',
      );
      final link = tester.widget<Text>(find.text('Iniciar sesión'));
      expect(
        link.style?.color,
        AppColors.mutedStrong,
        reason: 'mutedStrong #999999 — the primary CTA must dominate',
      );
    });

    testWidgets('the VDiscoDivider is gone — one primary CTA only (XL-19)', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      expect(find.byType(VDiscoDivider), findsNothing);
      // The wordmark + tagline + ONE primary CTA block: the sign-in entry
      // is the text link (already covered above).
      expect(
        tester.widgetList<VButton>(find.byType(VButton)).length,
        1,
        reason: 'exactly one VButton on the brand screen',
      );
    });

    testWidgets('wordmark is the VDisplayText hero (Playfair displayLarge, '
        'violet family, breathing glow)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const WelcomeScreen(), notifier);
      await tester.pumpAndSettle();

      final display = tester.widget<VDisplayText>(find.byType(VDisplayText));
      expect(display.text, 'VIVE');
      expect(display.gradient, AppGradients.violet);
      final text = tester.widget<Text>(find.text('VIVE'));
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontSize, AppTypography.displayLarge.fontSize);
      expect(
        text.style?.fontStyle,
        isNull,
        reason: 'no italics — user directive 2026-08-14',
      );
    });

    testWidgets('login primary CTA is BLACK — no cyan/skyblue (user '
        'directive 2026-08-14)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const LoginScreen(), notifier);
      await tester.pumpAndSettle();

      final button = tester.widget<VButton>(
        find.widgetWithText(VButton, 'Iniciar sesión'),
      );
      expect(
        button.variant,
        VButtonVariant.dark,
        reason: 'the login CTA is the black variant, never glowAccent',
      );
      expect(button.gradient, isNull);
      final style = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Iniciar sesión'))
          .style;
      expect(
        style?.backgroundColor?.resolve({}),
        AppColors.surfaceAlt,
        reason: 'black face, not the cyan family gradient',
      );
      expect(
        style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'white text on black',
      );
      await _unmount(tester);
    });
  });

  group('Auth big headers — VDisplayText heroes (§3.2/§3.3, LUXE v2)', () {
    testWidgets('signup header renders the violet hero with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      _expectDisplayHeader(
        tester,
        'Crea tu cuenta',
        AppGradients.familyOf('signup'),
      );
    });

    testWidgets('age_gate header renders the violet hero with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const AgeGateScreen(email: 'test@test.com'),
        notifier,
      );
      await tester.pumpAndSettle();

      _expectDisplayHeader(
        tester,
        '¿Cuál es tu fecha de nacimiento?',
        AppGradients.familyOf('age_gate'),
      );
    });

    testWidgets('otp header renders the gold hero with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const OtpVerificationScreen(email: 'a@b.com', password: 'secret1'),
        notifier,
      );
      await tester.pump();

      _expectDisplayHeader(
        tester,
        'Ingresa el código de verificación',
        AppGradients.familyOf('otp'),
      );
      await _unmount(tester);
    });

    testWidgets('privacy_terms header renders the mint hero with the glow', (
      tester,
    ) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();

      _expectDisplayHeader(
        tester,
        'Acepta los términos para continuar',
        AppGradients.familyOf('privacy_terms'),
      );
    });

    testWidgets('forgot-password header renders the peach hero with the '
        'glow', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      _expectDisplayHeader(
        tester,
        '¿Olvidaste tu contraseña?',
        AppGradients.familyOf('forgot_password'),
      );
    });
  });

  group('ForgotPasswordScreen — §5.1 brand-moment CTA (U-14 R3, LUXE v2)', () {
    testWidgets('primary CTA is the filled glowAccent with the peach family '
        '(no pink)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      _expectFilledGlowAccent(
        tester,
        'Enviar enlace',
        AppGradients.familyOf('forgot_password'),
      );
    });

    testWidgets('the recovery form rides the VInput placeholder (VInput '
        'errorText for auth errors)', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.hintText, 'Correo electrónico');
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
        'La contraseña debe tener al menos 8 caracteres y contener un número.',
      );
      expect(passwordField.decoration?.errorStyle?.color, AppColors.error);
    });

    testWidgets('signup shows the mismatch error as the confirm field '
        'errorText in glowPink', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextField).at(1), 'secret12');
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

      // 'sofia' satisfies the username policy (min 5 graphemes) so the save
      // reaches createProfile, whose failure surfaces as the field error.
      await tester.enterText(find.byType(TextField), 'sofia');
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

  group('§6.2 display auth headers (LUXE v2 — VDisplayText, one hero per '
      'screen)', () {
    void expectDisplayHeader(String label) {
      final display = find.byType(VDisplayText);
      expect(
        display,
        findsOneWidget,
        reason:
            '§6.2 + LUXE directive #8 — exactly one display hero per '
            'screen',
      );
      expect(
        find.descendant(of: display, matching: find.text(label.toUpperCase())),
        findsOneWidget,
        reason: '$label is the screen\'s display hero',
      );
    }

    testWidgets('signup header is the display hero', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const SignupContactScreen(), notifier);
      await tester.pumpAndSettle();
      expectDisplayHeader('Crea tu cuenta');
    });

    testWidgets('age_gate header is the display hero', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const AgeGateScreen(email: 'test@test.com'),
        notifier,
      );
      await tester.pumpAndSettle();
      expectDisplayHeader('¿Cuál es tu fecha de nacimiento?');
    });

    testWidgets('privacy_terms header is the display hero', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(
        tester,
        const PrivacyTermsScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
        notifier,
      );
      await tester.pumpAndSettle();
      expectDisplayHeader('Acepta los términos para continuar');
    });

    testWidgets('forgot-password header is the display hero in the form '
        'state', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pump(tester, const ForgotPasswordScreen(), notifier);
      await tester.pumpAndSettle();
      expectDisplayHeader('¿Olvidaste tu contraseña?');
    });
  });
}
