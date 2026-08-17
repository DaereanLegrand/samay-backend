
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// UserService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// profile operations only.
///
/// Friendship lifecycle tests → friendship_service_test.dart.
/// Search/discovery tests → discovery_service_test.dart.
///
/// The Postgrest chain is resolved without network by the shared
/// [ResolvingBuilder] subclass (I-11 MISTAKE block: mocktail cannot stub
/// `then` on Future-implementing classes).
const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _avatarUrl = 'https://cdn.example/avatars/$_userId/123.png';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  UserService service() => UserService(client: client);

  group('UserService.getUserProfile', () {
    test('own row → full users-table profile mapped to a Map', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'id': _userId,
          'username': 'dana',
          'avatar_url': _avatarUrl,
          'bio': 'hola',
          'personal_shards': 120,
          'preshards': 3,
        }),
      );

      final profile = await service().getUserProfile(_userId);

      expect(profile?['id'], _userId);
      expect(profile?['username'], 'dana');
      expect(profile?['personal_shards'], 120);
    });

    test('other user → security-barrier view profile (public columns)',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final view = MockQueryBuilder();
      when(() => client.from('user_search_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'id': _otherId,
          'username': 'other',
          'avatar_url': null,
          'bio': 'soy otro',
        }),
      );

      final profile = await service().getUserProfile(_otherId);

      expect(profile?['id'], _otherId);
      expect(profile?['username'], 'other');
      expect(profile?['bio'], 'soy otro');
      expect(profile?.containsKey('personal_shards'), isFalse);
    });

    test('returns null when the row does not exist (view path)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final view = MockQueryBuilder();
      when(() => client.from('user_search_view')).thenAnswer((_) => view);
      when(() => view.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getUserProfile(_otherId), isNull);
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final view = MockQueryBuilder();
      when(() => client.from('user_search_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenThrow(
        const PostgrestException(
          message: 'permission denied for table user_search_view',
          code: '42501',
        ),
      );

      final err = await captureError(() => service().getUserProfile(_otherId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('UserService.updateAvatarUrl (PRFL avatar flow — I-36)', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
    });

    test('updates users.avatar_url for the given user id', () async {
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      await service().updateAvatarUrl(_userId, _avatarUrl);

      verify(() => table.update({'avatar_url': _avatarUrl})).called(1);
      expect(update.filters.single.column, 'id');
      expect(update.filters.single.value, _userId);
    });

    test('surfaces update failures to the caller', () async {
      when(() => table.update(any()))
          .thenThrow(StateError('update rejected'));

      expect(
        () => service().updateAvatarUrl(_userId, _avatarUrl),
        throwsStateError,
      );
    });
  });

  group('UserService.updateBio', () {
    test('updates users.bio scoped to the user id', () async {
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      await service().updateBio(_userId, 'nueva bio');

      verify(() => table.update({'bio': 'nueva bio'})).called(1);
      expect(update.filters.single.column, 'id');
      expect(update.filters.single.value, _userId);
    });
  });

  group('UserService.getDiscoveryOptIn (PFND opt-in — I-60)', () {
    test('returns false when no row is returned', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getDiscoveryOptIn(), isFalse);
    });

    test('returns the stored opt-in value', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'discovery_opt_in': true}),
      );

      expect(await service().getDiscoveryOptIn(), isTrue);
    });

    test('returns false without a session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().getDiscoveryOptIn(), isFalse);
      verifyNever(() => client.from('users'));
    });
  });

  group('UserService.setDiscoveryOptIn (PFND opt-in — I-60)', () {
    test('updates users.discovery_opt_in scoped to the current user',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      await service().setDiscoveryOptIn(true);

      verify(() => table.update({'discovery_opt_in': true})).called(1);
      expect(update.filters.single.column, 'id');
      expect(update.filters.single.value, _userId);
    });
  });

  group('UserService.getMyInterestTags (PFND — I-60)', () {
    test('parses the PostgREST list form of interest_tags', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'interest_tags': ['musica', 'fiestas']},
        ),
      );

      final tags = await service().getMyInterestTags();

      expect(tags, ['fiestas', 'musica']);
    });

    test('parses a JSON-encoded interest_tags string', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'interest_tags': '["cine","viajes"]'},
        ),
      );

      final tags = await service().getMyInterestTags();

      expect(tags, ['cine', 'viajes']);
    });

    test('returns an empty list when the row has no tags', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'interest_tags': <String>[]},
        ),
      );

      expect(await service().getMyInterestTags(), isEmpty);
    });
  });
}
