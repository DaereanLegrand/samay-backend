import 'package:samay/core/providers/config_provider.dart';

/// Test-only [appConfigProvider] override (I-71): serves [config] without
/// touching [ConfigService], the connectivity stream, or the Hive cache.
///
/// After the AsyncNotifier migration (I-71) the legacy
/// `overrideWith((ref) async => config)` syntax no longer applies to
/// [appConfigProvider]; screen/router suites that need a deterministic
/// `app_config` override the provider with this notifier instead.
class FakeAppConfigNotifier extends AppConfigNotifier {
  FakeAppConfigNotifier(this.config);

  final Map<String, String> config;

  @override
  Future<Map<String, String>> build() async => config;
}

/// Variant that always fails [build] — screens must render their error state.
class FailingAppConfigNotifier extends AppConfigNotifier {
  FailingAppConfigNotifier(this.error);

  final Object error;

  @override
  Future<Map<String, String>> build() async => throw error;
}
