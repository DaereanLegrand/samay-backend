import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/friendship.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/repositories/chat_repository.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/profile_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/features/chat/chat_providers.dart';
import 'package:samay/features/friends/friends_providers.dart';
import 'package:samay/features/groups/groups_providers.dart';
import 'package:samay/features/profile/profile_providers.dart' as profile;

class _MockFriendsRepository extends Mock implements FriendsRepository {}

class _MockGroupsRepository extends Mock implements GroupsRepository {}

class _MockProfileRepository extends Mock implements ProfileRepository {}

class _MockChatRepository extends Mock implements ChatRepository {}

const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _groupId = '33333333-3333-3333-3333-333333333333';

UserProfile _profile(String id, String username) => UserProfile.fromJson({
      'id': id,
      'username': username,
      'avatar_url': null,
    });

/// Reads a provider's future, absorbing the error so the AsyncError state can
/// be asserted (a thrown provider future fails the test otherwise).
Future<Object?> _readAbsorbed(Future<Object?> Function() read) async {
  try {
    await read();
  } on Object catch (e) {
    return e;
  }
  return null;
}

/// Notifiers that count `build` invocations so tests can assert the SM-09
/// refresh contract: `refresh()` re-runs `build()` via `ref.invalidateSelf()`.
class _CountingFriendsListNotifier extends FriendsListNotifier {
  int buildCount = 0;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    buildCount++;
    return [];
  }
}

class _CountingMyGroupsNotifier extends MyGroupsNotifier {
  int buildCount = 0;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    buildCount++;
    return [];
  }
}

class _CountingMyProfileNotifier extends profile.MyProfileNotifier {
  int buildCount = 0;

  @override
  Future<Map<String, dynamic>?> build() async {
    buildCount++;
    return null;
  }
}

class _CountingProfileGroupsNotifier extends profile.ProfileGroupsNotifier {
  int buildCount = 0;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    buildCount++;
    return [];
  }
}

class _CountingLeaderboardNotifier extends LeaderboardNotifier {
  int buildCount = 0;

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    buildCount++;
    return [];
  }
}

class _CountingSearchResultsNotifier extends SearchResultsNotifier {
  int buildCount = 0;

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    buildCount++;
    return [];
  }
}

/// Notifiers whose `build` always throws — the TST-05/H-18 error-state seam
/// (same pattern as `profile_providers_test.dart`): the providers call
/// `SupabaseService.instance` directly, so the established subclass-stub
/// pattern pins the AsyncError state the UI consumes. The underlying
/// service behaviors (search filter pass, contributions aggregation) are
/// covered at the service layer in `test/services/*_test.dart`.
class _ThrowingFriendsListNotifier extends FriendsListNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    throw StateError('friends list unavailable');
  }
}

class _ThrowingFriendRequestsNotifier extends FriendRequestsNotifier {
  @override
  Future<FriendRequestsData> build() async {
    throw StateError('requests unavailable');
  }
}

class _ThrowingSearchResultsNotifier extends SearchResultsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    throw StateError('search unavailable');
  }
}

class _ThrowingMyGroupsNotifier extends MyGroupsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    throw StateError('groups unavailable');
  }
}

class _ThrowingGroupDetailNotifier extends GroupDetailNotifier {
  @override
  Future<Map<String, dynamic>?> build(String arg) async {
    throw StateError('group unavailable');
  }
}

class _ThrowingContributionsNotifier extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async {
    throw StateError('contributions unavailable');
  }
}

class _ThrowingLeaderboardNotifier extends LeaderboardNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    throw StateError('leaderboard unavailable');
  }
}

class _ThrowingBlockedUsersNotifier extends BlockedUsersNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    throw StateError('blocked users unavailable');
  }
}

class _ThrowingGroupInvitesNotifier extends GroupInvitesNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    throw StateError('group invites unavailable');
  }
}

