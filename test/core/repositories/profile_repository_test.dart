import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/repositories/profile_repository.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

class _MockUserService extends Mock implements UserService {}

class _MockGoTrueClient extends Mock implements GoTrueClient {}

const _userId = '11111111-1111-1111-1111-111111111111';
const _avatarUrl = 'https://cdn.example/avatars/1.png';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late _MockUserService users;
  late _MockGoTrueClient auth;
  late ProfileRepository repo;

  setUp(() {
    users = _MockUserService();
    auth = _MockGoTrueClient();
    when(() => users.auth).thenReturn(auth);
    repo = ProfileRepository(users: users);
  });

  group('ProfileRepository.getMyProfile', () {
    test('resolves the current user and returns the typed profile', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => users.getUserProfile(_userId)).thenAnswer((_) async => const {
            'id': _userId,
            'username': 'dana',
            'bio': 'hola',
            'personal_shards': 120,
            'preshards': 3,
          });

      final profile = await repo.getMyProfile();

      verify(() => auth.currentUser).called(1);
      verify(() => users.getUserProfile(_userId)).called(1);
      expect(profile, isA<UserProfile>());
      expect(profile!.username, 'dana');
      expect(profile.bio, 'hola');
      expect(profile.personalShards, 120);
    });

    test('returns null when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await repo.getMyProfile(), isNull);

      verifyNever(() => users.getUserProfile(any()));
    });

    test('propagates service errors', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => users.getUserProfile(_userId)).thenThrow(StateError('boom'));

      final err = await captureError(() => repo.getMyProfile());
      expect(err, isA<StateError>());
    });
  });

  group('ProfileRepository.updateBio', () {
    test('resolves the current user and calls UserService.updateBio', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => users.updateBio(_userId, 'nueva bio'))
          .thenAnswer((_) async {});

      await repo.updateBio('nueva bio');

      verify(() => users.updateBio(_userId, 'nueva bio')).called(1);
    });

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);

      final err = await captureError(() => repo.updateBio('bio'));
      expect(err, isA<Exception>());
      verifyNever(() => users.updateBio(any(), any()));
    });
  });

  group('ProfileRepository.updateAvatarUrl', () {
    test('resolves the current user and calls UserService.updateAvatarUrl',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => users.updateAvatarUrl(_userId, _avatarUrl))
          .thenAnswer((_) async {});

      await repo.updateAvatarUrl(_avatarUrl);

      verify(() => users.updateAvatarUrl(_userId, _avatarUrl)).called(1);
    });

    test('propagates update failures to the caller', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => users.updateAvatarUrl(_userId, _avatarUrl))
          .thenThrow(const PostgrestException(
            message: 'permission denied for table users',
            code: '42501',
          ));

      final err = await captureError(() => repo.updateAvatarUrl(_avatarUrl));
      expect(err, isA<PostgrestException>());
    });
  });
}
