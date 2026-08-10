import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// Deterministic auth notifier for the OTP UX tests (I-29, SEC-05/H-23):
/// records every `verifyOtp`/`sendOtp` call and can be switched between
/// success and failure modes. Injected via `authStateProvider.overrideWith`,
/// so no Supabase/network is ever touched.
class _RecordingAuthNotifier extends AuthNotifier {
  final List<String> verifyCalls = [];
  final List<String> sendOtpCalls = [];
  bool failVerification = false;

  /// When true, the notifier resolves "successful" verifications as
  /// unauthenticated (no error, no session) — the screen's early-return path,
  /// so tests can exercise several verifications without navigating away.
  bool authenticatedResult = true;

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> sendOtp(String email) async {
    sendOtpCalls.add(email);
    state = AsyncData(state.valueOrNull ?? const AuthState());
  }

  @override
  Future<void> verifyOtp(String email, String token, [String? password]) async {
    verifyCalls.add(token);
    if (failVerification) {
      state = AsyncError(
        ValidationError('código', 'El código no es válido'),
        StackTrace.current,
      );
      return;
    }
    state = AsyncData(
      authenticatedResult
          ? const AuthState(authenticated: true)
          : const AuthState(),
    );
  }
}

Future<_Harness> _pumpScreen(
  WidgetTester tester,
  _RecordingAuthNotifier notifier,
) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => notifier),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (_, _) => const OtpVerificationScreen(
          email: 'a@b.com',
          password: 'secret1',
        ),
      ),
      GoRoute(
        path: RoutePaths.ageGate,
        builder: (_, _) => const Scaffold(body: Text('age-gate')),
      ),
      GoRoute(path: RoutePaths.mainFeed, builder: (_, _) => const Scaffold()),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  return _Harness(container, router);
}

class _Harness {
  _Harness(this.container, this.router);
  final ProviderContainer container;
  final GoRouter router;
}

/// Unmounts the widget tree so the 1s countdown timer is cancelled by the
/// screen's `dispose` — keeps `testWidgets` free of pending-timer failures.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  group('OtpVerificationScreen — resend countdown (SEC-05/H-23)', () {
    testWidgets('counts down and disables resend until the cooldown elapses',
        (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pumpScreen(tester, notifier);
      await tester.pump();

      expect(find.text('Reenviar código (60s)'), findsOneWidget);
      TextButton button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Reenviar código (60s)'),
      );
      expect(button.onPressed, isNull);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Reenviar código (59s)'), findsOneWidget);
      expect(find.text('Reenviar código (60s)'), findsNothing);

      await tester.pump(const Duration(seconds: 59));
      expect(find.text('Reenviar código'), findsOneWidget);
      expect(find.textContaining('Reenviar código (', findRichText: false),
          findsNothing);
      button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Reenviar código'),
      );
      expect(button.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(TextButton, 'Reenviar código'));
      await tester.pump();

      expect(notifier.sendOtpCalls, ['a@b.com']);
      expect(find.text('Reenviar código (60s)'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('resend restarts the countdown', (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pumpScreen(tester, notifier);
      await tester.pump();

      await tester.pump(const Duration(seconds: 60));
      expect(find.text('Reenviar código'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Reenviar código'));
      await tester.pump();
      expect(find.text('Reenviar código (60s)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Reenviar código (59s)'), findsOneWidget);
      expect(notifier.sendOtpCalls, ['a@b.com']);
      await _unmount(tester);
    });
  });

  group('OtpVerificationScreen — auto-submit on 6 digits (AUTH spec gap)', () {
    testWidgets('fires verification when the 6th digit is entered',
        (tester) async {
      final notifier = _RecordingAuthNotifier()
        ..authenticatedResult = false;
      await _pumpScreen(tester, notifier);
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();

      expect(notifier.verifyCalls, ['123456']);
      await _unmount(tester);
    });

    testWidgets('manual Verificar button still verifies the entered code',
        (tester) async {
      final notifier = _RecordingAuthNotifier()
        ..authenticatedResult = false;
      await _pumpScreen(tester, notifier);
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      expect(notifier.verifyCalls, ['123456']);

      await tester.tap(find.widgetWithText(TextButton, 'Verificar'));
      await tester.pump();

      expect(notifier.verifyCalls, ['123456', '123456']);
      await _unmount(tester);
    });

    testWidgets('successful verification navigates to the age gate',
        (tester) async {
      final notifier = _RecordingAuthNotifier();
      await _pumpScreen(tester, notifier);
      await tester.pump();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('age-gate'), findsOneWidget);
      expect(notifier.verifyCalls, ['123456']);
      await _unmount(tester);
    });
  });

  group('OtpVerificationScreen — wrong-attempt guard (SEC-05/H-23)', () {
    testWidgets('blocks verification after 5 consecutive failures and '
        'requires a resend to reset the counter', (tester) async {
      final notifier = _RecordingAuthNotifier()..failVerification = true;
      await _pumpScreen(tester, notifier);
      await tester.pump();

      for (var i = 0; i < 5; i++) {
        await tester.enterText(find.byType(TextField), '000000');
        await tester.pump();
      }
      expect(notifier.verifyCalls, List.filled(5, '000000'));

      expect(
        find.text('Demasiados intentos fallidos. Solicita un nuevo código.'),
        findsOneWidget,
      );
      final verifyButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Verificar'),
      );
      expect(verifyButton.onPressed, isNull);

      // Blocked state: further input must NOT auto-submit.
      await tester.enterText(find.byType(TextField), '111111');
      await tester.pump();
      expect(notifier.verifyCalls, hasLength(5));

      // Resend (once the cooldown elapsed) resets the failure counter.
      await tester.pump(const Duration(seconds: 61));
      await tester.tap(find.widgetWithText(TextButton, 'Reenviar código'));
      await tester.pump();
      expect(notifier.sendOtpCalls, ['a@b.com']);
      expect(
        find.text('Demasiados intentos fallidos. Solicita un nuevo código.'),
        findsNothing,
      );

      final verifyButtonAfterReset = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Verificar'),
      );
      expect(verifyButtonAfterReset.onPressed, isNotNull);

      // First failure after the reset is attempt 1 — no block yet.
      await tester.enterText(find.byType(TextField), '222222');
      await tester.pump();
      expect(notifier.verifyCalls, hasLength(6));
      expect(
        find.text('Demasiados intentos fallidos. Solicita un nuevo código.'),
        findsNothing,
      );
      await _unmount(tester);
    });
  });
}
