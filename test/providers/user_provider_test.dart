import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/providers/user_provider.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/ban_service.dart';

/// currentUserProvider tests (I-44, TST-03/H-16): the provider mirrors the
/// authenticated user from the auth state through AuthService.
const _user = {'id': '11111111-1111-1111-1111-111111111111', 'email': 'a@b.com'};

class _FakeAuthService extends Mock implements AuthService {}

class _FakeBanService extends Mock implements BanService {}

/// AuthService stub pinned to [user] (or null): no auth events, profile
/// probe fails closed, `getCurrentUser` replays the pinned value.
AuthService _serviceWithUser(Map<String, dynamic>? user) {
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => const Stream.empty());
  when(() => service.userHasProfile(any())).thenAnswer((_) async => true);
  when(() => service.getCurrentUser()).thenReturn(user);
  return service;
}

BanService _stubbedBanService() {
  final service = _FakeBanService();
  when(() => service.checkBanStatus(force: any(named: 'force')))
      .thenAnswer((_) async => BanStatus.notBanned);
  return service;
}

ProviderContainer _newContainer(AuthService service) {
  final container = ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(service),
      banServiceProvider.overrideWithValue(_stubbedBanService()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('currentUserProvider', () {
    test('resolves to null while unauthenticated', () async {
      final container = _newContainer(_serviceWithUser(null));

      final user = await container.read(currentUserProvider.future);

      expect(user, isNull);
    });

    test('resolves to the authenticated user', () async {
      final service = _serviceWithUser(_user);
      final container = _newContainer(service);
      // Settle the auth state first: currentUserProvider reads it via
      // `ref.watch`, so its first build while auth is still loading resolves
      // to null.
      await container.read(authStateProvider.future);

      final user = await container.read(currentUserProvider.future);

      expect(user, _user);
      // Once by the auth-state probe, once by currentUserProvider itself.
      verify(() => service.getCurrentUser()).called(2);
    });
  });
}
