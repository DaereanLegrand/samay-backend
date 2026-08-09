import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// AppConfigProvider behavioral tests (I-44, TST-03/H-16 + TST-05/H-18):
/// the FutureProvider maps a ConfigService result/failure into AsyncValue.
void main() {
  late MockConfigService config;

  setUp(() {
    config = MockConfigService();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        configServiceProvider.overrideWithValue(config),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AppConfigProvider', () {
    test('resolves to AsyncData with the fetched config', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer();

      final value = await container.read(appConfigProvider.future);

      expect(value, {'economy.user_signup_shards': '512'});
      expect(container.read(appConfigProvider), isA<AsyncData<Map<String, String>>>());
    });

    test('surfaces AsyncError when the fetch throws', () async {
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

    test('re-fetches after invalidation (refresh pattern)', () async {
      when(() => config.fetchAppConfig())
          .thenAnswer((_) async => {'economy.user_signup_shards': '512'});
      final container = makeContainer();
      // A live listener keeps the provider alive across the invalidation.
      final sub = container.listen(appConfigProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(appConfigProvider.future);

      container.invalidate(appConfigProvider);
      // `pump()` flushes the container's scheduled reloads (microtasks +
      // timers) — the invalidate → rebuild cycle completes before we read.
      await container.pump();
      await container.read(appConfigProvider.future);

      // One fetch for the initial load, one for the post-invalidate reload.
      verify(() => config.fetchAppConfig()).called(2);
    });
  });
}
