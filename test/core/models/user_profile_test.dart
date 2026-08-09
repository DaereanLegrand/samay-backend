import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/user_profile.dart';

void main() {
  const id = '5f7a5c0a-2b3e-4d5e-8f1a-9b2c3d4e5f60';
  final fixture = <String, dynamic>{
    'id': id,
    'username': 'luna',
    'avatar_url': 'https://cdn.example.test/avatars/luna.png',
    'date_of_birth': '1998-06-15',
    'bio': 'Noches de techno y amigos',
    'personal_shards': 320,
    'preshards': 12,
    'subscription_tier': 'pro',
    'deleted_at': null,
  };

  group('UserProfile', () {
    test('fromJson maps a Supabase users row', () {
      final profile = UserProfile.fromJson(fixture);
      expect(profile.id, id);
      expect(profile.username, 'luna');
      expect(profile.avatarUrl, 'https://cdn.example.test/avatars/luna.png');
      expect(profile.bio, 'Noches de techno y amigos');
      expect(profile.personalShards, 320);
      expect(profile.preshards, 12);
      expect(profile.subscriptionTier, 'pro');
      expect(profile.deletedAt, isNull);
      expect(profile.dateOfBirth, DateTime(1998, 6, 15));
    });

    test('fromJson applies defaults for missing economy/tier fields', () {
      final profile = UserProfile.fromJson({'id': id, 'username': 'nuevo'});
      expect(profile.personalShards, 0);
      expect(profile.preshards, 0);
      expect(profile.subscriptionTier, 'free');
    });

    test('fromJson handles null timestamps', () {
      final profile = UserProfile.fromJson({
        ...fixture,
        'deleted_at': '2026-08-01T10:30:00.000Z',
      });
      expect(profile.deletedAt, DateTime.parse('2026-08-01T10:30:00.000Z'));
    });

    test('toJson emits snake_case DB column names', () {
      final json = UserProfile.fromJson(fixture).toJson();
      expect(json['id'], id);
      expect(json['username'], 'luna');
      expect(json['avatar_url'], fixture['avatar_url']);
      expect(json['date_of_birth'], startsWith('1998-06-15'));
      expect(json['bio'], fixture['bio']);
      expect(json['personal_shards'], 320);
      expect(json['preshards'], 12);
      expect(json['subscription_tier'], 'pro');
      expect(json.containsKey('deleted_at'), isTrue);
      expect(json.keys, containsAll(fixture.keys));
    });

    test('roundtrip fromJson -> toJson preserves data', () {
      final original = UserProfile.fromJson(fixture);
      final roundtrip = UserProfile.fromJson(original.toJson());
      expect(roundtrip, original);
    });

    test('copyWith updates only the given field', () {
      final profile = UserProfile.fromJson(fixture);
      final updated = profile.copyWith(bio: 'Nuevo bio');
      expect(updated.bio, 'Nuevo bio');
      expect(updated.username, 'luna');
      expect(updated.personalShards, 320);
    });

    test('copyWith can clear nullable fields', () {
      final profile = UserProfile.fromJson(fixture);
      final cleared = profile.copyWith(avatarUrl: null);
      expect(cleared.avatarUrl, isNull);
      expect(cleared.username, 'luna');
    });

    test('equality compares all fields', () {
      expect(UserProfile.fromJson(fixture), UserProfile.fromJson(fixture));
      expect(
        UserProfile.fromJson(fixture).copyWith(username: 'otra'),
        isNot(UserProfile.fromJson(fixture)),
      );
    });
  });
}
