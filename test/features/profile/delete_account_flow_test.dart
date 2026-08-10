import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/profile/screens/delete_account_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Records `deleteAccount` invocations on the real DeleteAccountScreen flow
/// (I-45, TST-07/M-14). The screen reads the current-user email directly from
/// `SupabaseService.instance.auth` (seeded via [support.initSupabaseHarness])
/// and delegates the deletion to the auth notifier, which this fake captures.
class _RecordingDeleteNotifier extends AuthNotifier {
  int deleteAccountCalls = 0;

  @override
  Future<AuthState> build() async => const AuthState();

  @override
  Future<void> deleteAccount() async {
    deleteAccountCalls++;
    state = const AsyncData(AuthState());
  }
}

Future<GoRouter> _pumpScreen(WidgetTester tester) async {
  final notifier = _RecordingDeleteNotifier();
  final container = ProviderContainer(
    overrides: [authStateProvider.overrideWith(() => notifier)],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/delete',
    routes: [
      GoRoute(path: '/delete', builder: (_, _) => const DeleteAccountScreen()),
      GoRoute(
        path: RoutePaths.login,
        builder: (_, _) => const Scaffold(body: Text('login-marker')),
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
  return router;
}

void main() {
  setUpAll(() async {
    // Seeded session: `SupabaseService.instance.auth.currentUser?.email`
    // resolves to 'user@samay.test' without any network.
    await support.initSupabaseHarness(sessionEmail: 'user@samay.test');
  });

  group('DeleteAccountScreen — confirmed delete (TST-07/M-14)', () {
    testWidgets('matching email → confirm dialog → deleteAccount called → '
        'navigates to login', (tester) async {
      await _pumpScreen(tester);

      await tester.enterText(
        find.byType(TextField),
        'USER@samay.test', // case-insensitive match
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Eliminar cuenta'));
      await tester.pumpAndSettle();

      expect(find.text('¿Eliminar cuenta?'), findsOneWidget);
      expect(find.textContaining('no se puede deshacer'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Eliminar'));
      await tester.pumpAndSettle();

      expect(find.text('login-marker'), findsOneWidget);
      expect(find.byType(DeleteAccountScreen), findsNothing);
    });

    testWidgets('non-matching email shows the mismatch snackbar and never '
        'opens the confirm dialog', (tester) async {
      await _pumpScreen(tester);

      await tester.enterText(find.byType(TextField), 'other@samay.test');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Eliminar cuenta'));
      await tester.pumpAndSettle();

      expect(find.text('El correo no coincide con tu cuenta'), findsOneWidget);
      expect(find.text('¿Eliminar cuenta?'), findsNothing);
    });
  });
}
