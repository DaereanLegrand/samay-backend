import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/features/auth/welcome_screen.dart';
import 'package:vive_app/features/auth/login_screen.dart';
import 'package:vive_app/features/auth/signup_contact_screen.dart';
import 'package:vive_app/features/auth/otp_verification_screen.dart';
import 'package:vive_app/features/auth/age_gate_screen.dart';
import 'package:vive_app/features/auth/privacy_terms_screen.dart';
import 'package:vive_app/features/auth/profile_setup_screen.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      home: child,
      routes: {
        '/auth/signup': (_) => const SignupContactScreen(),
        '/auth/verify': (_) => const Scaffold(),
        '/auth/age-gate': (_) => const Scaffold(),
        '/auth/privacy-terms': (_) => const Scaffold(),
        '/auth/profile-setup': (_) => const Scaffold(),
        '/main/feed': (_) => const Scaffold(),
      },
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
  });

  group('SignupContactScreen', () {
    testWidgets('renders email field and continue button', (tester) async {
      await tester.pumpWidget(_wrap(const SignupContactScreen()));
      expect(find.text('Correo electrónico'), findsOneWidget);
      expect(find.text('Continuar'), findsOneWidget);
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
        PrivacyTermsScreen(email: 'test@test.com'),
      ));
      expect(find.text('Crear cuenta'), findsOneWidget);
    });
  });

  group('ProfileSetupScreen', () {
    testWidgets('renders form fields', (tester) async {
      await tester.pumpWidget(_wrap(
        ProfileSetupScreen(email: 'test@test.com'),
      ));
      expect(find.text('Nombre de usuario'), findsOneWidget);
      expect(find.text('Nombre visible'), findsOneWidget);
      expect(find.text('Completar después'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
    });
  });
}
