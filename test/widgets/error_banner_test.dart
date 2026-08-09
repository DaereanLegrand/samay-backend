import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_banner.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  group('ErrorBanner', () {
    testWidgets('renders the message', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Algo salió mal')));
      expect(find.text('Algo salió mal'), findsOneWidget);
    });

    testWidgets('renders the error icon by default', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Algo salió mal')));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('renders a custom icon', (tester) async {
      await tester.pumpWidget(
        _wrap(const ErrorBanner(message: 'Sin conexión', icon: Icons.wifi_off)),
      );
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    });

    testWidgets('retry button fires the retry callback', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        _wrap(ErrorBanner(message: 'Error', onRetry: () => retried = true)),
      );
      await tester.tap(find.text('Reintentar'));
      expect(retried, isTrue);
    });

    testWidgets('hides retry button when onRetry is null', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Error')));
      expect(find.text('Reintentar'), findsNothing);
    });

    testWidgets('close button fires the close callback', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        _wrap(ErrorBanner(message: 'Error', onClose: () => closed = true)),
      );
      await tester.tap(find.byIcon(Icons.close));
      expect(closed, isTrue);
    });

    testWidgets('hides close button when onClose is null', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Error')));
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('uses pink accent for the icon', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Error')));
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.color, const Color(0xFFFF2E88));
    });

    testWidgets('uses light gray for the message', (tester) async {
      await tester.pumpWidget(_wrap(const ErrorBanner(message: 'Error')));
      final text = tester.widget<Text>(find.text('Error'));
      expect(text.style?.color, const Color(0xFF999999));
    });
  });
}
