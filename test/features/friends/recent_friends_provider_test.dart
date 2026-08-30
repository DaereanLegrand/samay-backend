import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';
import 'package:samay/features/friends/providers/friends_cache_provider.dart';
import 'package:samay/features/friends/providers/recent_friends_provider.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';

const _friendActiveChat = '11111111-1111-1111-1111-111111111111';
const _friendActiveGame = '22222222-2222-2222-2222-222222222222';
const _friendInactive = '33333333-3333-3333-3333-333333333333';

UserSearchResult _friend(String id, String username) => UserSearchResult(
  id: id,
  username: username,
  friendshipStatus: 'accepted',
);

/// Stubbed on-device friends cache — [recentFriendsProvider] now sources from
/// [friendsCacheProvider] (the disk/background-fetched cache), so tests stub
/// the cache directly. The cache's own fetch/persist contract is covered by
/// `friends_cache_provider_test.dart`.
class _FakeFriendsCacheNotifier extends FriendsCacheController {
  final List<UserSearchResult> data;
  _FakeFriendsCacheNotifier(this.data);

  @override
  Future<List<UserSearchResult>> build() async => data;
}

class _FakeChatInboxNotifier extends ChatInboxNotifier {
  final List<ChatInboxItem> inbox;
  _FakeChatInboxNotifier(this.inbox);

  @override
  Future<List<ChatInboxItem>> build() async => inbox;
}

class _FakeMySessionsNotifier extends MyMinigameSessionsNotifier {
  final List<Map<String, dynamic>> sessions;
  _FakeMySessionsNotifier([this.sessions = const []]);

  @override
  Future<List<Map<String, dynamic>>> build() async => sessions;
}

class _BoomChatInboxNotifier extends ChatInboxNotifier {
  @override
  Future<List<ChatInboxItem>> build() async => throw Exception('inbox down');
}

ChatInboxItem _inboxItem({
  required String peerId,
  required String lastMessageAt,
}) {
  return ChatInboxItem(
    chatId: 'chat-$peerId',
    type: 'direct',
    peerId: peerId,
    peerUsername: 'peer',
    lastMessageAt: DateTime.parse(lastMessageAt),
    unreadCount: 0,
  );
}

Map<String, dynamic> _session({
  required String id,
  required String createdAt,
  required List<String> participants,
}) {
  return {
    'id': id,
    'group_id': null,
    'game_type': 'truth_dare',
    'status': 'active',
    'shard_wager': 0,
    'player_limit': 8,
    'participants': participants,
    'winner_id': null,
    'created_at': createdAt,
    'name': null,
  };
}

void main() {
  test('orders friends by recency: chat, then minigame, then inactive', () async {
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendActiveChat, 'carlos'),
            _friend(_friendActiveGame, 'belen'),
            _friend(_friendInactive, 'ana'),
          ]),
        ),
        chatInboxProvider.overrideWith(
          () => _FakeChatInboxNotifier([
            _inboxItem(peerId: _friendActiveChat, lastMessageAt: '2026-08-28T12:00:00Z'),
          ]),
        ),
        myMinigameSessionsProvider.overrideWith(
          () => _FakeMySessionsNotifier([
            _session(
              id: 's1',
              createdAt: '2026-08-27T09:00:00Z',
              participants: [_friendActiveGame],
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Warm the recency inputs so the ordering is deterministic.
    await container.read(chatInboxProvider.future);
    await container.read(myMinigameSessionsProvider.future);

    final friends = await container.read(recentFriendsProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendActiveChat, _friendActiveGame, _friendInactive],
    );
    expect(
      friends.every((f) => f.friendshipStatus == 'accepted'),
      isTrue,
      reason: 'recent friends must be shaped like accepted search results',
    );
  });

  test('tie-broken by username ASC when activity ties', () async {
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendInactive, 'zeta'),
            _friend(_friendActiveChat, 'mario'),
            _friend(_friendActiveGame, 'lucia'),
          ]),
        ),
        chatInboxProvider.overrideWith(
          () => _FakeChatInboxNotifier([
            _inboxItem(peerId: _friendActiveChat, lastMessageAt: '2026-08-28T12:00:00Z'),
            _inboxItem(peerId: _friendActiveGame, lastMessageAt: '2026-08-28T12:00:00Z'),
          ]),
        ),
        myMinigameSessionsProvider.overrideWith(_FakeMySessionsNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatInboxProvider.future);
    await container.read(myMinigameSessionsProvider.future);
    final friends = await container.read(recentFriendsProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendActiveGame, _friendActiveChat, _friendInactive],
      reason: 'equal recency falls back to username order; the two active '
          'friends sort before the inactive one',
    );
  });

  test('an errored chat-inbox cache is skipped (never an error, never a fetch)',
      () async {
    final container = ProviderContainer(
      overrides: [
        friendsCacheProvider.overrideWith(
          () => _FakeFriendsCacheNotifier([
            _friend(_friendActiveGame, 'belen'),
            _friend(_friendInactive, 'ana'),
          ]),
        ),
        chatInboxProvider.overrideWith(_BoomChatInboxNotifier.new),
        myMinigameSessionsProvider.overrideWith(
          () => _FakeMySessionsNotifier([
            _session(
              id: 's1',
              createdAt: '2026-08-27T09:00:00Z',
              participants: [_friendActiveGame],
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(myMinigameSessionsProvider.future);

    final friends = await container.read(recentFriendsProvider.future);

    expect(
      [for (final f in friends) f.id],
      [_friendActiveGame, _friendInactive],
      reason: 'an errored chat cache must not block the friend list',
    );
  });
}
