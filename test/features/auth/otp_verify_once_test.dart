import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// REGRESSION (2026-08-24, user report): the OTP screen allowed re-submitting
/// an ALREADY-CONSUMED code after a successful verification (the code field
/// was never cleared and there was no verified latch). GoTrue answers any
/// rejected email code with `otp_expired`, so the redundant second call
/// produced a FAKE "El código ha expirado" — and its failure path signed out
/// the just-created session mid-funnel.
///
/// Contract: verification is single-shot — after a success, further submit
/// attempts (queued taps, autofill events) must NOT reach the notifier.
class _CountingOtpNotifier extends AuthNotifier {
  int verifyOtpCalls = 0;

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> verifyOtp(String email, String token, [String? password]) async {
    verifyOtpCalls++;
    state = const AsyncData(AuthState(authenticated: true, hasProfile: false));
  }

  @override
  Future<void> sendOtp(String email) async {
    state = AsyncData(state.valueOrNull ?? const AuthState());
  }

  @override
  Future<void> signOut() async {
    state = const AsyncData(AuthState());
  }
}

class _Harness {
  _Harness(this.container, this.notifier);

  final ProviderContainer container;
  final _CountingOtpNotifier notifier;
}

Future<_Harness> _pump(WidgetTester tester) async {
  // Phone-sized surface: the OTP column overflows the 800×600 test default.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final notifier = _CountingOtpNotifier();
  final container = ProviderContainer(
    overrides: [authStateProvider.overrideWith(() => notifier)],
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
        builder: (_, _) =>
            const Scaffold(body: Text('age-gate-marker')),
      ),
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
  await tester.pumpAndSettle();
  return _Harness(container, notifier);
}

void main() {
  testWidgets('entering the code verifies exactly once and advances the '
      'funnel', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();

    expect(harness.notifier.verifyOtpCalls, 1);
    expect(find.text('age-gate-marker'), findsOneWidget);
  });

  testWidgets('a queued second Verificar tap AFTER success is ignored '
      '(no duplicate verify of the consumed code)', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    expect(harness.notifier.verifyOtpCalls, 1);

    // The OTP screen stays mounted (OFFSTAGE, not hit-testable) below the
    // pushed age-gate route — fire its still-live submit handler directly,
    // exactly as a late tap / queued event would.
    final submit = tester.widget<TextButton>(
      find.widgetWithText(
        TextButton,
        'Verificar',
        skipOffstage: false,
      ),
    );
    expect(submit.onPressed, isNotNull);
    submit.onPressed!();
    await tester.pumpAndSettle();

    expect(harness.notifier.verifyOtpCalls, 1);
  });
}
