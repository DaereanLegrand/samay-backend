import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/friendship.dart';

void main() {
  const friendshipId = 'f001e002-4003-4f04-8a05-6b07c08d09e0';
  const userId = '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60';

  group('FriendshipSummary', () {
    test('fromJson maps the getFriends row shape', () {
      final summary = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
      });
      expect(summary.friendshipId, friendshipId);
      expect(summary.userId, userId);
      expect(summary.status, isNull);
    });

    test('fromJson reads optional status', () {
      final summary = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
        'status': 'pending',
      });
      expect(summary.status, 'pending');
    });

    test('toJson emits snake_case DB column names', () {
      final json = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
      }).toJson();
      expect(json['friendship_id'], friendshipId);
      expect(json['user_id'], userId);
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
        'status': 'accepted',
      });
      expect(FriendshipSummary.fromJson(original.toJson()), original);
    });

    test('copyWith updates only the given field', () {
      final summary = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
      });
      final updated = summary.copyWith(status: 'blocked');
      expect(updated.status, 'blocked');
      expect(updated.userId, userId);
    });

    test('equality compares all fields', () {
      final a = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
      });
      final b = FriendshipSummary.fromJson({
        'friendship_id': friendshipId,
        'user_id': userId,
      });
      expect(a, b);
      expect(a.copyWith(userId: 'other'), isNot(a));
    });
  });
}
