import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/auth/providers/auth_form_errors.dart';

/// Flow-scoped auth error providers (2026-08-24 fake-OTP-error fix):
/// signup/login screens render ONLY these providers — never the global
/// `authStateProvider` error — so a stale/unrelated server error cannot
/// leak into a screen it does not belong to.
void main() {
  group('signupErrorsProvider', () {
    test('starts clean', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final errors = container.read(signupErrorsProvider);
      expect(errors.usernameErrors, isEmpty);
      expect(errors.serverError, isNull);
      expect(errors.displayText, isNull);
    });

    test('holds MULTIPLE username field errors together', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(signupErrorsProvider.notifier).setUsernameErrors([
        'El nombre de usuario es obligatorio.',
        'Debe tener al menos 5 caracteres.',
      ]);

      final errors = container.read(signupErrorsProvider);
      expect(errors.usernameErrors.length, 2);
      expect(errors.displayText, contains('\n'));
    });

    test('server error renders through displayText', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(signupErrorsProvider.notifier)
          .setServerError('El nombre de usuario ya existe');

      expect(
        container.read(signupErrorsProvider).displayText,
        'El nombre de usuario ya existe',
      );
    });

    test('clear resets field and server errors', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(signupErrorsProvider.notifier)
        ..setUsernameErrors(['x'])
        ..setServerError('y')
        ..clear();

      expect(notifier, same(container.read(signupErrorsProvider.notifier)));
      final errors = container.read(signupErrorsProvider);
      expect(errors.usernameErrors, isEmpty);
      expect(errors.serverError, isNull);
      expect(errors.displayText, isNull);
    });
  });

  group('loginErrorProvider', () {
    test('starts null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(loginErrorProvider), isNull);
    });

    test('set/clear round-trip', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(loginErrorProvider.notifier).set('boom');
      expect(container.read(loginErrorProvider), 'boom');

      container.read(loginErrorProvider.notifier).clear();
      expect(container.read(loginErrorProvider), isNull);
    });
  });
}
