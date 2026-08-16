import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/providers/theme_provider.dart';
import 'package:samay/core/services/storage_service.dart';

/// In-memory [HiveService] stand-in (I-65): records writes, seeds reads —
/// no Hive init, no platform channels.
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

  @override
  Future<void> cacheMessage(String chatId, String messageId, String plaintext) async {}

  @override
  String? getCachedMessage(String chatId, String messageId) => null;

  @override
  Future<void> deleteCachedMessage(String chatId, String messageId) async {}

  @override
  Future<void> pruneCachedMessages(String chatId, int maxPerChat) async {}
}

ProviderContainer makeContainer({HiveService? hive}) {
  final container = ProviderContainer(
    overrides: [
      hiveServiceProvider.overrideWithValue(hive ?? _FakeHiveService()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// ThemeModeNotifier behavioral tests (I-65, UI-05/L-16): the provider loads
/// the persisted mode from the encrypted Hive config cache at startup,
/// persists every change, and degrades to dark when the cache is unavailable
/// (uninitialized Hive) or holds an unknown value.
void main() {
  group('ThemeModeNotifier', () {
    test('defaults to dark when the config cache is empty', () async {
      final container = makeContainer();

      final mode = await container.read(themeModeProvider.future);

      expect(mode, ThemeMode.dark);
      expect(container.read(themeModeProvider).value, ThemeMode.dark);
    });

    test('loads system from the config cache at startup', () async {
      final container = makeContainer(
        hive: _FakeHiveService({ThemeModeNotifier.configKey: 'system'}),
      );

      final mode = await container.read(themeModeProvider.future);

      expect(mode, ThemeMode.system);
    });

    test('unknown stored values fall back to dark', () async {
      final container = makeContainer(
        hive: _FakeHiveService({ThemeModeNotifier.configKey: 'light'}),
      );

      final mode = await container.read(themeModeProvider.future);

      expect(mode, ThemeMode.dark);
    });

    test('setThemeMode persists the choice under the config key', () async {
      final fake = _FakeHiveService();
      final container = makeContainer(hive: fake);

      await container.read(themeModeProvider.future);
      await container.read(themeModeProvider.notifier).setThemeMode(
        ThemeMode.system,
      );

      expect(container.read(themeModeProvider).value, ThemeMode.system);
      expect(fake.config[ThemeModeNotifier.configKey], 'system');

      await container.read(themeModeProvider.notifier).setThemeMode(
        ThemeMode.dark,
      );

      expect(container.read(themeModeProvider).value, ThemeMode.dark);
      expect(fake.config[ThemeModeNotifier.configKey], 'dark');
    });

    test('a persisted choice survives a provider rebuild (roundtrip)', () async {
      final fake = _FakeHiveService();
      final first = makeContainer(hive: fake);

      await first.read(themeModeProvider.future);
      await first
          .read(themeModeProvider.notifier)
          .setThemeMode(ThemeMode.system);
      first.dispose();

      final second = makeContainer(hive: fake);
      addTearDown(second.dispose);

      expect(await second.read(themeModeProvider.future), ThemeMode.system);
    });

    test('uninitialized Hive falls back to dark without throwing', () async {
      // No hiveServiceProvider override: the real HiveService is used while
      // the global Hive is NOT initialized in this process — the box access
      // throws and the provider must degrade to dark, never crash.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final mode = await container.read(themeModeProvider.future);

      expect(mode, ThemeMode.dark);
    });
  });
}
