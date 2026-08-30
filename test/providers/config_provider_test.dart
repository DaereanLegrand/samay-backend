import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/connectivity_service.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// In-memory [HiveService] stand-in (I-71): records writes, seeds reads —
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

  final Map<String, List<Map<String, dynamic>>> friends = {};

  @override
  Future<void> cacheFriends(String userId, List<Map<String, dynamic>> friends) async {
    this.friends[userId] = friends;
  }

  @override
  List<Map<String, dynamic>>? getCachedFriends(String userId) => friends[userId];

  @override
  Future<void> clearCachedFriends(String userId) async {
    friends.remove(userId);
  }
}

/// [HiveService] whose writes always fail — the fire-and-forget cache write
/// must be logged, never surfaced.
class _FailingHiveService extends _FakeHiveService {
  @override
  Future<void> cacheConfig(Map<String, String> config) async {
    throw StateError('disk full');
  }
}

/// AppConfigProvider behavioral tests (I-44 + I-71, H-09 + STOR): the
/// AsyncNotifier maps a ConfigService result/failure into AsyncValue, refreshes
/// via `refresh()` (invalidateSelf), writes every successful fetch through to
/// the encrypted Hive config cache, and serves the cached copy when the fetch
/// fails while offline ([connectivityProvider] false — the I-67 handoff).
/// Server errors while online are never masked.
void main() {
  late MockConfigService config;

  setUp(() {
    config = MockConfigService();
  });

  ProviderContainer makeContainer({
    Stream<bool>? connectivity,
    HiveService? hive,
  }) {
    final container = ProviderContainer(
      overrides: [
        configServiceProvider.overrideWithValue(config),
        // I-67: the provider watches connectivity, and the connectivity_plus
        // plugin cannot be listened to in tests — the seam is always
        // overridden (inert stream = never emits → optimistic online).
        connectivityServiceProvider.overrideWithValue(
          ConnectivityService(
            onConnectivityChanged: () =>
                connectivity ?? Stream<bool>.multi((_) {}),
          ),
        ),
        hiveServiceProvider.overrideWithValue(hive ?? _FakeHiveService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AppConfigProvider', () {
    // The connectivity flip → provider rebuild chain spans the stream event
    // delivery (external microtask) AND riverpod's internal scheduler (I-67
    // test pattern). Instead of racing fixed flushes, poll until the provider
    // leaves the loading state — bounded, deterministic in CI.
    Future<AsyncValue<Map<String, String>>> pumpUntilSettled(
      ProviderContainer container,
    ) async {
      for (var i = 0; i < 100; i++) {
        await pumpEventQueue();
        await container.pump();
        final state = container.read(appConfigProvider);
        if (state is! AsyncLoading) return state;
      }
      return container.read(appConfigProvider);
    }

    test('resolves to AsyncData with the fetched config', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer();

      final value = await container.read(appConfigProvider.future);

      expect(value, {'economy.user_signup_shards': '512'});
      expect(container.read(appConfigProvider), isA<AsyncData<Map<String, String>>>());
    });

    test('surfaces AsyncError when the fetch throws online', () async {
      when(() => config.fetchAppConfig()).thenThrow(
        const PostgrestException(
          message: 'permission denied for table app_config',
          code: '42501',
        ),
      );
      final container = makeContainer();

      await container
          .read(appConfigProvider.future)
          .catchError((_) => const <String, String>{});

      final state = container.read(appConfigProvider);
      expect(state, isA<AsyncError<Map<String, String>>>());
      expect(state.hasError, isTrue);
    });

    test('refresh() invalidates and re-fetches', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer();
      // A live listener keeps the provider alive across the invalidation.
      final sub = container.listen(appConfigProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(appConfigProvider.future);

      await container.read(appConfigProvider.notifier).refresh();
      // `pump()` flushes the container's scheduled reloads (microtasks +
      // timers) — the invalidate → rebuild cycle completes before we read.
      await container.pump();
      await container.read(appConfigProvider.future);

      // One fetch for the initial load, one for the post-refresh reload.
      verify(() => config.fetchAppConfig()).called(2);
    });

    test('re-fetches after external invalidation (UI retry pattern)', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer();
      final sub = container.listen(appConfigProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(appConfigProvider.future);

      container.invalidate(appConfigProvider);
      await container.pump();
      await container.read(appConfigProvider.future);

      verify(() => config.fetchAppConfig()).called(2);
    });

    test('a successful fetch persists the config to the cache', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final hive = _FakeHiveService();
      final container = makeContainer(hive: hive);

      await container.read(appConfigProvider.future);
      await container.pump();

      expect(hive.config, {'economy.user_signup_shards': '512'});
    });

    test('a cache write failure is logged, never surfaced', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer(hive: _FailingHiveService());

      await container.read(appConfigProvider.future);
      await container.pump();

      expect(
        container.read(appConfigProvider),
        isA<AsyncData<Map<String, String>>>(),
      );
    });

    test('offline failure serves the cached config', () async {
      when(() => config.fetchAppConfig()).thenThrow(
        const PostgrestException(message: 'connection refused', code: '503'),
      );
      final controller = StreamController<bool>.broadcast();
      addTearDown(controller.close);
      final container = makeContainer(
        connectivity: controller.stream,
        hive: _FakeHiveService({'economy.user_signup_shards': '128'}),
      );

      // First attempt: no connectivity event yet → optimistic online → error.
      final first = container.read(appConfigProvider.future);
      first.catchError((_) => const <String, String>{});
      await container.pump();
      expect(
        container.read(appConfigProvider),
        isA<AsyncError<Map<String, String>>>(),
      );

      // Connectivity flips offline → the provider re-runs → cache is served.
      controller.add(false);
      final state = await pumpUntilSettled(container);

      expect(state, isA<AsyncData<Map<String, String>>>());
      expect(state.value, {'economy.user_signup_shards': '128'});
    });

    test('offline failure with an empty cache still surfaces AsyncError',
        () async {
      when(() => config.fetchAppConfig()).thenThrow(
        const PostgrestException(message: 'connection refused', code: '503'),
      );
      final controller = StreamController<bool>.broadcast();
      addTearDown(controller.close);
      final container = makeContainer(connectivity: controller.stream);

      final first = container.read(appConfigProvider.future);
      first.catchError((_) => const <String, String>{});
      await container.pump();
      controller.add(false);
      final state = await pumpUntilSettled(container);

      expect(state, isA<AsyncError<Map<String, String>>>());
    });
  });

  group('hiveServiceProvider (promoted to service_providers.dart, I-71)', () {
    test('resolves a real HiveService without overrides', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(hiveServiceProvider), isA<HiveService>());
    });

    test('is overridable with an in-memory fake (test seam)', () {
      final container = makeContainer();
      expect(container.read(hiveServiceProvider), isA<_FakeHiveService>());
    });
  });
}
