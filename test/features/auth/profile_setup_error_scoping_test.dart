import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/auth/providers/auth_form_errors.dart';
import 'package:samay/features/auth/screens/profile_setup_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// REGRESSION (2026-08-24, user report): landing on "Completa tu perfil"
/// immediately showed a red "El código ha expirado. Solicita uno nuevo."
/// that was completely fake — the screen rendered the GLOBAL
/// `authStateProvider` error left behind by an earlier funnel step.
///
/// Contract after the fix:
/// 1. A pre-existing global auth error is NEVER rendered on entry.
/// 2. Field errors come only from this screen's own action (username policy
///    + the createProfile server error captured post-await).
class _PreErroredAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async {
    throw ValidationError(
      'código',
      'El código ha expirado. Solicita uno nuevo.',
    );
  }

  @override
  Future<void> createProfile(String username, {String? dateOfBirth}) async {
    state = AsyncData(
      (state.valueOrNull ?? const AuthState()).copyWith(hasProfile: true),
    );
  }
}

class _Harness {
  _Harness(this.container);

  final ProviderContainer container;
}

Future<_Harness> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [authStateProvider.overrideWith(_PreErroredAuthNotifier.new)],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(
        path: '/test',
        builder: (_, _) =>
            const ProfileSetupScreen(email: 'a@b.com', dateOfBirth: '2000-01-15'),
      ),
      GoRoute(
        path: RoutePaths.mainFeed,
        builder: (_, _) => const Scaffold(body: Text('main-feed-marker')),
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
  return _Harness(container);
}

void main() {
  testWidgets('entry with a stale global auth error renders NO error text', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.textContaining('expirado'), findsNothing);
    expect(find.textContaining('código'), findsNothing);
  });

  testWidgets('short username shows the SPECIFIC policy error and never '
      'reaches createProfile', (tester) async {
    final harness = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('Debe tener al menos 5 caracteres.'), findsOneWidget);
    // The field error rides VInput.errorText — rendered under the field.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.errorText, 'Debe tener al menos 5 caracteres.');
    expect(find.text('main-feed-marker'), findsNothing);
    expect(
      harness.container.read(signupErrorsProvider).usernameErrors,
      ['Debe tener al menos 5 caracteres.'],
    );
  });

  testWidgets('valid username clears errors, saves and navigates to feed', (
    tester,
  ) async {
    final harness = await _pump(tester);

    // Seed a stale error to prove the save path resets it.
    harness.container.read(signupErrorsProvider.notifier).setServerError(
          'El código ha expirado. Solicita uno nuevo.',
        );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sofia');
    await tester.tap(find.widgetWithText(TextButton, 'Guardar'));
    await tester.pumpAndSettle();

    expect(find.text('main-feed-marker'), findsOneWidget);
    expect(harness.container.read(signupErrorsProvider).displayText, isNull);
    expect(find.textContaining('expirado'), findsNothing);
  });
}
