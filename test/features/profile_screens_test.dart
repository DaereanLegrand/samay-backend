import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive/features/profile/profile_screen.dart';
import 'package:vive/features/profile/edit_profile_screen.dart';
import 'package:vive/features/profile/settings_screen.dart';
import 'package:vive/features/profile/public_profile_screen.dart';
import 'package:vive/features/profile/delete_account_screen.dart';
import 'package:vive/features/feed/feed_screen.dart';
import 'package:vive/shared/widgets/v_button.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(home: child),
  );
}

void main() {
  group('ProfileScreen', () {
    testWidgets('renders profile title', (tester) async {
      await tester.pumpWidget(_wrap(const ProfileScreen()));
      expect(find.text('Perfil'), findsOneWidget);
    });
  });

  group('EditProfileScreen', () {
    testWidgets('renders edit form', (tester) async {
      await tester.pumpWidget(_wrap(const EditProfileScreen()));
      expect(find.text('Editar perfil'), findsOneWidget);
      expect(find.text('Biograf\u00eda'), findsOneWidget);
      expect(find.text('Guardar cambios'), findsOneWidget);
    });
  });

  group('SettingsScreen', () {
    testWidgets('renders settings options', (tester) async {
      await tester.pumpWidget(_wrap(const SettingsScreen()));
      expect(find.text('Configuración'), findsOneWidget);
      expect(find.text('Suscripción'), findsOneWidget);
      expect(find.text('Cerrar sesión'), findsOneWidget);
    });
  });

  group('PublicProfileScreen', () {
    testWidgets('renders public profile', (tester) async {
      await tester.pumpWidget(_wrap(
        const PublicProfileScreen(userId: 'test-id'),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Usuario'), findsOneWidget);
      expect(find.text('Agregar amigo'), findsOneWidget);
    });
  });

  group('DeleteAccountScreen', () {
    testWidgets('renders delete account form', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      expect(find.text('Eliminar cuenta'), findsWidgets);
      expect(find.textContaining('Confirma tu correo'), findsOneWidget);
    });

    testWidgets('tapping delete with empty email does nothing', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.tap(find.text('Eliminar cuenta').last);
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar cuenta?'), findsNothing);
    });

    testWidgets('tapping delete with wrong email does not show confirm dialog', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      await tester.enterText(find.byType(TextField), 'wrong@email.com');
      await tester.pump();
      await tester.tap(find.text('Eliminar cuenta').last);
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar cuenta?'), findsNothing);
    });
  });

  group('FeedScreen', () {
    testWidgets('renders welcome message', (tester) async {
      await tester.pumpWidget(_wrap(const FeedScreen()));
      expect(find.text('Bienvenido a Vive!'), findsOneWidget);
    });
  });
}
