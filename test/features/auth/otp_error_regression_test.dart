import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/ban_service.dart';
import 'package:samay/crypto/interfaces.dart';
import 'package:samay/features/auth/screens/otp_verification_screen.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// REGRESSION (2026-08-26, user report): a rejected OTP showed NO error. The
/// screen mirrored the GLOBAL `authStateProvider` error, but the notifier
/// signs out in its `verifyOtp` failure path (`auth_provider.dart` catch) and
/// the `signedOut` listener rewrites the global provider to `AsyncData`
/// before the next frame — the message was silently lost. The field cleared,
/// but the user got no feedback.
///
/// Contract: a rejected code must render the specific invalid-code message
/// (captured locally at failure time — GoTrue answers every rejected email
/// code with `otp_expired`, so the message is a single fixed literal), keep
/// the user on the screen, and clear the field.
class _FakeAuthService extends Mock implements AuthService {}

class _FakeBanService extends Mock implements BanService {}

class _FakePrekeyService extends Mock implements E2eePrekeyService {}

/// The REAL [AuthNotifier] with a service that throws `otp_expired` on verify
/// and emits `signedOut` on signOut — exactly how production fails (the
/// notifier signs out in its catch, firing the auth-stream listener).
Future<void> _pump(WidgetTester tester) async {
  final controller = StreamController<supabase.AuthState>.broadcast();
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => controller.stream);
  when(() => service.userHasProfile(any())).thenAnswer((_) async => false);
  when(() => service.verifyOtp(any(), any()))
      .thenThrow(const AuthException(
    'Token has expired',
    code: 'otp_expired',
  ));
  when(() => service.sendOtp(any())).thenAnswer((_) async {});
  when(() => service.signOut()).thenAnswer((_) async {
    controller.add(
      const supabase.AuthState(supabase.AuthChangeEvent.signedOut, null),
    );
  });

  final ban = _FakeBanService();
  when(() => ban.checkBanStatus(force: any(named: 'force')))
      .thenAnswer((_) async => BanStatus.notBanned);
  final prekeys = _FakePrekeyService();
  when(() => prekeys.publishAll()).thenAnswer((_) async {});
  when(() => prekeys.handleMissingSession()).thenAnswer((_) async {});
  when(() => prekeys.fetchBundle(any())).thenAnswer((_) async => null);

  final container = ProviderContainer(overrides: [
    authServiceProvider.overrideWithValue(service),
    banServiceProvider.overrideWithValue(ban),
    e2eePrekeyServiceProvider.overrideWithValue(prekeys),
  ]);
  addTearDown(container.dispose);

  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (_, _) =>
            const OtpVerificationScreen(email: 'a@b.com', password: 'secret1'),
      ),
      GoRoute(
        path: RoutePaths.ageGate,
        builder: (_, _) => const Scaffold(body: Text('age-gate-marker')),
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
}

void main() {
  testWidgets('rejected OTP renders the specific invalid-code error, clears '
      'the field and stays on the screen', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();

    expect(
      find.text('El código es incorrecto o ha expirado. Solicita uno nuevo.'),
      findsOneWidget,
    );
    // The field is cleared after the failure…
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    // …and the funnel does NOT advance.
    expect(find.text('age-gate-marker'), findsNothing);
    expect(find.byType(OtpVerificationScreen), findsOneWidget);
  });
}