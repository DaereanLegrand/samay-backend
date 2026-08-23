import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/profile/providers/profile_providers.dart' as profile;

/// U-17 R20 ledger tests (2026-08-11): the 15s refetch throttle on the
/// shell-tab providers' `refresh()` paths (Juega's `lastFetchedAt` guard,
/// U-13 §5.4). The ledger lives in
/// the shell-flow work that introduced the throttled refresh.
///
/// Every notifier in the three R20 files (groups/friends/profile providers)
/// must skip `refresh()` while the last fetch is younger than the throttle
/// window and refetch once it has aged. The counting subclasses below shrink
/// the window to 50ms so the "after → refetch" half runs on real timers.

const _window = Duration(milliseconds: 50);

/// Runs the R20 contract: initial build → refresh within the window (no
/// refetch) → refresh after the window (refetch).
Future<void> expectThrottledRefresh({
  required int Function() buildCount,
  required Future<void> Function() refresh,
  required Future<void> Function() settle,
}) async {
  expect(buildCount(), 1, reason: 'initial build');
  await refresh();
  await settle();
  expect(buildCount(), 1, reason: 'refresh within the window must skip (R20)');
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await refresh();
  await settle();
  expect(buildCount(), 2, reason: 'refresh after the window must refetch (R20)');
}

class _CountingMyGroups extends MyGroupsNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<Group>> build() async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingGroupDetail extends GroupDetailNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<Group?> build(String arg) async {
    builds++;
    markFetched();
    return null;
  }
}

class _CountingGroupMembers extends GroupMembersNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<GroupMember>> build(String arg) async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingContributions extends GroupContributionsNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<GroupContributionsData> build(String arg) async {
    builds++;
    markFetched();
    return const GroupContributionsData(contributors: [], myContribution: 0);
  }
}

class _CountingGroupInvites extends GroupInvitesNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingLeaderboard extends LeaderboardNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<LeaderboardEntry>> build(String arg) async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingFriendsList extends FriendsListNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<UserProfile>> build() async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingFriendRequests extends FriendRequestsNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<FriendRequestsData> build() async {
    builds++;
    markFetched();
    return const FriendRequestsData(requests: [], names: {});
  }
}

class _CountingBlockedUsers extends BlockedUsersNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<UserProfile>> build() async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingSearchResults extends SearchResultsNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<UserSearchResult>> build(String arg) async {
    builds++;
    markFetched();
    return const [];
  }
}

class _CountingMyProfile extends profile.MyProfileNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<Map<String, dynamic>?> build() async {
    builds++;
    markFetched();
    return null;
  }
}

class _CountingProfileGroups extends profile.ProfileGroupsNotifier {
  int builds = 0;

  @override
  Duration get refreshThrottle => _window;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    markFetched();
    return const [];
  }
}

void main() {
  group('R20 — 15s refresh throttle (U-13 §5.4)', () {
    test('myGroupsProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [myGroupsProvider.overrideWith(_CountingMyGroups.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(myGroupsProvider.notifier) as _CountingMyGroups;

      await container.read(myGroupsProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(myGroupsProvider.future),
      );
    });

    test('groupDetailProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [groupDetailProvider.overrideWith(_CountingGroupDetail.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(groupDetailProvider('g-1').notifier)
              as _CountingGroupDetail;

      await container.read(groupDetailProvider('g-1').future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(groupDetailProvider('g-1').future),
      );
    });

    test('groupMembersProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [groupMembersProvider.overrideWith(_CountingGroupMembers.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(groupMembersProvider('g-1').notifier)
              as _CountingGroupMembers;

      await container.read(groupMembersProvider('g-1').future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(groupMembersProvider('g-1').future),
      );
    });

    test('contributionsProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [contributionsProvider.overrideWith(_CountingContributions.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(contributionsProvider('g-1').notifier)
              as _CountingContributions;

      await container.read(contributionsProvider('g-1').future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(contributionsProvider('g-1').future),
      );
    });

    test('groupInvitesProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [groupInvitesProvider.overrideWith(_CountingGroupInvites.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(groupInvitesProvider.notifier) as _CountingGroupInvites;

      await container.read(groupInvitesProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(groupInvitesProvider.future),
      );
    });

    test('leaderboardProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [leaderboardProvider.overrideWith(_CountingLeaderboard.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(leaderboardProvider('micro').notifier)
              as _CountingLeaderboard;

      await container.read(leaderboardProvider('micro').future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async =>
            container.read(leaderboardProvider('micro').future),
      );
    });

    test('friendsListProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [friendsListProvider.overrideWith(_CountingFriendsList.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(friendsListProvider.notifier) as _CountingFriendsList;

      await container.read(friendsListProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(friendsListProvider.future),
      );
    });

    test('friendRequestsProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [friendRequestsProvider.overrideWith(_CountingFriendRequests.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(friendRequestsProvider.notifier)
              as _CountingFriendRequests;

      await container.read(friendRequestsProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(friendRequestsProvider.future),
      );
    });

    test('blockedUsersProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [blockedUsersProvider.overrideWith(_CountingBlockedUsers.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(blockedUsersProvider.notifier) as _CountingBlockedUsers;

      await container.read(blockedUsersProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(blockedUsersProvider.future),
      );
    });

    test('searchResultsProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [searchResultsProvider.overrideWith(_CountingSearchResults.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(searchResultsProvider('ana').notifier)
              as _CountingSearchResults;

      await container.read(searchResultsProvider('ana').future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(searchResultsProvider('ana').future),
      );
    });

    test('myProfileProvider refresh() skips within the window and refetches '
        'after', () async {
      final container = ProviderContainer(
        overrides: [
          profile.myProfileProvider.overrideWith(_CountingMyProfile.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(profile.myProfileProvider.notifier)
              as _CountingMyProfile;

      await container.read(profile.myProfileProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(profile.myProfileProvider.future),
      );
    });

    test('profile myGroupsProvider refresh() skips within the window and '
        'refetches after', () async {
      final container = ProviderContainer(
        overrides: [profile.myGroupsProvider.overrideWith(_CountingProfileGroups.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(profile.myGroupsProvider.notifier)
              as _CountingProfileGroups;

      await container.read(profile.myGroupsProvider.future);
      await expectThrottledRefresh(
        buildCount: () => notifier.builds,
        refresh: () => notifier.refresh(),
        settle: () async => container.read(profile.myGroupsProvider.future),
      );
    });

    test('external invalidate() is never throttled — action-driven refreshes '
        'bypass the window (R20 must-not-mask-actions)', () async {
      final container = ProviderContainer(
        overrides: [myGroupsProvider.overrideWith(_CountingMyGroups.new)],
      );
      addTearDown(container.dispose);
      final notifier =
          container.read(myGroupsProvider.notifier) as _CountingMyGroups;

      await container.read(myGroupsProvider.future);
      expect(notifier.builds, 1);

      // The action pattern (accept/decline/create/leave screens call
      // `ref.invalidate(...)` directly, never `refresh()`).
      container.invalidate(myGroupsProvider);
      await container.read(myGroupsProvider.future);
      expect(notifier.builds, 2,
          reason: 'real invalidation from actions must never be masked (R20)');
    });
  });
}
