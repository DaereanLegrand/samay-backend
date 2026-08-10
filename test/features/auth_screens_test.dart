import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/router/route_extras.dart';
import 'package:samay/features/auth/screens/welcome_screen.dart';
import 'package:samay/features/auth/screens/login_screen.dart';
import 'package:samay/features/auth/screens/signup_contact_screen.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/auth/screens/age_gate_screen.dart';
import 'package:samay/features/auth/screens/privacy_terms_screen.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/route_error_screen.dart';

/// Local test router with the auth-flow routes. Extras are read through the
/// typed [RouteExtra] factories (I-03 / NAV-04 / H-04) — never raw
/// `state.extra as Map<String, dynamic>` casts — so a malformed or missing
/// extra renders [RouteErrorScreen] instead of crashing the harness.
Widget _wrap(Widget child) {
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/test', builder: (_, _) => child),
      GoRoute(
        path: '/auth/signup',
        builder: (_, _) => const SignupContactScreen(),
      ),
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
  return ProviderScope(
    child: MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

void main() {
  group('WelcomeScreen', () {
    testWidgets('renders title and buttons', (tester) async {
      await tester.pumpWidget(_wrap(const WelcomeScreen()));
      expect(find.text('VIVE'), findsOneWidget);
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
    testWidgets('renders email, password, confirm password fields and create button', (tester) async {
      await tester.pumpWidget(_wrap(const SignupContactScreen()));
      expect(find.text('Correo electrónico'), findsOneWidget);
      expect(find.textContaining('Contraseña'), findsWidgets);
      expect(find.text('Crear cuenta'), findsWidgets);
    });
  });

  group('OtpVerificationScreen', () {
    testWidgets('renders code input and verify button', (tester) async {
      await tester.pumpWidget(_wrap(
        OtpVerificationScreen(email: 'test@test.com', password: 'test123'),
      ));
      // Settle the async auth provider: the very first frame is AsyncLoading
      // (button shows a spinner), which is not the state under test.
      await tester.pumpAndSettle();
      expect(find.text('Verificar'), findsOneWidget);
    });
  });

  group('AgeGateScreen', () {
    testWidgets('renders date picker button and continue', (tester) async {
      await tester.pumpWidget(_wrap(
        AgeGateScreen(email: 'test@test.com'),
      ));
      expect(find.text('Continuar'), findsOneWidget);
      expect(find.text('Seleccionar fecha'), findsOneWidget);
    });
  });

  group('PrivacyTermsScreen', () {
    testWidgets('renders checkboxes and create account button', (tester) async {
      await tester.pumpWidget(_wrap(
        PrivacyTermsScreen(email: 'test@test.com', dateOfBirth: '2000-01-15'),
      ));
      expect(find.text('Crear cuenta'), findsOneWidget);
    });
  });

  group('ProfileSetupScreen', () {
    testWidgets('renders form fields and save button, no skip', (tester) async {
      await tester.pumpWidget(_wrap(
        ProfileSetupScreen(email: 'test@test.com', dateOfBirth: '2000-01-15'),
      ));
      // Settle the async auth provider: the very first frame is AsyncLoading
      // (button shows a spinner), which is not the state under test.
      await tester.pumpAndSettle();
      expect(find.text('Nombre de usuario'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
      expect(find.text('Completar despu\u00e9s'), findsNothing);
    });
  });

  group('harness route extras (I-03 / NAV-04 / H-04)', () {
    testWidgets('legacy map extras still reach the screens via RouteExtras',
        (tester) async {
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

    testWidgets('missing extras render RouteErrorScreen, never crash',
        (tester) async {
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
