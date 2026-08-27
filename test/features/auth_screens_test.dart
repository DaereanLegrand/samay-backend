import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/screens/welcome_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/route_error_screen.dart';

/// Auth notifier pinned to "email already registered" so the signup screen's
/// exists-dialog can be exercised without network (no-fallback policy
/// 2026-08-13: the dialog must offer an explicit labeled login action).
class _FakeExistsAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<String> checkEmail(String email) async => 'exists';
}

/// Local test router with the auth-flow routes. Extras are read through the
/// typed [RouteExtra] factories (I-03 / NAV-04 / H-04) — never raw
/// `state.extra as Map<String, dynamic>` casts — so a malformed or missing
/// extra renders [RouteErrorScreen] instead of crashing the harness.
Widget _wrap(Widget child, {AuthNotifier? authNotifier}) {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, _) => child),
      GoRoute(path: '/auth/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: RoutePaths.login, builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/auth/verify',
        builder: (_, state) {
          final extra = VerifyExtra.fromState(state);
          if (extra == null) return const RouteErrorScreen();
          return OtpVerificationScreen(
            email: extra.email,
            password: extra.password,
          );
        },
      ),
      GoRoute(
        path: '/auth/age-gate',
        builder: (_, state) =>
            AgeGateScreen(email: AgeGateExtra.fromState(state)?.email),
      ),
      GoRoute(
        path: '/auth/privacy-terms',
        builder: (_, state) {
          final extra = PrivacyTermsExtra.fromState(state);
          if (extra == null) return const RouteErrorScreen();
          return PrivacyTermsScreen(
            email: extra.email,
            dateOfBirth: extra.dateOfBirth,
          );
        },
      ),
      GoRoute(
        path: '/auth/profile-setup',
        builder: (_, state) {
          final extra = ProfileSetupExtra.fromState(state);
          if (extra == null) return const RouteErrorScreen();
          return ProfileSetupScreen(
            email: extra.email,
            dateOfBirth: extra.dateOfBirth,
          );
        },
      ),
      GoRoute(path: '/main/feed', builder: (_, _) => const Scaffold()),
    ],
  );
  final overrides = <Override>[
    if (authNotifier != null)
      authStateProvider.overrideWith(() => authNotifier),
  ];
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

/// Phone-sized test surface for the OTP-pumping tests: the U-07 restyle grew
/// the OTP column (displayMedium header + otpInputText field), and the
/// 800×600 test default is smaller than any phone — the pinned-bottom layout
/// overflowed in the Ahem-font harness.
void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('WelcomeScreen', () {
    testWidgets('renders title and buttons', (tester) async {
      await tester.pumpWidget(_wrap(const WelcomeScreen()));
      expect(find.text('vive'), findsOneWidget);
      expect(find.text('Crear cuenta'), findsOneWidget);
      expect(find.text('Iniciar sesión'), findsOneWidget);
    });
  });

  group('LoginScreen', () {
    testWidgets('renders email and password fields', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      expect(find.text('Correo electrónico'), findsOneWidget);
      expect(find.text('Contraseña'), findsOneWidget);
      expect(find.text('Olvidé mi contraseña'), findsOneWidget);
    });

    testWidgets('renders login button', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      // Settle the async auth provider: the very first frame is AsyncLoading
      // (button shows a spinner), which is not the state under test.
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Iniciar sesión'), findsOneWidget);
    });

    testWidgets('renders crear cuenta button', (tester) async {
      await tester.pumpWidget(_wrap(const LoginScreen()));
      expect(find.text('Crear cuenta'), findsWidgets);
    });
  });

  group('SignupContactScreen', () {
    testWidgets(
      'renders email, password, confirm password fields and create button',
      (tester) async {
        await tester.pumpWidget(_wrap(const SignupContactScreen()));
        // Settle the async auth provider: the very first frame is
        // AsyncLoading (the CTA shows a spinner, not its label).
        await tester.pumpAndSettle();
        expect(find.text('Correo electrónico'), findsOneWidget);
        expect(find.textContaining('Contraseña'), findsWidgets);
        expect(find.text('Crear cuenta'), findsWidgets);
      },
    );

    testWidgets('already-registered dialog offers an explicit login action '
        'that navigates to the login screen (no-fallback policy)', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(
        _wrap(
          const SignupContactScreen(),
          authNotifier: _FakeExistsAuthNotifier(),
        ),
      );
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'tester@tester.com');
      await tester.enterText(fields.at(1), 'tester123');
      await tester.enterText(fields.at(2), 'tester123');
      await tester.tap(find.text('Crear cuenta'));
      await tester.pumpAndSettle();

      expect(find.text('Correo ya registrado'), findsOneWidget);
      expect(find.text('Iniciar sesión'), findsOneWidget);

      await tester.tap(find.text('Iniciar sesión'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(SignupContactScreen), findsNothing);
    });
  });

  group('OtpVerificationScreen', () {
    testWidgets('renders code input and verify button', (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(
        _wrap(
          const OtpVerificationScreen(
            email: 'test@test.com',
            password: 'test123',
          ),
        ),
      );
      // Settle the async auth provider: the very first frame is AsyncLoading
      // (button shows a spinner), which is not the state under test.
      await tester.pumpAndSettle();
      expect(find.text('Verificar'), findsOneWidget);
    });
  });

  group('AgeGateScreen', () {
    testWidgets('renders date picker button and continue', (tester) async {
      await tester.pumpWidget(
        _wrap(const AgeGateScreen(email: 'test@test.com')),
      );
      expect(find.text('Continuar'), findsOneWidget);
      expect(find.text('Seleccionar fecha'), findsOneWidget);
    });
  });

  group('PrivacyTermsScreen', () {
    testWidgets('renders checkboxes and create account button', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const PrivacyTermsScreen(
            email: 'test@test.com',
            dateOfBirth: '2000-01-15',
          ),
        ),
      );
      expect(find.text('Crear cuenta'), findsOneWidget);
    });
  });

  group('ProfileSetupScreen', () {
    testWidgets('renders form fields and save button, no skip', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ProfileSetupScreen(
            email: 'test@test.com',
            dateOfBirth: '2000-01-15',
          ),
        ),
      );
      // Settle the async auth provider: the very first frame is AsyncLoading
      // (button shows a spinner), which is not the state under test.
      await tester.pumpAndSettle();
      expect(find.text('Nombre de usuario'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
      expect(find.text('Completar despu\u00e9s'), findsNothing);
    });
  });

  group('harness route extras (I-03 / NAV-04 / H-04)', () {
    testWidgets('legacy map extras still reach the screens via RouteExtras', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(_wrap(const WelcomeScreen()));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(WelcomeScreen));
      context.push(
        '/auth/verify',
        extra: {'email': 'a@b.com', 'password': 'secret1'},
      );
      await tester.pumpAndSettle();
      expect(find.byType(OtpVerificationScreen), findsOneWidget);
      expect(find.text('Verificar'), findsOneWidget);
    });

    testWidgets('missing extras render RouteErrorScreen, never crash', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(_wrap(const WelcomeScreen()));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(WelcomeScreen));
      context.push('/auth/verify');
      await tester.pumpAndSettle();
      expect(find.byType(RouteErrorScreen), findsOneWidget);
      expect(find.byType(OtpVerificationScreen), findsNothing);
    });
  });
}
