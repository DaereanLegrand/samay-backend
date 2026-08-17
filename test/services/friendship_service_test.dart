
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/services/friendship_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// FriendshipService behavioral tests (extracted from user_service_test.dart).
const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _thirdId = '33333333-3333-3333-3333-333333333333';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  FriendshipService service() => FriendshipService(client: client);

  group('FriendshipService.getFriendshipStatus', () {
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

  group('FriendshipService.sendFriendRequest', () {
    test('inserts a pending friendship when none exists and reports pending',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final probe = ResolvingBuilder<PostgrestList>(null);
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
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
      when(() => table.select(any()))
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
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1
            ? ResolvingBuilder<PostgrestList>(null)
            : ResolvingBuilder<PostgrestList>({
                'id': 'fr-rev',
                'status': 'pending',
              });
      });
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      final status = await service().sendFriendRequest(_otherId);

      expect(status, 'accepted',
          reason: 'a reverse pending request becomes an instant accept (R15)');
      verify(() => table.update({'status': 'accepted'})).called(1);
      expect(update.filters[0].value, 'fr-rev',
          reason: 'the update targets the reverse row id');
      expect(update.filters[1].column, 'status',
          reason: 'only a pending row may be flipped — a blocked row is a '
              'block, not an accept');
      expect(update.filters[1].value, 'pending');
      verifyNever(() => table.insert(any()));
    });

    test(
        'throws when the reverse-direction row is a BLOCK — the addressee '
        'of a blocked row cannot flip it into an accepted friendship',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      var selectCalls = 0;
      when(() => table.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1
            ? ResolvingBuilder<PostgrestList>(null)
            : ResolvingBuilder<PostgrestList>({
                'id': 'fr-block',
                'status': 'blocked',
              });
      });
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      expect(
        () => service().sendFriendRequest(_otherId),
        throwsA(predicate((e) =>
            e is Exception && e.toString().contains('bloqueado'))),
      );
      verifyNever(() => table.update(any()));
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
      when(() => table.select(any()))
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

  group('FriendshipService.getFriends', () {
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

  group('FriendshipService.getFriendRequests', () {
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

  group('FriendshipService.getBlockedUsers / getBlockStatus', () {
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

  group('FriendshipService.accept/decline/remove friend request', () {
    test('acceptFriendRequest calls the accept_friend_request RPC', () async {
      when(() => client.rpc('accept_friend_request',
              params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().acceptFriendRequest('fr-1');

      verify(() => client.rpc('accept_friend_request',
              params: {'p_friendship_id': 'fr-1'}))
          .called(1);
      verifyNever(() => client.from('friendships').update(any()));
    });

    test('declineFriendRequest deletes only a pending friendship row', () async {
      final table = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final del = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => del);

      await service().declineFriendRequest('fr-1');

      expect(del.filters[0].value, 'fr-1');
      expect(del.filters[1].column, 'status',
          reason: 'a blocked row must never be deletable through decline — '
              'only a pending request');
      expect(del.filters[1].value, 'pending');
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

  group('FriendshipService.blockUser / unblockUser', () {
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
}
