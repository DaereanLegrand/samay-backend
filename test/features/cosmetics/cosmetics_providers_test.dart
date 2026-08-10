import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/cosmetics/providers/cosmetics_providers.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Provider-level behavioral tests for the cosmetics shop state (I-62):
/// catalog/my-cosmetics loads, the purchase action (service call + refresh of
/// both providers + the profile balance), typed insufficient-shards error
/// mapping, and the equip toggle.
const _cosmeticId = '55555555-5555-5555-5555-555555555555';

Map<String, dynamic> _catalogItem({
  String id = _cosmeticId,
  String type = 'avatar_frame',
}) => {
  'id': id,
  'name': 'Marco Neon',
  'type': type,
  'asset_url': 'https://cdn.example/neon.png',
  'shard_cost': 50,
  'tier_requirement': 'free',
};

Map<String, dynamic> _ownedRow({
  String id = 'uc-1',
  String cosmeticId = _cosmeticId,
  bool equipped = false,
}) => {
  'id': id,
  'cosmetic_id': cosmeticId,
  'equipped': equipped,
  'purchased_at': DateTime(2026, 8, 1).toIso8601String(),
  'cosmetics': _catalogItem(id: cosmeticId),
};

class _FakeShardsService implements ShardsService {
  _FakeShardsService({
    List<Map<String, dynamic>>? catalog,
    List<Map<String, dynamic>>? owned,
  }) : catalog = catalog ?? [_catalogItem()],
       owned = owned ?? [];

