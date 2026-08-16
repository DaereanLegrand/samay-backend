import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:samay/features/profile/providers/notification_prefs_provider.dart';

/// In-memory [HiveService] stand-in (same seam as theme_provider_test).
class _FakeHiveService implements HiveService {
  _FakeHiveService([Map<String, String>? initial]) : config = {...?initial};

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

/// R2: the notification-preference store loads the persisted toggles from the
/// encrypted local config cache, defaults everything on, persists each flip,
/// and degrades to defaults when the cache is unavailable.
void main() {
  group('NotificationPrefsNotifier', () {
    test('defaults every preference to enabled on an empty cache', () async {
      final container = makeContainer();

      final prefs = await container.read(notificationPrefsProvider.future);

      expect(prefs, {
        for (final pref in NotificationPrefsNotifier.prefs) pref.key: true,
      });
    });

    test('loads persisted false values from the config cache', () async {
      final container = makeContainer(
        hive: _FakeHiveService({'notifications.event_reminders': 'false'}),
      );

      final prefs = await container.read(notificationPrefsProvider.future);

      expect(prefs['notifications.event_reminders'], isFalse);
      expect(prefs['notifications.friend_requests'], isTrue);
    });

    test('set persists the flip under the preference key', () async {
      final hive = _FakeHiveService();
      final container = makeContainer(hive: hive);

      await container.read(notificationPrefsProvider.future);
      await container
          .read(notificationPrefsProvider.notifier)
          .set('notifications.friend_requests', false);

      expect(
        container
            .read(notificationPrefsProvider)
            .value?['notifications.friend_requests'],
        isFalse,
      );
      expect(
        hive.config['notifications.friend_requests'],
        'false',
        reason: 'R2 — the toggle must be persisted on-device',
      );
    });

    test(
      'a persisted choice survives a provider rebuild (roundtrip)',
      () async {
        final hive = _FakeHiveService();
        final first = makeContainer(hive: hive);

        await first.read(notificationPrefsProvider.future);
        await first
            .read(notificationPrefsProvider.notifier)
            .set('notifications.chat_messages', false);
        first.dispose();

        final second = makeContainer(hive: hive);
        addTearDown(second.dispose);

        final prefs = await second.read(notificationPrefsProvider.future);
        expect(prefs['notifications.chat_messages'], isFalse);
      },
    );

    test('uninitialized Hive degrades to defaults without throwing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final prefs = await container.read(notificationPrefsProvider.future);

      expect(prefs, {
        for (final pref in NotificationPrefsNotifier.prefs) pref.key: true,
      });
    });
  });
}
