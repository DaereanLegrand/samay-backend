import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/app.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/theme_provider.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:samay/features/profile/settings_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// In-memory [HiveService] stand-in (I-65) — records writes, seeds reads.
class _FakeHiveService implements HiveService {
  _FakeHiveService([Map<String, String>? initial])
      : config = {...?initial};

  final Map<String, String> config;

  @override
  Future<void> init({bool initializeFlutter = true}) async {}

  @override
  Future<void> cacheConfig(Map<String, String> config) async {
    this.config.addAll(config);
  }

  @override
  Map<String, String>? getCachedConfig() =>
      config.isEmpty ? null : Map<String, String>.of(config);
}

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState();
}

/// UI-05 / L-16 (I-65): MaterialApp must resolve its [ThemeMode] from
/// [themeModeProvider] (persisted choice, default dark), and the settings
/// toggle must switch + persist it. Dark-only remains the brand (design doc
/// §1 P1) — 'system' is the future seam; it resolves to [SamayTheme.dark]
/// either way since both `theme` and `darkTheme` are the disco theme.
void main() {
  group('SamayApp theme wiring', () {
    testWidgets('defaults to dark when nothing is persisted', (tester) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          hiveServiceProvider.overrideWithValue(_FakeHiveService()),
          // I-67: inert connectivity seam (plugin-free test environment).
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(routerProvider).go(RoutePaths.welcome);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SamayApp(),
        ),
      );
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      expect(app.theme, SamayTheme.dark);
      expect(app.darkTheme, SamayTheme.dark);
    });

    testWidgets('loads the persisted system mode and applies it to the app',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          hiveServiceProvider.overrideWithValue(
            _FakeHiveService({ThemeModeNotifier.configKey: 'system'}),
          ),
          // I-67: inert connectivity seam (plugin-free test environment).
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(routerProvider).go(RoutePaths.welcome);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SamayApp(),
        ),
      );
      await tester.pumpAndSettle();

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
    });

    testWidgets('switching the provider re-wires MaterialApp and persists',
        (tester) async {
      final fake = _FakeHiveService();
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(_StubAuthNotifier.new),
          hiveServiceProvider.overrideWithValue(fake),
          // I-67: inert connectivity seam (plugin-free test environment).
          connectivityServiceProvider.overrideWithValue(
            ConnectivityService(
              onConnectivityChanged: () => Stream<bool>.multi((_) {}),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(routerProvider).go(RoutePaths.welcome);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SamayApp(),
        ),
      );
      await tester.pumpAndSettle();

      await container
          .read(themeModeProvider.notifier)
          .setThemeMode(ThemeMode.system);
      await tester.pumpAndSettle();

      var app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
      expect(fake.config[ThemeModeNotifier.configKey], 'system');

      await container
          .read(themeModeProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();

      app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      expect(fake.config[ThemeModeNotifier.configKey], 'dark');
    });
  });

  group('SettingsScreen theme toggle', () {
    Widget wrapSettings(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      );
    }

    testWidgets('renders the Tema section with Oscuro selected by default', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          hiveServiceProvider.overrideWithValue(_FakeHiveService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(wrapSettings(container));
      await tester.pumpAndSettle();

      expect(find.text('Tema'), findsOneWidget);
      expect(find.text('Oscuro'), findsOneWidget);
      expect(find.text('Sistema'), findsOneWidget);
      final segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.dark});
    });

    testWidgets('toggling to Sistema switches the provider and persists it', (
      tester,
    ) async {
      final fake = _FakeHiveService();
      final container = ProviderContainer(
        overrides: [
          hiveServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(wrapSettings(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sistema'));
      await tester.pumpAndSettle();

      var segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.system});
      expect(fake.config[ThemeModeNotifier.configKey], 'system');
      expect(
        container.read(themeModeProvider).value,
        ThemeMode.system,
      );

      await tester.tap(find.text('Oscuro'));
      await tester.pumpAndSettle();

      segmented = tester.widget<SegmentedButton<ThemeMode>>(
        find.byType(SegmentedButton<ThemeMode>),
      );
      expect(segmented.selected, {ThemeMode.dark});
      expect(fake.config[ThemeModeNotifier.configKey], 'dark');
    });
  });
}
