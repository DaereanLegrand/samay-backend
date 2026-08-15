import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/realtime_service.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/providers/friendships_realtime_listener.dart';

import '../../support/resolving_builder.dart';

class MockRealtimeService extends Mock implements RealtimeService {}

/// FriendshipsRealtimeListener (2026-08-14): the shell-mounted listener
/// keeps the friends list / requests fresh on the REMOTE side — any
/// friendships row event touching the user invalidates both providers.
const _userId = '11111111-1111-1111-1111-111111111111';

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, user: {'id': _userId});
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

class _CountingFriendRequestsNotifier extends FriendRequestsNotifier {
  final List<int> onBuild;

  _CountingFriendRequestsNotifier(this.onBuild);

  @override
  Future<FriendRequestsData> build() async {
    onBuild.add(1);
    return const FriendRequestsData(requests: [], names: {});
  }
}

void main() {
  setUpAll(() {
    // mocktail cannot synthesize function-typed fallback values for `any()`.
    registerFallbackValue((Map<String, dynamic> _) {});
  });

  testWidgets('invalidates friends + requests providers on a remote '
      'friendships event', (tester) async {
    final realtime = MockRealtimeService();
    final channel = MockRealtimeChannel();
    when(() => channel.unsubscribe()).thenAnswer((_) async => 'ok');
    late void Function(Map<String, dynamic>) onChange;
    when(() => realtime.subscribeToFriendships(any())).thenAnswer((inv) async {
      onChange =
          inv.positionalArguments[0] as void Function(Map<String, dynamic>);
      return channel;
    });

    final friendsBuilds = <int>[];
    final requestsBuilds = <int>[];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
        realtimeServiceProvider.overrideWithValue(realtime),
        friendsListProvider.overrideWith(
          () => _CountingFriendsListNotifier(friendsBuilds),
        ),
        friendRequestsProvider.overrideWith(
          () => _CountingFriendRequestsNotifier(requestsBuilds),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: FriendshipsRealtimeListener()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The listener subscribes once the auth state resolves.
    expect(onChange, isNotNull,
        reason: 'the listener subscribes after the auth user resolves');

    // Warm both providers so invalidation is observable as a re-build.
    await container.read(friendsListProvider.future);
    await container.read(friendRequestsProvider.future);
    final buildsBefore = friendsBuilds.length + requestsBuilds.length;

    // Remote side accepts the request → friendships UPDATE row.
    onChange({
      'id': 'f-1',
      'requester_id': _userId,
      'addressee_id': '22222222-2222-2222-2222-222222222222',
      'status': 'accepted',
    });
    await tester.pump();

    await container.read(friendsListProvider.future);
    await container.read(friendRequestsProvider.future);

    expect(friendsBuilds.length + requestsBuilds.length,
        greaterThan(buildsBefore),
        reason: 'the event invalidated both providers');
  });
}