  List<Map<String, dynamic>> catalog;
  List<Map<String, dynamic>> owned;
  int catalogFetches = 0;
  int ownedFetches = 0;
  int purchaseCalls = 0;
  final List<String> purchased = [];
  final List<(String, bool)> equips = [];
  Object? purchaseError;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  ConfigService get config => throw UnimplementedError();

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  Future<void> donateToGroup(String groupId, int amount) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getGroupContributions(String groupId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getLeaderboard(String sizeTier) =>
      throw UnimplementedError();

  @override
  Future<int> getUserContributionToGroup(String groupId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listCosmetics() async {
    catalogFetches++;
    return List.of(catalog);
  }

  @override
  Future<List<Map<String, dynamic>>> getMyCosmetics() async {
    ownedFetches++;
    return List.of(owned);
  }

  @override
  Future<void> purchaseCosmetic(String cosmeticId) async {
    purchaseCalls++;
    if (purchaseError != null) throw purchaseError!;
    purchased.add(cosmeticId);
    owned.add(_ownedRow(id: 'uc-$cosmeticId', cosmeticId: cosmeticId));
  }

  @override
  Future<void> setCosmeticEquipped(String userCosmeticId, bool equipped) async {
    equips.add((userCosmeticId, equipped));
    owned.firstWhere((r) => r['id'] == userCosmeticId)['equipped'] = equipped;
  }

  @override
  Future<List<LedgerEntry>> getShardLedger({int limit = 100}) async => const [];

  @override
  Future<List<LedgerEntry>> getPreshardLedger({int limit = 100}) async =>
      const [];
}

class _StubProfileFetcher {
  _StubProfileFetcher(this._onFetch);

  final Future<Map<String, dynamic>?> Function() _onFetch;
  int calls = 0;

  Future<Map<String, dynamic>?> call() {
    calls++;
    return _onFetch();
  }
}

class _StubProfileNotifier extends MyProfileNotifier {
  _StubProfileNotifier(this.fetcher);

  final _StubProfileFetcher fetcher;

  @override
  Future<Map<String, dynamic>?> build() => fetcher.call();
}

void main() {
  group('cosmeticsCatalogProvider', () {
    test('loads the public catalog from the shards service', () async {
      final service = _FakeShardsService(catalog: [_catalogItem()]);
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(cosmeticsCatalogProvider.future);
      expect(state, hasLength(1));
      expect(state.single['name'], 'Marco Neon');
      expect(service.catalogFetches, 1);
    });

    test('exposes an AsyncError when the catalog fetch fails', () async {
      final container = ProviderContainer(
        overrides: [
          shardsServiceProvider.overrideWithValue(_ThrowingService()),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(cosmeticsCatalogProvider.future),
        throwsA(isA<Exception>()),
      );
      final state = container.read(cosmeticsCatalogProvider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<Exception>());
    });
  });

  group('myCosmeticsProvider', () {
    test('loads the owned cosmetics with the joined cosmetic', () async {
      final service = _FakeShardsService(owned: [_ownedRow(equipped: true)]);
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(myCosmeticsProvider.future);
      expect(state, hasLength(1));
      expect(state.single['equipped'], isTrue);
      expect(service.ownedFetches, 1);
    });

    test(
      'purchase calls the service and refreshes both providers + balance',
      () async {
        final service = _FakeShardsService();
        final profileFetcher = _StubProfileFetcher(
          () async => const {
            'username': 'dana',
            'personal_shards': 120,
            'preshards': 0,
            'subscription_tier': 'free',
          },
        );
        final container = ProviderContainer(
          overrides: [
            shardsServiceProvider.overrideWithValue(service),
            myProfileProvider.overrideWith(
              () => _StubProfileNotifier(profileFetcher),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(myCosmeticsProvider.future);
        await container.read(cosmeticsCatalogProvider.future);
        await container.read(myProfileProvider.future);

        await container
            .read(myCosmeticsProvider.notifier)
            .purchase(_cosmeticId);

        expect(service.purchaseCalls, 1);
        expect(service.purchased, [_cosmeticId]);
        // The purchase action invalidates the catalog, owned set and balance;
        // reading them again re-runs each build (the shop screen watches all
        // three, so the refresh is observable there too).
        await container.read(cosmeticsCatalogProvider.future);
        await container.read(myCosmeticsProvider.future);
        await container.read(myProfileProvider.future);
        expect(service.catalogFetches, 2);
        expect(service.ownedFetches, 2);
        expect(profileFetcher.calls, 2);
      },
    );

    test(
      'maps an InsufficientShardsException to a typed friendly failure',
      () async {
        final service = _FakeShardsService()
          ..purchaseError = const InsufficientShardsException(
            required: 500,
            balance: 10,
          );
        final profileFetcher = _StubProfileFetcher(
          () async => const {
            'username': 'dana',
            'personal_shards': 10,
            'preshards': 0,
            'subscription_tier': 'free',
          },
        );
        final container = ProviderContainer(
          overrides: [
            shardsServiceProvider.overrideWithValue(service),
            myProfileProvider.overrideWith(
              () => _StubProfileNotifier(profileFetcher),
            ),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(myCosmeticsProvider.notifier).purchase(_cosmeticId),
          throwsA(
            isA<CosmeticPurchaseException>().having(
              (e) => e.failure,
              'failure',
              CosmeticPurchaseFailure.insufficientShards,
            ),
          ),
        );
        // Nothing was recorded and nothing was refreshed on failure.
        expect(service.purchased, isEmpty);
        expect(service.ownedFetches, 1);
      },
    );

    test(
      'maps a TierRequirementException to a typed friendly failure',
      () async {
        final service = _FakeShardsService()
          ..purchaseError = const TierRequirementException();
        final profileFetcher = _StubProfileFetcher(
          () async => const {
            'username': 'dana',
            'personal_shards': 500,
            'preshards': 0,
            'subscription_tier': 'free',
          },
        );
        final container = ProviderContainer(
          overrides: [
            shardsServiceProvider.overrideWithValue(service),
            myProfileProvider.overrideWith(
              () => _StubProfileNotifier(profileFetcher),
            ),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(myCosmeticsProvider.notifier).purchase(_cosmeticId),
          throwsA(
            isA<CosmeticPurchaseException>().having(
              (e) => e.failure,
              'failure',
              CosmeticPurchaseFailure.tierRequirement,
            ),
          ),
        );
      },
    );

    test('setEquipped calls the service and refreshes the owned set', () async {
      final service = _FakeShardsService(owned: [_ownedRow()]);
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await container.read(myCosmeticsProvider.future);

      await container
          .read(myCosmeticsProvider.notifier)
          .setEquipped('uc-1', true);

      expect(service.equips, [('uc-1', true)]);
      await container.read(myCosmeticsProvider.future);
      expect(service.ownedFetches, 2);
      expect(
        (await container.read(myCosmeticsProvider.future)).single['equipped'],
        isTrue,
      );
    });
  });
}

class _ThrowingService extends _FakeShardsService {
  @override
  Future<List<Map<String, dynamic>>> listCosmetics() async =>
      throw Exception('catalog exploded');
}
