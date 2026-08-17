import 'package:samay/core/providers/auth_provider.dart';

/// Minimal deterministic [AuthNotifier] for tests that need a signed-in user
/// but do not exercise auth flows. Returns [AuthState] with the given [userId]
/// (defaults to a standard test UUID). Injected via
/// `authStateProvider.overrideWith`, so no Supabase/network is ever touched.
///
/// Usage:
/// ```dart
/// authStateProvider.overrideWith(
///   () => StubAuthNotifier(userId: 'custom-uuid'),
/// );
/// ```
class StubAuthNotifier extends AuthNotifier {
  StubAuthNotifier({
    String userId = '11111111-1111-1111-1111-111111111111',
    this.authenticated = false,
    this.hasProfile = false,
  }) : _userId = userId;

  final String _userId;
  final bool authenticated;
  final bool hasProfile;

  @override
  Future<AuthState> build() async => AuthState(
        authenticated: authenticated,
        hasProfile: hasProfile,
        user: {'id': _userId},
      );
}
