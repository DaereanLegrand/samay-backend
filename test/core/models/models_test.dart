import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/models.dart';

void main() {
  group('models barrel', () {
    test('exports all core models', () {
      expect(UserProfile, isA<Type>());
      expect(Group, isA<Type>());
      expect(GroupMember, isA<Type>());
      expect(FriendshipSummary, isA<Type>());
      expect(ChatMessage, isA<Type>());
      expect(NotificationItem, isA<Type>());
      expect(Event, isA<Type>());
    });
  });
}
