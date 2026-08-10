import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// ShardsService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// donation guard + RPC shape, contribution aggregation, cosmetic purchase
/// and leaderboard reads, plus error propagation.
const _userId = '11111111-1111-1111-1111-111111111111';
const _groupId = '33333333-3333-3333-3333-333333333333';
const _cosmeticId = '55555555-5555-5555-5555-555555555555';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;
  late MockConfigService config;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
    config = MockConfigService();
  });

  ShardsService service() => ShardsService(client: client, config: config);

  group('ShardsService.donateToGroup', () {
    test('throws when the user has fewer shards than the amount', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => users.select('personal_shards')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'personal_shards': 10}),
      );

      expect(
        () => service().donateToGroup(_groupId, 100),
        throwsA(
          predicate(
            (e) => e is Exception && e.toString().contains('suficientes'),
          ),
        ),
      );
      verifyNever(
        () =>
            client.rpc('donate_shards_to_group', params: any(named: 'params')),
      );
    });

    test(
      'invokes the donation RPC with the config-driven boost window',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final users = MockQueryBuilder();
        when(() => client.from('users')).thenAnswer((_) => users);
        when(() => users.select('personal_shards')).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({'personal_shards': 500}),
        );
        when(
          () => config.fetchAppConfig(),
        ).thenAnswer((_) async => {'economy.group_shard_boost_days': '21'});
        when(
          () => client.rpc(
            'donate_shards_to_group',
            params: any(named: 'params'),
          ),
        ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

        await service().donateToGroup(_groupId, 100);

        final params =
            verify(
                  () => client.rpc(
                    'donate_shards_to_group',
                    params: captureAny(named: 'params'),
                  ),
                ).captured.single
                as Map;
        expect(params['p_group_id'], _groupId);
        expect(params['p_user_id'], _userId);
        expect(params['p_amount'], 100);
        final expiresAt = DateTime.parse(params['p_expires_at'] as String);
        expect(
          expiresAt.isAfter(DateTime.now().add(const Duration(days: 20))),
          isTrue,
        );
        expect(
          expiresAt.isBefore(DateTime.now().add(const Duration(days: 22))),
          isTrue,
        );
      },
    );

    test(
      'falls back to the default 14-day boost window when config is absent',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final users = MockQueryBuilder();
        when(() => client.from('users')).thenAnswer((_) => users);
        when(() => users.select('personal_shards')).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({'personal_shards': 500}),
        );
        when(() => config.fetchAppConfig()).thenAnswer((_) async => const {});
        when(
          () => client.rpc(
            'donate_shards_to_group',
            params: any(named: 'params'),
          ),
        ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

        await service().donateToGroup(_groupId, 100);

        final params =
            verify(
                  () => client.rpc(
                    'donate_shards_to_group',
                    params: captureAny(named: 'params'),
                  ),
                ).captured.single
                as Map;
        final expiresAt = DateTime.parse(params['p_expires_at'] as String);
        expect(
          expiresAt.isBefore(DateTime.now().add(const Duration(days: 15))),
          isTrue,
        );
      },
    );

    test(
      'propagates a not-authorized PostgrestException from the RPC',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final users = MockQueryBuilder();
        when(() => client.from('users')).thenAnswer((_) => users);
        when(() => users.select('personal_shards')).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({'personal_shards': 500}),
        );
        when(() => config.fetchAppConfig()).thenAnswer((_) async => const {});
        when(
          () => client.rpc(
            'donate_shards_to_group',
            params: any(named: 'params'),
          ),
        ).thenThrow(
          const PostgrestException(message: 'Not authorized', code: '42501'),
        );

        final err = await captureError(
          () => service().donateToGroup(_groupId, 100),
        );
        expect(err, isA<PostgrestException>());
        expectMapped(err, PermissionError);
      },
    );
  });

  group('ShardsService.getGroupContributions / getUserContributionToGroup', () {
    test('getGroupContributions maps the active rows', () async {
      final table = MockQueryBuilder();
      when(
        () => client.from('group_shard_contributions'),
      ).thenAnswer((_) => table);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'c-1',
          'user_id': _userId,
          'shards_contributed': 50,
          'users': {'username': 'dana'},
        },
      ]);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final result = await service().getGroupContributions(_groupId);

      expect(result, hasLength(1));
      expect(result.single['users'], {'username': 'dana'});
      expect(
        rows.filters,
        contains(const RecordedFilter('group_id', _groupId)),
      );
    });

    test('getUserContributionToGroup sums every active row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      when(
        () => client.from('group_shard_contributions'),
      ).thenAnswer((_) => table);
      when(() => table.select('shards_contributed')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'shards_contributed': 30},
          {'shards_contributed': 12},
          {'shards_contributed': 8},
        ]),
      );

      expect(await service().getUserContributionToGroup(_groupId), 50);
    });

    test(
      'getUserContributionToGroup returns 0 when there are no rows',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final table = MockQueryBuilder();
        when(
          () => client.from('group_shard_contributions'),
        ).thenAnswer((_) => table);
        when(
          () => table.select('shards_contributed'),
        ).thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

        expect(await service().getUserContributionToGroup(_groupId), 0);
      },
    );
  });

  group('ShardsService.purchaseCosmetic', () {
    test('inserts the ownership row and a negative ledger entry', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final cosmetics = MockQueryBuilder();
      final users = MockQueryBuilder();
      final userCosmetics = MockQueryBuilder();
      final ledger = MockQueryBuilder();
      when(() => client.from('cosmetics')).thenAnswer((_) => cosmetics);
      when(() => client.from('users')).thenAnswer((_) => users);
      when(
        () => client.from('user_cosmetics'),
      ).thenAnswer((_) => userCosmetics);
      when(() => client.from('shard_ledger')).thenAnswer((_) => ledger);
      when(() => cosmetics.select('shard_cost, tier_requirement')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'shard_cost': 50,
          'tier_requirement': 'free',
        }),
      );
      when(() => users.select('personal_shards, subscription_tier')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'personal_shards': 200,
          'subscription_tier': 'pro',
        }),
      );
      when(
        () => userCosmetics.insert(any()),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(
        () => ledger.insert(any()),
      ).thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().purchaseCosmetic(_cosmeticId);

      final owned =
          verify(() => userCosmetics.insert(captureAny())).captured.single
              as Map;
      expect(owned['user_id'], _userId);
      expect(owned['cosmetic_id'], _cosmeticId);
      expect(owned['equipped'], isFalse);

      final entry =
          verify(() => ledger.insert(captureAny())).captured.single as Map;
      expect(entry['user_id'], _userId);
      expect(entry['delta'], -50);
      expect(entry['reason'], 'cosmetic_purchase');
      expect(entry['reference_id'], _cosmeticId);
    });

    test(
      'throws a typed InsufficientShardsException when unaffordable',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final cosmetics = MockQueryBuilder();
        final users = MockQueryBuilder();
        when(() => client.from('cosmetics')).thenAnswer((_) => cosmetics);
        when(() => client.from('users')).thenAnswer((_) => users);
        when(() => cosmetics.select('shard_cost, tier_requirement')).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({
            'shard_cost': 500,
            'tier_requirement': 'free',
          }),
        );
        when(
          () => users.select('personal_shards, subscription_tier'),
        ).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({
            'personal_shards': 100,
            'subscription_tier': 'free',
          }),
        );

        await expectLater(
          service().purchaseCosmetic(_cosmeticId),
          throwsA(isA<InsufficientShardsException>()),
        );
        verifyNever(() => client.from('user_cosmetics'));
        verifyNever(() => client.from('shard_ledger'));
      },
    );

    test('throws a typed TierRequirementException when the tier is below the '
        'requirement', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final cosmetics = MockQueryBuilder();
      final users = MockQueryBuilder();
      when(() => client.from('cosmetics')).thenAnswer((_) => cosmetics);
      when(() => client.from('users')).thenAnswer((_) => users);
      when(() => cosmetics.select('shard_cost, tier_requirement')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'shard_cost': 50,
          'tier_requirement': 'vip',
        }),
      );
      when(() => users.select('personal_shards, subscription_tier')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'personal_shards': 500,
          'subscription_tier': 'free',
        }),
      );

      await expectLater(
        service().purchaseCosmetic(_cosmeticId),
        throwsA(isA<TierRequirementException>()),
      );
      verifyNever(() => client.from('user_cosmetics'));
      verifyNever(() => client.from('shard_ledger'));
    });
  });

  group('ShardsService.listCosmetics', () {
    test('maps the public catalog rows', () async {
      final table = MockQueryBuilder();
      when(() => client.from('cosmetics')).thenAnswer((_) => table);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': _cosmeticId,
          'name': 'Marco Neon',
          'type': 'avatar_frame',
          'asset_url': 'https://cdn.example/neon.png',
          'shard_cost': 50,
          'tier_requirement': 'free',
        },
      ]);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final result = await service().listCosmetics();

      expect(result, hasLength(1));
      expect(result.single['name'], 'Marco Neon');
      expect(result.single['type'], 'avatar_frame');
      verify(
        () => table.select(
          'id, name, type, asset_url, shard_cost, tier_requirement',
        ),
      );
    });
  });

  group('ShardsService.getMyCosmetics', () {
    test(
      'returns the current user ownership rows with the joined cosmetic',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final table = MockQueryBuilder();
        when(() => client.from('user_cosmetics')).thenAnswer((_) => table);
        final rows = ResolvingBuilder<PostgrestList>([
          {
            'id': 'uc-1',
            'cosmetic_id': _cosmeticId,
            'equipped': true,
            'purchased_at': DateTime(2026, 8, 1).toIso8601String(),
            'cosmetics': {
              'id': _cosmeticId,
              'name': 'Marco Neon',
              'type': 'avatar_frame',
              'asset_url': 'https://cdn.example/neon.png',
              'shard_cost': 50,
              'tier_requirement': 'free',
            },
          },
        ]);
        when(() => table.select(any())).thenAnswer((_) => rows);

        final result = await service().getMyCosmetics();

        expect(result, hasLength(1));
        expect(result.single['id'], 'uc-1');
        expect(result.single['equipped'], isTrue);
        expect((result.single['cosmetics'] as Map)['type'], 'avatar_frame');
        expect(rows.filters, contains(RecordedFilter('user_id', _userId)));
      },
    );

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(() => service().getMyCosmetics(), throwsA(isA<Exception>()));
    });
  });

  group('ShardsService.setCosmeticEquipped', () {
    test('unequips by flipping equipped off on the row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final table = MockQueryBuilder();
      final updates = ResolvingBuilder<dynamic>(null);
      when(() => client.from('user_cosmetics')).thenAnswer((_) => table);
      when(() => table.update(any())).thenAnswer((_) => updates);

      await service().setCosmeticEquipped('uc-1', false);

      verify(() => table.update({'equipped': false})).called(1);
      expect(updates.filters, contains(const RecordedFilter('id', 'uc-1')));
      expect(updates.filters, contains(RecordedFilter('user_id', _userId)));
    });

    test(
      'equipping auto-unequips other owned items of the same type',
      () async {
        when(() => auth.currentUser).thenReturn(_currentUser());
        final table = MockQueryBuilder();
        final updates = ResolvingBuilder<dynamic>(null);
        when(() => client.from('user_cosmetics')).thenAnswer((_) => table);
        when(
          () => table.select('cosmetic_id, cosmetics!inner(type)'),
        ).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>({
            'cosmetic_id': _cosmeticId,
            'cosmetics': {'type': 'avatar_frame'},
          }),
        );
        when(() => table.select('id, cosmetics!inner(type)')).thenAnswer(
          (_) => ResolvingBuilder<PostgrestList>([
            {
              'id': 'uc-1',
              'cosmetics': {'type': 'avatar_frame'},
            },
            {
              'id': 'uc-2',
              'cosmetics': {'type': 'avatar_frame'},
            },
            {
              'id': 'uc-3',
              'cosmetics': {'type': 'badge'},
            },
          ]),
        );
        when(() => table.update(any())).thenAnswer((_) => updates);

        await service().setCosmeticEquipped('uc-1', true);

        verify(() => table.update({'equipped': false})).called(1);
        verify(() => table.update({'equipped': true})).called(1);
        expect(updates.filters, contains(const RecordedFilter('id', 'uc-2')));
        expect(updates.filters, contains(const RecordedFilter('id', 'uc-1')));
        // The badge row (different type) must never be touched.
        expect(
          updates.filters,
          isNot(contains(const RecordedFilter('id', 'uc-3'))),
        );
      },
    );

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);
      expect(
        () => service().setCosmeticEquipped('uc-1', true),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('ShardsService.getLeaderboard', () {
    test('returns the ranked snapshots for the tier', () async {
      final snapshots = MockQueryBuilder();
      when(
        () => client.from('group_rank_snapshots'),
      ).thenAnswer((_) => snapshots);
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'group_id': 'g-1',
          'rank_position': 1,
          'score': 900,
          'member_count': 20,
        },
      ]);
      when(() => snapshots.select(any())).thenAnswer((_) => rows);

      final result = await service().getLeaderboard('micro');

      expect(result, hasLength(1));
      expect(result.single['rank_position'], 1);
      expect(
        rows.filters,
        contains(const RecordedFilter('size_tier', 'micro')),
      );
    });
  });
}
