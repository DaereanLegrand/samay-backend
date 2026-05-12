import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/features/profile/profile_screen.dart';
import 'package:vive_app/features/profile/edit_profile_screen.dart';
import 'package:vive_app/features/profile/settings_screen.dart';
import 'package:vive_app/features/profile/public_profile_screen.dart';
import 'package:vive_app/features/profile/delete_account_screen.dart';
import 'package:vive_app/features/feed/feed_screen.dart';

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
      expect(find.text('Nombre visible'), findsOneWidget);
      expect(find.text('Biografía'), findsOneWidget);
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
      expect(find.text('Perfil'), findsOneWidget);
      expect(find.text('Agregar amigo'), findsOneWidget);
    });
  });

  group('DeleteAccountScreen', () {
    testWidgets('renders delete account form', (tester) async {
      await tester.pumpWidget(_wrap(const DeleteAccountScreen()));
      expect(find.text('Eliminar cuenta'), findsWidgets);
    });
  });

  group('FeedScreen', () {
    testWidgets('renders welcome message', (tester) async {
      await tester.pumpWidget(_wrap(const FeedScreen()));
      expect(find.text('Bienvenido a Vive!'), findsOneWidget);
    });
  });
}
