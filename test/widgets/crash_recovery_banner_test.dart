import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/app.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/crash_recovery_banner.dart';

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState();
}

class _FakeHiveService implements HiveService {
  @override
  Future<void> init({bool initializeFlutter = true}) async {}

  @override
  Future<void> cacheConfig(Map<String, String> config) async {}

  @override
  Map<String, String>? getCachedConfig() => null;

  @override
  Future<void> cacheMessage(String chatId, String messageId, String plaintext) async {}

  @override
  String? getCachedMessage(String chatId, String messageId) => null;

  @override
  Future<void> deleteCachedMessage(String chatId, String messageId) async {}

  @override
  Future<void> pruneCachedMessages(String chatId, int maxPerChat) async {}
}

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

/// LOG-03 recovery-UI tests: the banner appears only when a recovered crash
/// marker was reported at launch, and dismissal is per-session.
void main() {
  group('CrashRecoveryBanner', () {
    testWidgets('renders nothing when there was no recovered crash', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const CrashRecoveryBanner()));

      expect(
        find.text('La app se recuperó de un cierre inesperado'),
        findsNothing,
      );
      expect(find.byType(CrashRecoveryBanner), findsOneWidget);
    });

    testWidgets(
      'shows the localized recovery copy when a crash was recovered',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const CrashRecoveryBanner(visible: true)),
        );

        expect(
          find.text('La app se recuperó de un cierre inesperado'),
          findsOneWidget,
        );
        expect(find.text('OK'), findsOneWidget);
      },
    );

    testWidgets('dismisses on OK and stays gone', (tester) async {
      await tester.pumpWidget(_wrap(const CrashRecoveryBanner(visible: true)));

      await tester.tap(find.text('OK'));
      await tester.pump();

      expect(
        find.text('La app se recuperó de un cierre inesperado'),
        findsNothing,
        reason: 'the banner is dismissible and collapses for the session',
      );
    });
  });

  group('SamayApp wiring', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          hiveServiceProvider.overrideWithValue(_FakeHiveService()),
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('recoveredFromCrash: true surfaces the banner above the app', (
      tester,
    ) async {
      final c = container();
      c.read(routerProvider).go(RoutePaths.welcome);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const SamayApp(recoveredFromCrash: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('La app se recuperó de un cierre inesperado'),
        findsOneWidget,
        reason: 'the flag from main() reaches the user-facing banner',
      );
    });

    testWidgets('recoveredFromCrash: false shows no banner', (tester) async {
      final c = container();
      c.read(routerProvider).go(RoutePaths.welcome);

      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SamayApp()),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('La app se recuperó de un cierre inesperado'),
        findsNothing,
      );
    });
  });
}
