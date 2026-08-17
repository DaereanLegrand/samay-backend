
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/services/discovery_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// DiscoveryService behavioral tests (search + Party Finder, extracted from
/// user_service_test.dart).
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

  DiscoveryService service() => DiscoveryService(client: client);

  group('DiscoveryService.searchUsers (blocked-filter logic)', () {
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

    test('a pending row where the current user is the addressee carries '
        'friendship_id + friendship_direction received (ISSUE 5)', () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([]);
      final asAddressee = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-9',
          'requester_id': _otherId,
          'addressee_id': _userId,
          'status': 'pending',
        },
      ]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final results = await service().searchUsers('a');

      final r = results.single;
      expect(r['friendship_status'], 'pending');
      expect(r['friendship_id'], 'fr-9');
      expect(r['friendship_direction'], 'received');
      verify(() => frTable.select('id, requester_id, addressee_id, status'))
          .called(2);
    });

    test('a pending row where the current user is the requester carries '
        'friendship_id + friendship_direction sent (ISSUE 5)', () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-8',
          'requester_id': _userId,
          'addressee_id': _otherId,
          'status': 'pending',
        },
      ]);
      final asAddressee = ResolvingBuilder<PostgrestList>([]);
      var selectCalls = 0;
      when(() => frTable.select(any())).thenAnswer((_) {
        selectCalls++;
        return selectCalls == 1 ? asRequester : asAddressee;
      });

      final results = await service().searchUsers('a');

      final r = results.single;
      expect(r['friendship_status'], 'pending');
      expect(r['friendship_id'], 'fr-8');
      expect(r['friendship_direction'], 'sent');
    });

    test('accepted rows carry neither friendship_id nor '
        'friendship_direction (ISSUE 5)', () async {
      final usersTable = MockQueryBuilder();
      when(() => client.from('user_search_view'))
          .thenAnswer((_) => usersTable);
      when(() => usersTable.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'id': _otherId, 'username': 'ana', 'avatar_url': null},
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      final asRequester = ResolvingBuilder<PostgrestList>([]);
      final asAddressee = ResolvingBuilder<PostgrestList>([
        {
          'id': 'fr-7',
          'requester_id': _otherId,
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

      final r = results.single;
      expect(r['friendship_status'], 'accepted');
      expect(r.containsKey('friendship_id'), isFalse);
      expect(r.containsKey('friendship_direction'), isFalse);
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

  group('DiscoveryService.findMatches (PFND — I-60)', () {
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
