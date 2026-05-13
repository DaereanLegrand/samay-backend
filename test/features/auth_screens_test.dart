import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vive_app/features/auth/welcome_screen.dart';
import 'package:vive_app/features/auth/login_screen.dart';
import 'package:vive_app/features/auth/signup_contact_screen.dart';
import 'package:vive_app/features/auth/otp_verification_screen.dart';
import 'package:vive_app/features/auth/age_gate_screen.dart';
import 'package:vive_app/features/auth/privacy_terms_screen.dart';
import 'package:vive_app/features/auth/profile_setup_screen.dart';

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
        builder: (_, state) => OtpVerificationScreen(email: state.extra as String),
      ),
      GoRoute(
        path: '/auth/age-gate',
        builder: (_, state) => AgeGateScreen(email: state.extra as String?),
      ),
      GoRoute(
        path: '/auth/privacy-terms',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          return PrivacyTermsScreen(
            email: extra['email'] as String,
            dateOfBirth: extra['dateOfBirth'] as String,
          );
        },
      ),
      GoRoute(
        path: '/auth/profile-setup',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>;
          return ProfileSetupScreen(
            email: extra['email'] as String,
            dateOfBirth: extra['dateOfBirth'] as String,
          );
        },
      ),
      GoRoute(path: '/main/feed', builder: (_, _) => const Scaffold()),
    ],
  );
  return ProviderScope(
    child: MaterialApp.router(
      routerConfig: router,
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
        OtpVerificationScreen(email: 'test@test.com'),
      ));
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
      expect(find.text('Nombre de usuario'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
      expect(find.text('Completar despu\u00e9s'), findsNothing);
    });
  });
}
