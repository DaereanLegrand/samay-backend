import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/models/friendship.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/services/discovery_service.dart';
import 'package:samay/core/services/friendship_service.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

class _MockUserService extends Mock implements UserService {}

class _MockFriendshipService extends Mock implements FriendshipService {}

class _MockDiscoveryService extends Mock implements DiscoveryService {}

const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _friendshipId = '33333333-3333-3333-3333-333333333333';

void main() {
  late _MockUserService users;
  late _MockFriendshipService friendships;
  late _MockDiscoveryService discovery;
  late FriendsRepository repo;

  setUp(() {
    users = _MockUserService();
    friendships = _MockFriendshipService();
    discovery = _MockDiscoveryService();
    repo = FriendsRepository(
      users: users,
      friendships: friendships,
      discovery: discovery,
    );
  });

  group('FriendsRepository.getUserProfile', () {
    test('delegates to UserService and returns a typed UserProfile', () async {
      when(() => users.getUserProfile(_userId)).thenAnswer((_) async => const {
            'id': _userId,
            'username': 'dana',
            'avatar_url': 'https://cdn.example/a.png',
            'bio': 'hola',
            'personal_shards': 120,
            'preshards': 3,
          });

      final profile = await repo.getUserProfile(_userId);

      verify(() => users.getUserProfile(_userId)).called(1);
      expect(profile, isA<UserProfile>());
      expect(profile!.id, _userId);
      expect(profile.username, 'dana');
      expect(profile.avatarUrl, 'https://cdn.example/a.png');
      expect(profile.personalShards, 120);
      expect(profile.preshards, 3);
    });

    test('propagates service errors unchanged', () async {
      when(() => users.getUserProfile(_userId)).thenThrow(
        const PostgrestException(
          message: 'permission denied for table users',
          code: '42501',
        ),
      );

      final err = await captureError(() => repo.getUserProfile(_userId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('FriendsRepository.getFriends', () {
    test('delegates and maps rows to FriendshipSummary', () async {
      when(() => friendships.getFriends()).thenAnswer((_) async => [
            {'friendship_id': _friendshipId, 'user_id': _otherId},
            {'friendship_id': '44444444-4444-4444-4444-444444444444',
             'user_id': '55555555-5555-5555-5555-555555555555'},
          ]);

      final friends = await repo.getFriends();

      verify(() => friendships.getFriends()).called(1);
      expect(friends, hasLength(2));
      expect(friends, isA<List<FriendshipSummary>>());
      expect(friends.first.friendshipId, _friendshipId);
      expect(friends.first.userId, _otherId);
    });
  });

  group('FriendsRepository map passthrough methods', () {
    test('searchUsers forwards the query via DiscoveryService', () async {
      when(() => discovery.searchUsers('ana')).thenAnswer((_) async => const [
            {'id': _otherId, 'username': 'ana', 'friendship_status': 'pending'},
          ]);

      final res = await repo.searchUsers('ana');

      verify(() => discovery.searchUsers('ana')).called(1);
      expect(res.single.friendshipStatus, 'pending',
          reason: 'the service enrichment must survive the repository');
    });

    test('getFriendRequests passes rows through', () async {
      when(() => friendships.getFriendRequests()).thenAnswer((_) async => const [
            {'type': 'received', 'friendship_id': _friendshipId,
             'user_id': _otherId, 'created_at': '2026-08-01T00:00:00Z'},
          ]);

      final rows = await repo.getFriendRequests();

      verify(() => friendships.getFriendRequests()).called(1);
      expect(rows.single.type, 'received');
    });

    test('getBlockedUsers passes rows through', () async {
      when(() => friendships.getBlockedUsers()).thenAnswer((_) async => const [
            {'blocked_user_id': _otherId},
          ]);

      final rows = await repo.getBlockedUsers();

      verify(() => friendships.getBlockedUsers()).called(1);
      expect(rows.single['blocked_user_id'], _otherId);
    });

    test('getFriendshipDetail passes the row through (requester_id intact)',
        () async {
      when(() => friendships.getFriendshipDetail(_otherId)).thenAnswer(
        (_) async => {'id': _friendshipId, 'status': 'pending',
                      'requester_id': _otherId},
      );

      final detail = await repo.getFriendshipDetail(_otherId);

      verify(() => friendships.getFriendshipDetail(_otherId)).called(1);
      expect(detail?['requester_id'], _otherId);
    });

    test('getFriendshipStatus / getFriendshipIdForUser / getBlockStatus forward',
        () async {
      when(() => friendships.getFriendshipStatus(_otherId))
          .thenAnswer((_) async => 'accepted');
      when(() => friendships.getFriendshipIdForUser(_otherId))
          .thenAnswer((_) async => _friendshipId);
      when(() => friendships.getBlockStatus(_otherId)).thenAnswer((_) async => true);

      expect(await repo.getFriendshipStatus(_otherId), 'accepted');
      expect(await repo.getFriendshipIdForUser(_otherId), _friendshipId);
      expect(await repo.getBlockStatus(_otherId), isTrue);

      verify(() => friendships.getFriendshipStatus(_otherId)).called(1);
      verify(() => friendships.getFriendshipIdForUser(_otherId)).called(1);
      verify(() => friendships.getBlockStatus(_otherId)).called(1);
    });
  });

  group('FriendsRepository mutations', () {
    test('sendFriendRequest forwards the target user id and its status',
        () async {
      when(() => friendships.sendFriendRequest(_otherId))
          .thenAnswer((_) async => 'accepted');

      final status = await repo.sendFriendRequest(_otherId);

      expect(status, 'accepted',
          reason: 'the repo passes the service status through (R15)');
      verify(() => friendships.sendFriendRequest(_otherId)).called(1);
    });

    test('accept/decline forward the friendship id', () async {
      when(() => friendships.acceptFriendRequest(_friendshipId))
          .thenAnswer((_) async {});
      when(() => friendships.declineFriendRequest(_friendshipId))
          .thenAnswer((_) async {});

      await repo.acceptFriendRequest(_friendshipId);
      await repo.declineFriendRequest(_friendshipId);

      verify(() => friendships.acceptFriendRequest(_friendshipId)).called(1);
      verify(() => friendships.declineFriendRequest(_friendshipId)).called(1);
    });

    test('block/unblock/removeFriend forward the user/friendship id', () async {
      when(() => friendships.blockUser(_otherId)).thenAnswer((_) async {});
      when(() => friendships.unblockUser(_otherId)).thenAnswer((_) async {});
      when(() => friendships.removeFriend(_friendshipId)).thenAnswer((_) async {});

      await repo.blockUser(_otherId);
      await repo.unblockUser(_otherId);
      await repo.removeFriend(_friendshipId);

      verify(() => friendships.blockUser(_otherId)).called(1);
      verify(() => friendships.unblockUser(_otherId)).called(1);
      verify(() => friendships.removeFriend(_friendshipId)).called(1);
    });

    test('propagates duplicate-request errors to the caller', () async {
      when(() => friendships.sendFriendRequest(_otherId))
          .thenThrow(Exception('Ya existe una solicitud o amistad con este usuario'));

      final err = await captureError(() => repo.sendFriendRequest(_otherId));
      expect(err, isA<Exception>());
    });
  });
}
