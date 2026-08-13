import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/show_app_error.dart';

MaterialApp _app() {
  return const MaterialApp(
    locale: Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(),
  );
}

void main() {
  group('showAppError', () {
    testWidgets(
      'maps a raw Exception to a generic user-safe message via SnackBar',
      (tester) async {
        await tester.pumpWidget(_app());
        await showAppError(
          tester.element(find.byType(Scaffold)),
          Exception('boom'),
        );
        await tester.pump();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text(ServerError().message), findsOneWidget);
        expect(
          find.textContaining('boom'),
          findsNothing,
          reason: 'raw exception internals must never reach the user (ERR-03)',
        );
      },
    );

    testWidgets('shows a SnackBar for transient (non-blocking) errors', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await showAppError(
        tester.element(find.byType(Scaffold)),
        Exception('transient'),
      );
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('shows an AlertDialog for blocking errors', (tester) async {
      await tester.pumpWidget(_app());
      final future = showAppError(
        tester.element(find.byType(Scaffold)),
        Exception('blocking'),
        blocking: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(ServerError().message), findsOneWidget);
      expect(find.textContaining('blocking'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await future;
    });

    testWidgets('shows a plain String error verbatim', (tester) async {
      await tester.pumpWidget(_app());
      await showAppError(
        tester.element(find.byType(Scaffold)),
        'Error personalizado',
      );
      await tester.pump();
      expect(find.text('Error personalizado'), findsOneWidget);
    });

    testWidgets('blocking dialog dismisses via OK', (tester) async {
      await tester.pumpWidget(_app());
      final future = showAppError(
        tester.element(find.byType(Scaffold)),
        Exception('dismiss me'),
        blocking: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await future;
    });

    testWidgets('blocking dialog shows the mapped error code', (tester) async {
      await tester.pumpWidget(_app());
      final future = showAppError(
        tester.element(find.byType(Scaffold)),
        UnauthorizedError(),
        blocking: true,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('AUTH_UNAUTHORIZED'), findsOneWidget);
      expect(find.text('Código de error: AUTH_UNAUTHORIZED'), findsOneWidget);
      expect(find.text(UnauthorizedError().message), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await future;
    });

    testWidgets('SnackBar shows the mapped error code', (tester) async {
      await tester.pumpWidget(_app());
      await showAppError(
        tester.element(find.byType(Scaffold)),
        UnauthorizedError(),
      );
      await tester.pump();
      expect(find.textContaining('AUTH_UNAUTHORIZED'), findsOneWidget);
      expect(find.text('Código de error: AUTH_UNAUTHORIZED'), findsOneWidget);
      expect(find.text(UnauthorizedError().message), findsOneWidget);
    });
  });

  group('showErrorSnackBar', () {
    testWidgets('shows a SnackBar with the mapped user-safe message', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await showErrorSnackBar(
        tester.element(find.byType(Scaffold)),
        Exception('snack'),
      );
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(ServerError().message), findsOneWidget);
      expect(find.textContaining('snack'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
