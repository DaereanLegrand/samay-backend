import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  group('ErrorView', () {
    testWidgets('renders the message', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorView(message: 'No se pudo cargar')));
      expect(find.text('No se pudo cargar'), findsOneWidget);
    });

    testWidgets('renders the error icon by default', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorView(message: 'No se pudo cargar')));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('renders a custom icon', (tester) async {
      await tester.pumpWidget(
        _wrap(const ErrorView(message: 'Sin conexión', icon: Icons.wifi_off)),
      );
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });

    testWidgets('retry button fires the retry callback', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(ErrorView(message: 'Error', onRetry: () => retried = true)),
      );
      await tester.tap(find.text('Reintentar'));
      expect(retried, isTrue);
    });

    testWidgets('retry button uses the provided label', (tester) async {
      await tester.pumpWidget(
        _wrap(ErrorView(message: 'Error', onRetry: () {}, retryLabel: 'Volver a intentar')),
      );
      expect(find.text('Volver a intentar'), findsOneWidget);
    });

    testWidgets('hides retry button when onRetry is null', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorView(message: 'Error')));
      expect(find.text('Reintentar'), findsNothing);
    });

    testWidgets('uses pink accent for the icon', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorView(message: 'Error')));
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.color, const Color(0xFFFF2E88));
    });

    testWidgets('uses light gray for the message', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorView(message: 'Error')));
      final text = tester.widget<Text>(find.text('Error'));
      expect(text.style?.color, const Color(0xFF999999));
    });
  });
}
