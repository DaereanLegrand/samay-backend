import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:samay/features/party_finder/party_finder_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

/// PFND provider tests (I-60): the opt-in toggle provider reads/persists
/// users.discovery_opt_in through the real [UserService] over a mock client,
/// and the matches provider resolves my tags + overlapping matches and sorts
/// by shared-tag count (service contract). Failure paths surface AsyncError.
const _userId = '11111111-1111-1111-1111-111111111111';
const _otherId = '22222222-2222-2222-2222-222222222222';
const _thirdId = '33333333-3333-3333-3333-333333333333';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

ProviderContainer _container(UserService service) {
  final container = ProviderContainer(overrides: [
    userServiceProvider.overrideWithValue(service),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenReturn(_currentUser());
  });

  UserService service() => UserService(client: client);

  group('discoveryOptInProvider (PFND opt-in toggle)', () {
    test('build reads users.discovery_opt_in through the service', () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'discovery_opt_in': false}),
      );

      final container = _container(service());

      expect(await container.read(discoveryOptInProvider.future), isFalse);
    });

    test('setOptIn persists through the service and flips the state',
        () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'discovery_opt_in': false}),
      );
      final update = ResolvingBuilder<dynamic>(null);
      when(() => users.update(any())).thenAnswer((_) => update);

      final container = _container(service());
      expect(await container.read(discoveryOptInProvider.future), isFalse);

      await container.read(discoveryOptInProvider.notifier).setOptIn(true);

      verify(() => users.update({'discovery_opt_in': true})).called(1);
      expect(update.filters.single.value, _userId);
      expect(container.read(discoveryOptInProvider).valueOrNull, isTrue);
    });

    test('a failed write surfaces as AsyncError', () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'discovery_opt_in': false}),
      );
      when(() => users.update(any())).thenThrow(
        const PostgrestException(
          message: 'permission denied for table users',
          code: '42501',
        ),
      );

      final container = _container(service());
      await container.read(discoveryOptInProvider.future);

      await expectLater(
        container.read(discoveryOptInProvider.notifier).setOptIn(true),
        throwsA(isA<PostgrestException>()),
      );
      expect(container.read(discoveryOptInProvider), isA<AsyncError>());
    });
  });

  group('partyMatchesProvider (PFND matches)', () {
    test('resolves my tags then returns overlaps sorted by shared count',
        () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'interest_tags': ['musica', 'cine']},
        ),
      );
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
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
        ]),
      );
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      when(() => frTable.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      final container = _container(service());
      final matches = await container.read(partyMatchesProvider.future);

      expect(matches.map((m) => m['id']), [_thirdId, _otherId]);
      expect(matches.first['shared_count'], 2);
      expect(matches.last['shared_count'], 1);
    });

    test('refresh re-runs build after a block invalidates a match',
        () async {
      var blocked = false;
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(
          {'interest_tags': ['musica']},
        ),
      );
      final view = MockQueryBuilder();
      when(() => client.from('discovery_view')).thenAnswer((_) => view);
      when(() => view.select(any())).thenAnswer((_) {
        if (blocked) return ResolvingBuilder<PostgrestList>([]);
        return ResolvingBuilder<PostgrestList>([
          {
            'id': _otherId,
            'username': 'ana',
            'avatar_url': null,
            'interest_tags': ['musica'],
          },
        ]);
      });
      final frTable = MockQueryBuilder();
      when(() => client.from('friendships')).thenAnswer((_) => frTable);
      when(() => frTable.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      final container = _container(service());
      expect(await container.read(partyMatchesProvider.future), hasLength(1));

      blocked = true;
      await container.read(partyMatchesProvider.notifier).refresh();

      expect(await container.read(partyMatchesProvider.future), isEmpty);
    });

    test('a service failure surfaces as AsyncError', () async {
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      final container = _container(service());

      await expectLater(
        container.read(partyMatchesProvider.future),
        throwsA(isA<PostgrestException>()),
      );
      expect(container.read(partyMatchesProvider), isA<AsyncError>());
    });
  });
}
