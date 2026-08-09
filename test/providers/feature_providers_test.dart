import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/friends/friends_providers.dart';
import 'package:samay/features/groups/groups_providers.dart';
import 'package:samay/features/profile/profile_providers.dart' as profile;

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
}
