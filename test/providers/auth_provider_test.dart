import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vive/core/providers/auth_provider.dart';

void main() {
  group('AuthProvider', () {
    test('initial state is unauthenticated', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(authStateProvider);
      expect(state.authenticated, isFalse);
    });

    test('initial state is not loading', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(authStateProvider);
      expect(state.loading, isFalse);
    });

    test('initial user is null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(authStateProvider);
      expect(state.user, isNull);
    });
  });
}