void main() {
  group('friends providers (I-12)', () {
    test('friendsListProvider refresh() re-runs build', () async {
      final container = ProviderContainer(
        overrides: [friendsListProvider.overrideWith(_CountingFriendsListNotifier.new)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(friendsListProvider.notifier) as _CountingFriendsListNotifier;

      await container.read(friendsListProvider.future);
      expect(notifier.buildCount, 1);
      expect(container.read(friendsListProvider).value, isEmpty);

      await notifier.refresh();
      await container.read(friendsListProvider.future);
      expect(notifier.buildCount, 2);
    });

    test('searchResultsProvider keeps family instances per query', () async {
      final container = ProviderContainer(
        overrides: [searchResultsProvider.overrideWith(_CountingSearchResultsNotifier.new)],
      );
      addTearDown(container.dispose);

      await container.read(searchResultsProvider('ana').future);
      await container.read(searchResultsProvider('lucas').future);
      expect(container.read(searchResultsProvider('ana')).value, isEmpty);
      expect(container.read(searchResultsProvider('lucas')).value, isEmpty);

      final notifier =
          container.read(searchResultsProvider('ana').notifier) as _CountingSearchResultsNotifier;
      expect(notifier.buildCount, 1);
    });
  });

  group('groups providers (I-12)', () {
    test('myGroupsProvider refresh() re-runs build', () async {
      final container = ProviderContainer(
        overrides: [myGroupsProvider.overrideWith(_CountingMyGroupsNotifier.new)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(myGroupsProvider.notifier) as _CountingMyGroupsNotifier;

      await container.read(myGroupsProvider.future);
      expect(notifier.buildCount, 1);

      await notifier.refresh();
      await container.read(myGroupsProvider.future);
      expect(notifier.buildCount, 2);
    });

    test('leaderboardProvider refresh() re-runs build for the same tier',
        () async {
      final container = ProviderContainer(
        overrides: [leaderboardProvider.overrideWith(_CountingLeaderboardNotifier.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(leaderboardProvider('micro').notifier) as _CountingLeaderboardNotifier;

      await container.read(leaderboardProvider('micro').future);
      expect(notifier.buildCount, 1);

      await notifier.refresh();
      await container.read(leaderboardProvider('micro').future);
      expect(notifier.buildCount, 2);
    });
  });

  group('profile providers (I-12, screens wired by I-13)', () {
    test('myProfileProvider refresh() re-runs build', () async {
      final container = ProviderContainer(
        overrides: [
          profile.myProfileProvider.overrideWith(_CountingMyProfileNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(profile.myProfileProvider.notifier) as _CountingMyProfileNotifier;

      await container.read(profile.myProfileProvider.future);
      expect(notifier.buildCount, 1);

      await notifier.refresh();
      await container.read(profile.myProfileProvider.future);
      expect(notifier.buildCount, 2);
    });

    test('profile myGroupsProvider refresh() re-runs build', () async {
      final container = ProviderContainer(
        overrides: [profile.myGroupsProvider.overrideWith(_CountingProfileGroupsNotifier.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(profile.myGroupsProvider.notifier) as _CountingProfileGroupsNotifier;

      await container.read(profile.myGroupsProvider.future);
      expect(notifier.buildCount, 1);

      await notifier.refresh();
      await container.read(profile.myGroupsProvider.future);
      expect(notifier.buildCount, 2);
    });
  });

  group('feature providers — error states (TST-05/H-18)', () {
    test('friendsListProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          friendsListProvider.overrideWith(_ThrowingFriendsListNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err =
          await _readAbsorbed(() => container.read(friendsListProvider.future));
      expect(err, isA<StateError>());
      expect(container.read(friendsListProvider),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });

    test('friendRequestsProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          friendRequestsProvider
              .overrideWith(_ThrowingFriendRequestsNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(friendRequestsProvider.future));
      expect(err, isA<StateError>());
      expect(container.read(friendRequestsProvider),
          isA<AsyncError<FriendRequestsData>>());
    });

    test('searchResultsProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          searchResultsProvider
              .overrideWith(_ThrowingSearchResultsNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(searchResultsProvider('ana').future));
      expect(err, isA<StateError>());
      expect(container.read(searchResultsProvider('ana')),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });

    test('myGroupsProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          myGroupsProvider.overrideWith(_ThrowingMyGroupsNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(myGroupsProvider.future));
      expect(err, isA<StateError>());
      expect(container.read(myGroupsProvider),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });

    test('groupDetailProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          groupDetailProvider.overrideWith(_ThrowingGroupDetailNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(groupDetailProvider('g-1').future));
      expect(err, isA<StateError>());
      expect(container.read(groupDetailProvider('g-1')),
          isA<AsyncError<Map<String, dynamic>?>>());
    });

    test('contributionsProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          contributionsProvider
              .overrideWith(_ThrowingContributionsNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(contributionsProvider('g-1').future));
      expect(err, isA<StateError>());
      expect(container.read(contributionsProvider('g-1')),
          isA<AsyncError<GroupContributionsData>>());
    });

    test('leaderboardProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          leaderboardProvider.overrideWith(_ThrowingLeaderboardNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(leaderboardProvider('micro').future));
      expect(err, isA<StateError>());
      expect(container.read(leaderboardProvider('micro')),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });

    test('blockedUsersProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          blockedUsersProvider.overrideWith(_ThrowingBlockedUsersNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(blockedUsersProvider.future));
      expect(err, isA<StateError>());
      expect(container.read(blockedUsersProvider),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });

    test('groupInvitesProvider failure surfaces AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          groupInvitesProvider.overrideWith(_ThrowingGroupInvitesNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      final err = await _readAbsorbed(
          () => container.read(groupInvitesProvider.future));
      expect(err, isA<StateError>());
      expect(container.read(groupInvitesProvider),
          isA<AsyncError<List<Map<String, dynamic>>>>());
    });
  });

  group('feature providers → repositories (I-50 delegation)', () {
    test('friendsListProvider fetches each friend profile via the repository',
        () async {
      final repo = _MockFriendsRepository();
      when(() => repo.getFriends()).thenAnswer((_) async => [
            FriendshipSummary(friendshipId: 'f1', userId: _otherId),
          ]);
      when(() => repo.getUserProfile(_otherId))
          .thenAnswer((_) async => _profile(_otherId, 'ana'));
      final container = ProviderContainer(
        overrides: [friendsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(friendsListProvider.future);

      verify(() => repo.getFriends()).called(1);
      verify(() => repo.getUserProfile(_otherId)).called(1);
      expect(state.single['username'], 'ana');
    });

    test('searchResultsProvider forwards the query to the repository',
        () async {
      final repo = _MockFriendsRepository();
      when(() => repo.searchUsers('ana')).thenAnswer((_) async => const [
            {'id': _otherId, 'username': 'ana', 'friendship_status': 'pending'},
          ]);
      final container = ProviderContainer(
        overrides: [friendsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(searchResultsProvider('ana').future);

      verify(() => repo.searchUsers('ana')).called(1);
      expect(state.single['friendship_status'], 'pending');
    });

    test('myGroupsProvider delegates to the groups repository', () async {
      final repo = _MockGroupsRepository();
      when(() => repo.getMyGroups()).thenAnswer((_) async => const [
            Group(id: _groupId, name: 'Disco Crew', myRole: 'promotor'),
          ]);
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(myGroupsProvider.future);

      verify(() => repo.getMyGroups()).called(1);
      expect(state.single['my_role'], 'promotor');
    });

    test('groupDetailProvider delegates to the groups repository per id',
        () async {
      final repo = _MockGroupsRepository();
      when(() => repo.getGroup(_groupId))
          .thenAnswer((_) async => const Group(id: _groupId, name: 'Crew'));
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(groupDetailProvider(_groupId).future);

      verify(() => repo.getGroup(_groupId)).called(1);
      expect(state?['name'], 'Crew');
    });

    test('contributionsProvider aggregates via the repository', () async {
      final repo = _MockGroupsRepository();
      when(() => repo.getGroupContributions(_groupId))
          .thenAnswer((_) async => const [
                {'user_id': _userId, 'shards_contributed': 50,
                 'users': {'username': 'ana'}},
              ]);
      when(() => repo.getUserContributionToGroup(_groupId))
          .thenAnswer((_) async => 30);
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(contributionsProvider(_groupId).future);

      verify(() => repo.getGroupContributions(_groupId)).called(1);
      verify(() => repo.getUserContributionToGroup(_groupId)).called(1);
      expect(state.myContribution, 30);
      expect(state.contributors.single['shards_contributed'], 50);
    });

    test('leaderboardProvider enriches snapshot rows via the repository',
        () async {
      final repo = _MockGroupsRepository();
      when(() => repo.getLeaderboard('micro')).thenAnswer((_) async => const [
            {'group_id': _groupId, 'rank_position': 1, 'score': 500,
             'member_count': 12},
          ]);
      when(() => repo.getGroup(_groupId))
          .thenAnswer((_) async => const Group(id: _groupId, name: 'Crew'));
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(leaderboardProvider('micro').future);

      verify(() => repo.getLeaderboard('micro')).called(1);
      verify(() => repo.getGroup(_groupId)).called(1);
      expect(state.single['score'], 500);
      expect(state.single['name'], 'Crew');
    });

    test('myProfileProvider reads the profile repository', () async {
      final repo = _MockProfileRepository();
      when(() => repo.getMyProfile())
          .thenAnswer((_) async => _profile(_userId, 'dana'));
      final container = ProviderContainer(
        overrides: [profileRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(profile.myProfileProvider.future);

      verify(() => repo.getMyProfile()).called(1);
      expect(state?['username'], 'dana');
    });

    test('profile myGroupsProvider delegates to the groups repository',
        () async {
      final repo = _MockGroupsRepository();
      when(() => repo.getMyGroups()).thenAnswer((_) async => const [
            Group(id: _groupId, name: 'Fiesta Club', groupShards: 42),
          ]);
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(profile.myGroupsProvider.future);

      verify(() => repo.getMyGroups()).called(1);
      expect(state.single['group_shards'], 42);
    });

    test('chatMessagesProvider loads messages via the chat repository',
        () async {
      final repo = _MockChatRepository();
      when(() => repo.loadMessages(_groupId, limit: any(named: 'limit'),
              offset: any(named: 'offset')))
          .thenAnswer((_) async => const [
                {'id': 'm-1', 'sender_id': _userId, 'content': 'hola',
                 'media_url': null, 'created_at': '2026-08-01T00:00:00Z'},
              ]);
      final container = ProviderContainer(
        overrides: [chatE2eeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final state = await container.read(chatMessagesProvider(_groupId).future);

      verify(() => repo.loadMessages(_groupId, limit: 50, offset: 0)).called(1);
      expect(state.messages.single['content'], 'hola');
      expect(state.hasMore, isFalse); // short page → no older history
    });
  });
}
