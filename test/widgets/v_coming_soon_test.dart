import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';

MaterialApp _app({required Widget home}) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

void main() {
  group('VComingSoonScreen', () {
    testWidgets('renders title, headline and description', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      expect(find.text('Eventos'), findsOneWidget);
      expect(find.text('Pr\u00f3ximamente'), findsOneWidget);
      expect(find.text('Descripcion de prueba'), findsOneWidget);
    });

    testWidgets('renders default icon', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      expect(find.byIcon(Icons.construction), findsOneWidget);
    });

    testWidgets('shows Volver button and pops the navigator', (tester) async {
      await tester.pumpWidget(
        _app(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const VComingSoonScreen(
                    title: 'Eventos',
                    description: 'Descripcion de prueba',
                  ),
                ),
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Volver'), findsOneWidget);
      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();
      expect(find.text('Abrir'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });

    testWidgets('hides Volver button when showBackButton is false',
        (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
            showBackButton: false,
          ),
        ),
      );
      expect(find.text('Volver'), findsNothing);
    });
  });
}
