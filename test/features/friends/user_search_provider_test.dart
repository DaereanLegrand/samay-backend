import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/features/friends/providers/friends_cache_provider.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/providers/recent_friends_provider.dart';
import 'package:samay/features/friends/providers/user_search_provider.dart';

const _friendA = '11111111-1111-1111-1111-111111111111';
const _friendB = '22222222-2222-2222-2222-222222222222';

UserSearchResult _friend(String id, String username) => UserSearchResult(
  id: id,
  username: username,
  friendshipStatus: 'accepted',
);

/// Stubbed on-device friends cache — [userSearchProvider] reads it (via
/// `recentFriendsProvider`) for empty + <5-char queries.
class _FakeFriendsCacheNotifier extends FriendsCacheController {
  final List<UserSearchResult> data;
  _FakeFriendsCacheNotifier(this.data);

  @override
  Future<List<UserSearchResult>> build() async => data;
}

/// Records every query the backend `search_users` provider is asked to
/// resolve, so tests can assert short queries never reach the backend.
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<UserSearchResult>> build(String arg) async {
    queries.add(arg);
    return const [];
  }
}

/// Fixed backend results — used to prove the ≥5 merge/dedup/friends-first.
class _FakeSearchResultsNotifier extends SearchResultsNotifier {
  final List<UserSearchResult> data;
  _FakeSearchResultsNotifier(this.data);

  @override
  Future<List<UserSearchResult>> build(String arg) async => data;
}

/// The exact reported scenario (2026-08-29 bug): an empty or <5-char query
/// must return the on-device cached friends with ZERO backend calls.
void main() {
  test('<5-char query returns the cached friends, never the backend', () async {
    final search = _RecordingSearchResultsNotifier();
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendA, 'analia'),
            _friend(_friendB, 'lucas'),
          ]),
        ),
        searchResultsProvider.overrideWith(() => search),
      ],
    );
    addTearDown(container.dispose);

    await container.read(recentFriendsProvider.future);

    final async = container.read(userSearchProvider('an'));
    final results = async.value ?? const <UserSearchResult>[];

    expect(
      [for (final r in results) r.id],
      [_friendA],
      reason: 'the <5-char query filters the cached friends on-device',
    );
    expect(
      search.queries,
      isEmpty,
      reason: 'a <5-char query must never reach search_users',
    );
  });

  test('EMPTY query returns ALL cached friends (must display the friend list)',
      () async {
    final search = _RecordingSearchResultsNotifier();
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendA, 'analia'),
            _friend(_friendB, 'lucas'),
          ]),
        ),
        searchResultsProvider.overrideWith(() => search),
      ],
    );
    addTearDown(container.dispose);

    await container.read(recentFriendsProvider.future);

    final async = container.read(userSearchProvider(''));
    final results = async.value ?? const <UserSearchResult>[];

    expect(
      [for (final r in results) r.id],
      [_friendA, _friendB],
      reason: 'the empty query must display the full cached friend list',
    );
    expect(search.queries, isEmpty);
  });

  test('>=5-char query merges backend + friends, friends first, deduped',
      () async {
    final backend = _FakeSearchResultsNotifier(const [
      UserSearchResult(id: _friendA, username: 'analia'),
      UserSearchResult(id: '44444444-4444-4444-4444-444444444444', username: 'andres'),
    ]);
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendA, 'analia'),
          ]),
        ),
        searchResultsProvider.overrideWith(() => backend),
      ],
    );
    addTearDown(container.dispose);

    await container.read(recentFriendsProvider.future);
    await container.read(searchResultsProvider('analia').future);

    final async = container.read(userSearchProvider('analia'));
    final results = async.value ?? const <UserSearchResult>[];

    expect(
      [for (final r in results) r.username],
      ['analia', 'andres'],
      reason:
          'analia is a friend returned by the backend too → deduped to one '
          'row, listed first; andres (stranger) after',
    );
    expect(
      results.where((r) => r.id == _friendA).length,
      1,
      reason: 'the friend/backend dupe appears exactly once',
    );
    expect(
      results.first.friendshipStatus,
      'accepted',
      reason: 'the friend row is first (friends-first)',
    );
  });
}
