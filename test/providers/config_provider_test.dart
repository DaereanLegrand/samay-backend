import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vive/core/providers/config_provider.dart';

void main() {
  group('AppConfigProvider', () {
    test('config provider is defined', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(appConfigProvider), isA<AsyncValue<Map<String, String>>>());
    });
  });
}
