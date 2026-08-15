import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/auth/providers/auth_scope_reset.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';

import '../../support/resolving_builder.dart';

/// AuthScopeReset (2026-08-14): ON LOGOUT, FLUSH ALL DATA — signing out
/// (or switching accounts) invalidates every user-scoped provider so no
/// cached data survives into the next session.
const _userA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _userB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

/// Controllable auth notifier: tests flip the session via [set].
class _FakeAuthNotifier extends AuthNotifier {
  AuthState _state = const AuthState();

  void set(AuthState state) {
    _state = state;
    ref.invalidateSelf();
  }

  @override
  Future<AuthState> build() async => _state;
}

class _CountingFriendsListNotifier extends FriendsListNotifier {
  final List<int> onBuild;

  _CountingFriendsListNotifier(this.onBuild);

  @override
  Future<List<Map<String, dynamic>>> build() async {
    onBuild.add(1);
    return <Map<String, dynamic>>[];
  }
}

void main() {
  testWidgets('logout flushes the friends list cache (no stale data '
      'survives the session)', (tester) async {
    final auth = _FakeAuthNotifier();
    final builds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(() => auth),
        friendsListProvider.overrideWith(
          () => _CountingFriendsListNotifier(builds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: AuthScopeReset()),
        ),
      ),
    );
    await tester.pump();

    // Session A: the friends list builds once and caches.
    auth.set(
      const AuthState(authenticated: true, user: {'id': _userA}),
    );
    await tester.pump();
    await container.read(friendsListProvider.future);
    expect(builds.length, 1);

    // Same-session refreshes do NOT flush (uid unchanged).
    auth.set(
      const AuthState(authenticated: true, user: {'id': _userA}),
    );
    await tester.pump();
    expect(builds.length, 1);

    // LOGOUT → the cache is flushed: the next read rebuilds.
    auth.set(const AuthState());
    await tester.pump();
    await container.read(friendsListProvider.future);
    expect(builds.length, greaterThan(1),
        reason: 'logout must flush the user-scoped cache');

    final afterLogout = builds.length;

    // New session as ANOTHER user → fresh data, not the previous account's.
    auth.set(
      const AuthState(authenticated: true, user: {'id': _userB}),
    );
    await tester.pump();
    await container.read(friendsListProvider.future);
    expect(builds.length, greaterThan(afterLogout),
        reason: 'a new account must never reuse the previous cache');
  });

  testWidgets('logout flushes the in-memory chat service — stale E2EE '
      'sessions/outbox must not survive a sign-out (2026-08-15: the '
      '"Mensaje no descifrable" bug survived sign-out because the ChatService '
      'singleton cached them)', (tester) async {
    final auth = _FakeAuthNotifier();
    final builds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(() => auth),
        chatE2eeServiceProvider.overrideWith((ref) {
          builds.add(1);
          return ChatService(
            client: MockSupabaseClient(),
            realtime: RealtimeService(client: MockSupabaseClient()),
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: AuthScopeReset()),
        ),
      ),
    );
    await tester.pump();

    // Session A: the chat service builds once and caches.
    auth.set(
      const AuthState(authenticated: true, user: {'id': _userA}),
    );
    await tester.pump();
    container.read(chatE2eeServiceProvider);
    expect(builds.length, 1);

    // Same-session refresh does NOT flush (uid unchanged).
    auth.set(
      const AuthState(authenticated: true, user: {'id': _userA}),
    );
    await tester.pump();
    expect(builds.length, 1);

    // LOGOUT → the service instance (and its in-memory session cache) is
    // flushed: the next read must rebuild a fresh service.
    auth.set(const AuthState());
    await tester.pump();
    container.read(chatE2eeServiceProvider);
    expect(builds.length, greaterThan(1),
        reason: 'logout must flush the chat service provider');
  });
}
