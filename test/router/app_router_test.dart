import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:samay/core/router/app_router.dart';

void main() {
  group('AppRouter', () {
    test('routerProvider is defined', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(routerProvider), isNotNull);
    });
  });
}
