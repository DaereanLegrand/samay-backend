import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/providers/user_provider.dart';
import 'package:samay/core/services/auth_service.dart';
import 'package:samay/core/services/ban_service.dart';

/// currentUserProvider tests (I-44, TST-03/H-16): the provider mirrors the
/// authenticated user from the auth state through AuthService.
const _userId = '11111111-1111-1111-1111-111111111111';

UserProfile _profile(String id, String username) => UserProfile.fromJson({
      'id': id,
      'username': username,
      'avatar_url': null,
    });

class _FakeAuthService extends Mock implements AuthService {}

class _FakeBanService extends Mock implements BanService {}

/// AuthService stub pinned to [profile] (or null): no auth events, profile
/// probe fails closed, `getCurrentUserProfile` replays the pinned value.
AuthService _serviceWithProfile(UserProfile? profile) {
  final service = _FakeAuthService();
  when(() => service.onAuthStateChange).thenAnswer((_) => const Stream.empty());
  when(() => service.userHasProfile(any())).thenAnswer((_) async => true);
  // _resolveInitialState calls getCurrentUser() to boot auth state — return
  // a minimal map so AuthState.authenticated becomes true.
  when(() => service.getCurrentUser()).thenReturn(
    profile != null ? {'id': profile.id, 'email': 'a@b.com'} : null,
  );
  when(() => service.getCurrentUserProfile()).thenAnswer((_) async => profile);
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
      final container = _newContainer(_serviceWithProfile(null));

      final user = await container.read(currentUserProvider.future);

      expect(user, isNull);
    });

    test('resolves to the authenticated user', () async {
      final profile = _profile(_userId, 'ana');
      final service = _serviceWithProfile(profile);
      final container = _newContainer(service);
      // Settle the auth state first: currentUserProvider reads it via
      // `ref.watch`, so its first build while auth is still loading resolves
      // to null.
      await container.read(authStateProvider.future);

      final user = await container.read(currentUserProvider.future);

      expect(user, profile);
    });
  });
}
