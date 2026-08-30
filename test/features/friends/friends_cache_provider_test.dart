import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/friendship.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/services/storage_service.dart';
import 'package:samay/features/friends/providers/friends_cache_provider.dart';

const _uid = '11111111-1111-1111-1111-111111111111';
const _friendA = '22222222-2222-2222-2222-222222222222';
const _friendB = '33333333-3333-3333-3333-333333333333';

class _MockFriendsRepository extends Mock implements FriendsRepository {}

/// In-memory Hive stand-in — records the friends written per user.
class _FakeHiveService implements HiveService {
  final Map<String, List<Map<String, dynamic>>> friends = {};

  @override
  Future<void> init({bool initializeFlutter = true}) async {}

  @override
  Future<void> cacheConfig(Map<String, String> config) async {}

  @override
  Map<String, String>? getCachedConfig() => null;

  @override
  Future<void> cacheMessage(String chatId, String messageId, String plaintext) async {}

  @override
  String? getCachedMessage(String chatId, String messageId) => null;

  @override
  Future<void> deleteCachedMessage(String chatId, String messageId) async {}

  @override
  Future<void> pruneCachedMessages(String chatId, int maxPerChat) async {}

  @override
  Future<void> cacheFriends(String userId, List<Map<String, dynamic>> friends) async {
    this.friends[userId] = friends;
  }

  @override
  List<Map<String, dynamic>>? getCachedFriends(String userId) => friends[userId];

  @override
  Future<void> clearCachedFriends(String userId) async {
    friends.remove(userId);
  }
}

class _StubAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async => const AuthState(
        authenticated: true,
        hasProfile: true,
        user: {'id': _uid},
      );
}

void main() {
  test('cold cache: fetches friends (batched), persists to the device DB, '
      'returns them', () async {
    final repo = _MockFriendsRepository();
    when(() => repo.getFriends()).thenAnswer(
      (_) async => const [
        FriendshipSummary(friendshipId: 'f1', userId: _friendA),
        FriendshipSummary(friendshipId: 'f2', userId: _friendB),
      ],
    );
    when(() => repo.getUserSearchRows(any())).thenAnswer(
      (_) async => [
        {'id': _friendA, 'username': 'analia', 'avatar_url': null, 'bio': null},
        {'id': _friendB, 'username': 'lucas', 'avatar_url': null, 'bio': null},
      ],
    );

    final hive = _FakeHiveService();
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        friendsRepositoryProvider.overrideWithValue(repo),
        hiveServiceProvider.overrideWithValue(hive),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateProvider.future);

    final friends = await container.read(friendsCacheProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendA, _friendB],
      reason: 'friends are fetched + returned',
    );
    expect(
      friends.every((f) => f.friendshipStatus == 'accepted'),
      isTrue,
      reason: 'cached friends are shaped as accepted search rows',
    );
    expect(
      hive.friends.containsKey(_uid),
      isTrue,
      reason: 'the fetched friends are persisted to the device DB',
    );
    verify(() => repo.getUserSearchRows(any())).called(1);
  });

  test('a friend with an unresolvable/null-username profile is SKIPPED, the '
      'rest still land in the cache (never aborts the warm-up)', () async {
    final repo = _MockFriendsRepository();
    when(() => repo.getFriends()).thenAnswer(
      (_) async => const [
        FriendshipSummary(friendshipId: 'f1', userId: _friendA),
        FriendshipSummary(friendshipId: 'f2', userId: _friendB),
      ],
    );
    // _friendA resolves; _friendB is missing/null-username → dropped.
    when(() => repo.getUserSearchRows(any())).thenAnswer(
      (_) async => [
        {'id': _friendA, 'username': 'analia', 'avatar_url': null, 'bio': null},
      ],
    );

    final hive = _FakeHiveService();
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        friendsRepositoryProvider.overrideWithValue(repo),
        hiveServiceProvider.overrideWithValue(hive),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateProvider.future);

    final friends = await container.read(friendsCacheProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendA],
      reason: 'the resolvable friend survives; the bad one is skipped',
    );
    expect(
      hive.friends[_uid]?.length,
      1,
      reason: 'the cache persists only the resolvable friend',
    );
  });

  test('warm cache: reads from the device DB, NO network, NO error', () async {
    // Repo is NOT stubbed — a warm cache must never touch it.
    final hive = _FakeHiveService();
    hive.friends[_uid] = [
      const UserSearchResult(id: _friendA, username: 'analia').toJson(),
      const UserSearchResult(id: _friendB, username: 'lucas').toJson(),
    ];

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        hiveServiceProvider.overrideWithValue(hive),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateProvider.future);

    final friends = await container.read(friendsCacheProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendA, _friendB],
      reason: 'a warm cache serves the friends without any fetch',
    );
  });

  test('an empty cold cache (signed out / no friends) resolves to [], never '
      'throws', () async {
    final hive = _FakeHiveService();
    final repo = _MockFriendsRepository();
    when(() => repo.getFriends()).thenThrow(Exception('network down'));

    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        friendsRepositoryProvider.overrideWithValue(repo),
        hiveServiceProvider.overrideWithValue(hive),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateProvider.future);

    final friends = await container.read(friendsCacheProvider.future);

    expect(friends, isEmpty);
  });

  test('refresh() clears the device-DB entry and re-fetches', () async {
    final repo = _MockFriendsRepository();
    when(() => repo.getFriends()).thenAnswer(
      (_) async => const [FriendshipSummary(friendshipId: 'f1', userId: _friendA)],
    );
    when(() => repo.getUserSearchRows(any())).thenAnswer(
      (_) async => [
        {'id': _friendA, 'username': 'analia', 'avatar_url': null, 'bio': null},
      ],
    );

    final hive = _FakeHiveService();
    final container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_StubAuthNotifier.new),
        friendsRepositoryProvider.overrideWithValue(repo),
        hiveServiceProvider.overrideWithValue(hive),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authStateProvider.future);
    await container.read(friendsCacheProvider.future);
    expect(hive.friends.containsKey(_uid), isTrue);

    await container.read(friendsCacheProvider.notifier).refresh();
    await container.read(friendsCacheProvider.future);

    expect(
      hive.friends.containsKey(_uid),
      isTrue,
      reason: 'refresh clears + re-fetches (still persisted)',
    );
  });
}
