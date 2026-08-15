
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// UserService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// friendship lifecycle, search filtering and error propagation.
///
/// The Postgrest chain is resolved without network by the shared
/// [ResolvingBuilder] subclass (I-11 MISTAKE block: mocktail cannot stub
/// `then` on Future-implementing classes).
const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _thirdId = '33333333-3333-3333-3333-333333333333';
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
      // The view never exposes the sensitive columns.
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

  group('UserService.getFriendshipStatus', () {
    test('returns the status when the current user is the requester',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final requester = ResolvingBuilder<PostgrestList>({'status': 'accepted'});
      final addressee = ResolvingBuilder<PostgrestList>(null);
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? requester : addressee;
      });

      expect(await service().getFriendshipStatus(_otherId), 'accepted');
      expect(requester.filters[0].column, 'requester_id');
      expect(requester.filters[1].column, 'addressee_id');
    });

    test('returns the status when the current user is the addressee',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final requester = ResolvingBuilder<PostgrestList>(null);
      final addressee = ResolvingBuilder<PostgrestList>({'status': 'pending'});
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? requester : addressee;
      });

      expect(await service().getFriendshipStatus(_otherId), 'pending');
      expect(addressee.filters[0].column, 'requester_id');
      expect(addressee.filters[0].value, _otherId);
    });

    test('returns null when the session has no user', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().getFriendshipStatus(_otherId), isNull);
    });
  });

  group('UserService.sendFriendRequest', () {
    test('inserts a pending friendship when none exists and reports pending',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final probe = ResolvingBuilder<PostgrestList>(null);
      var selectCalls = 0;
      when(() => table.select('id')).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? probe : probe;
      });
      final insert = ResolvingBuilder<dynamic>(null);
      when(() => table.insert(any())).thenAnswer((_) => insert);

      final status = await service().sendFriendRequest(_otherId);

      expect(status, 'pending',
          reason: 'a fresh request reports pending (R15)');
      verify(() => table.insert({
        'requester_id': _userId,
        'addressee_id': _otherId,
        'status': 'pending',
      })).called(1);
    });

    test('throws when a friendship already exists (duplicate path)',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      when(() => table.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>({'id': 'fr-1'}));

      expect(
        () => service().sendFriendRequest(_otherId),
        throwsA(predicate((e) =>
            e is Exception && e.toString().contains('Ya existe'))),
      );
      verifyNever(() => table.insert(any()));
    });

    test(
        'accepts the reverse-direction request instantly and reports '
        'accepted (mutual, R15)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      var selectCalls = 0;
      when(() => table.select('id')).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1
            ? ResolvingBuilder<PostgrestList>(null)
            : ResolvingBuilder<PostgrestList>({'id': 'fr-rev'});
      });
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      final status = await service().sendFriendRequest(_otherId);

      expect(status, 'accepted',
          reason: 'a reverse pending request becomes an instant accept (R15)');
      verify(() => table.update({'status': 'accepted'})).called(1);
      expect(update.filters.single.value, 'fr-rev');
      verifyNever(() => table.insert(any()));
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().sendFriendRequest(_otherId),
          throwsA(isA<Exception>()));
    });

    test('propagates a duplicate-key PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      when(() => table.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));
      when(() => table.insert(any())).thenThrow(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint',
          code: '23505',
        ),
      );

      final err =
          await captureError(() => service().sendFriendRequest(_otherId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, ValidationError);
    });
  });

  group('UserService.getFriends', () {
    test('merges both directions into friend rows', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final asRequester = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-1',
          'requester_id': _userId,
          'addressee_id': _otherId,
          'status': 'accepted',
        },
      ]);
      final asAddressee = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-2',
          'requester_id': _thirdId,
          'addressee_id': _userId,
          'status': 'accepted',
        },
      ]);
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final friends = await service().getFriends();

      expect(friends, hasLength(2));
      expect(friends, containsAll([
        {'friendship_id': 'fr-1', 'user_id': _otherId},
        {'friendship_id': 'fr-2', 'user_id': _thirdId},
      ]));
      expect(asRequester.filters[1].value, 'accepted');
      expect(asAddressee.filters[1].value, 'accepted');
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().getFriends(), throwsA(isA<Exception>()));
    });
  });

  group('UserService.searchUsers (blocked-filter logic)', () {
    setUp(() {
      when(() => auth.currentUser).thenReturn(_currentUser());
    });

    test('drops users I have blocked from the results', () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
          {'id': _thirdId, 'username': 'luis', 'avatar_url': null},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([
        {
          'requester_id': _userId,
          'addressee_id': _otherId,
          'status': 'blocked',
        },
      ]);
      final asAddressee = ResolvingBuilder<PostgrestList>([]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final results = await service().searchUsers('a');

      expect(results.map((r) => r['id']), [_thirdId]);
      expect(results.any((r) => r['hidden'] == true), isFalse);
    });

    test('hides users who blocked me and attaches friendship_status',
        () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
          {'id': _thirdId, 'username': 'luis', 'avatar_url': null},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([]);
      final asAddressee = ResolvingBuilder<PostgrestList>([
        {
          'requester_id': _otherId,
          'addressee_id': _userId,
          'status': 'blocked',
        },
        {
          'requester_id': _thirdId,
          'addressee_id': _userId,
          'status': 'accepted',
        },
      ]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final results = await service().searchUsers('a');

      expect(results.map((r) => r['id']), [_thirdId]);
      expect(results.single['friendship_status'], 'accepted');
    });

    test('returns raw results unchanged when the session has no user',
        () async {
      when(() => auth.currentUser).thenReturn(null);
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
        ]),
      );

      final results = await service().searchUsers('a');

      expect(results, hasLength(1));
      // No friendships query ran (the filter pass is skipped unauthenticated).
      verifyNever(() => client.from('friendships'));
    });

    test('propagates a network-class PostgrestException', () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      final err = await captureError(() => service().searchUsers('a'));
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });

  group('UserService.getFriendRequests', () {
    test('combines received and sent requests', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final received = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-1',
          'requester_id': _otherId,
          'created_at': '2026-08-01T00:00:00Z',
        },
      ]);
      final sent = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-2',
          'addressee_id': _thirdId,
          'created_at': '2026-08-02T00:00:00Z',
        },
      ]);
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? received : sent;
      });

      final requests = await service().getFriendRequests();

      expect(requests, hasLength(2));
      expect(requests.first['type'], 'received');
      expect(requests.first['user_id'], _otherId);
      expect(requests.last['type'], 'sent');
      expect(requests.last['user_id'], _thirdId);
    });
  });

  group('UserService.getBlockedUsers / getBlockStatus', () {
    test('getBlockedUsers returns only rows I requested', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {
            'id': 'fr-1',
            'requester_id': _userId,
            'addressee_id': _otherId,
            'status': 'blocked',
          },
          {
            'id': 'fr-2',
            'requester_id': _thirdId,
            'addressee_id': _userId,
            'status': 'blocked',
          },
        ]),
      );

      final blocked = await service().getBlockedUsers();

      expect(blocked, [
        {'blocked_user_id': _otherId},
      ]);
    });

    test('getBlockStatus is true in either direction', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      var selectCalls = 0;
      when(() => table.select('id')).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1
            ? ResolvingBuilder<PostgrestList>(null)
            : ResolvingBuilder<PostgrestList>({'id': 'fr-1'});
      });

      expect(await service().getBlockStatus(_otherId), isTrue);
    });

    test('getBlockStatus is false when no blocked row exists', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      when(() => table.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().getBlockStatus(_otherId), isFalse);
    });

    test('getBlockStatus is false without a session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().getBlockStatus(_otherId), isFalse);
    });
  });

  group('UserService.accept/decline/remove friend request', () {
    test('acceptFriendRequest updates the status to accepted', () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      await service().acceptFriendRequest('fr-1');

      verify(() => table.update({'status': 'accepted'})).called(1);
      expect(update.filters.single.value, 'fr-1');
    });

    test('declineFriendRequest deletes the friendship row', () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => del);

      await service().declineFriendRequest('fr-1');

      expect(del.filters.single.value, 'fr-1');
    });

    test('removeFriend deletes the friendship row', () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => del);

      await service().removeFriend('fr-1');

      expect(del.filters.single.value, 'fr-1');
    });
  });

  group('UserService.blockUser / unblockUser', () {
    setUp(() {
      when(() => auth.currentUser).thenReturn(_currentUser());
    });

    test('blockUser deletes any existing friendship then inserts blocked',
        () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final existing = ResolvingBuilder<PostgrestList>({
        'id': 'fr-1',
        'requester_id': _userId,
      });
      final del = ResolvingBuilder<dynamic>(null);
      when(() => table.select('id, requester_id'))
          .thenAnswer((_) => existing);
      when(() => table.delete()).thenAnswer((_) => del);
      final insert = ResolvingBuilder<dynamic>(null);
      when(() => table.insert(any())).thenAnswer((_) => insert);

      await service().blockUser(_otherId);

      verify(() => table.insert({
        'requester_id': _userId,
        'addressee_id': _otherId,
        'status': 'blocked',
      })).called(1);
    });

    test('unblockUser deletes the blocked row and inserts nothing', () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      when(() => table.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>({'id': 'fr-1'}));
      final del = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => del);

      await service().unblockUser(_otherId);

      verifyNever(() => table.insert(any()));
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

  group('UserService.findMatches (PFND — I-60)', () {
    setUp(() {
      when(() => auth.currentUser).thenReturn(_currentUser());
    });

    test('queries discovery_view with self-exclusion + tag overlap and '
        'sorts by shared count desc', () async {
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      final viewBuilder = ResolvingBuilder<PostgrestList>([
        {
          'id': _otherId,
          'username': 'ana',
          'avatar_url': null,
          'interest_tags': ['musica', 'fiestas'],
        },
        {
          'id': _thirdId,
          'username': 'luis',
          'avatar_url': null,
          'interest_tags': ['musica', 'deportes', 'cine'],
        },
      ]);
      when(() => view.select(any())).thenAnswer((_) => viewBuilder);
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      when(() => frTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([]),
      );

      final matches = await service().findMatches(['musica', 'cine']);

      expect(matches.map((m) => m['id']), [_thirdId, _otherId]);
      expect(matches.first['shared_count'], 2);
      expect(matches.first['shared_tags'], ['cine', 'musica']);
      expect(matches.last['shared_count'], 1);
      expect(matches.last['shared_tags'], ['musica']);
      expect(viewBuilder.filters.any((f) =>
          f.column == 'id' && f.value == _userId), isTrue);
      expect(viewBuilder.filters.any((f) =>
          f.column == 'interest_tags' &&
          f.value is List &&
          (f.value! as List).join(',') == ['musica', 'cine'].join(',')),
          isTrue);
    });

    test('drops matches I have blocked (block → never appears again)',
        () async {
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null, 'interest_tags': ['musica']},
          {'id': _thirdId, 'username': 'luis', 'avatar_url': null, 'interest_tags': ['musica']},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([
        {
          'requester_id': _userId,
          'addressee_id': _otherId,
          'status': 'blocked',
        },
      ]);
      final asAddressee = ResolvingBuilder<PostgrestList>([]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final matches = await service().findMatches(['musica']);

      expect(matches.map((m) => m['id']), [_thirdId]);
    });

    test('hides matches who blocked me', () async {
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null, 'interest_tags': ['musica']},
          {'id': _thirdId, 'username': 'luis', 'avatar_url': null, 'interest_tags': ['musica']},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([]);
      final asAddressee = ResolvingBuilder<PostgrestList>([
        {
          'requester_id': _otherId,
          'addressee_id': _userId,
          'status': 'blocked',
        },
      ]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final matches = await service().findMatches(['musica']);

      expect(matches.map((m) => m['id']), [_thirdId]);
    });

    test('returns an empty list without a session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().findMatches(['musica']), isEmpty);
      verifyNever(() => client.from('discovery_view'));
    });

    test('returns an empty list when I have no tags and queries nothing',
        () async {
      expect(await service().findMatches(const []), isEmpty);
      verifyNever(() => client.from('discovery_view'));
    });

    test('propagates a network-class PostgrestException', () async {
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      final err = await captureError(() => service().findMatches(['musica']));
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });
}