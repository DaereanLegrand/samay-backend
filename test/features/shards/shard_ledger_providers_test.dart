import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/shards/providers/shard_ledger_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Provider-level behavioral tests for the shard ledger state (SLED — I-64):
/// both ledger lists load from the shards service, the derived totals sum the
/// deltas, errors surface as AsyncError, and refresh re-fetches both lists.
const _id = '11111111-1111-1111-1111-111111111111';

Map<String, dynamic> _row({
  String id = _id,
  int delta = 50,
  String reason = 'event_attendance',
  String? referenceId,
  DateTime? createdAt,
}) => {
  'id': id,
  'delta': delta,
  'reason': reason,
  'reference_id': referenceId,
  'created_at': (createdAt ?? DateTime.utc(2026, 8, 1, 21, 30)).toIso8601String(),
};

class _FakeShardsService implements ShardsService {
  _FakeShardsService({
    List<LedgerEntry>? shardLedger,
    List<LedgerEntry>? preshardLedger,
  }) : shardLedger = shardLedger ?? [
         LedgerEntry.fromJson(_row()),
         LedgerEntry.fromJson(_row(id: '22222222-2222-2222-2222-222222222222', delta: -20, reason: 'cosmetic_purchase')),
       ],
       preshardLedger = preshardLedger ?? [
         LedgerEntry.fromJson(_row(id: '44444444-4444-4444-4444-444444444444', delta: 100, reason: 'purchased')),
       ];

  List<LedgerEntry> shardLedger;
  List<LedgerEntry> preshardLedger;
  int shardFetches = 0;
  int preshardFetches = 0;
  Object? shardError;

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
  Future<List<Map<String, dynamic>>> listCosmetics() =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getMyCosmetics() =>
      throw UnimplementedError();

  @override
  Future<void> purchaseCosmetic(String cosmeticId) =>
      throw UnimplementedError();

  @override
  Future<void> setCosmeticEquipped(String userCosmeticId, bool equipped) =>
      throw UnimplementedError();

  @override
  Future<List<LedgerEntry>> getShardLedger({int limit = 100}) async {
    shardFetches++;
    if (shardError != null) throw shardError!;
    return List.of(shardLedger);
  }

  @override
  Future<List<LedgerEntry>> getPreshardLedger({int limit = 100}) async {
    preshardFetches++;
    return List.of(preshardLedger);
  }
}

void main() {
  group('shardLedgerProvider', () {
    test('loads both ledger lists from the shards service', () async {
      final service = _FakeShardsService();
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final state = await container.read(shardLedgerProvider.future);

      expect(service.shardFetches, 1);
      expect(service.preshardFetches, 1);
      expect(state.shards, hasLength(2));
      expect(state.preshards, hasLength(1));
      expect(state.shards.first.reason, 'event_attendance');
      expect(state.preshards.single.delta, 100);
    });

    test('derives totals by summing every delta per list', () async {
      final container = ProviderContainer(
        overrides: [
          shardsServiceProvider.overrideWithValue(_FakeShardsService()),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(shardLedgerProvider.future);

      // 50 + (-20) = 30 earned-spent net on the shard side; 100 preshards.
      expect(state.shardTotal, 30);
      expect(state.preshardTotal, 100);
    });

    test('isEmpty when both lists have no entries', () async {
      final container = ProviderContainer(
        overrides: [
          shardsServiceProvider.overrideWithValue(
            _FakeShardsService(shardLedger: [], preshardLedger: []),
          ),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(shardLedgerProvider.future);
      expect(state.isEmpty, isTrue);
    });

    test('exposes an AsyncError when the shard fetch fails', () async {
      final service = _FakeShardsService()..shardError = Exception('ledger exploded');
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(shardLedgerProvider.future),
        throwsA(isA<Exception>()),
      );
      final state = container.read(shardLedgerProvider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<Exception>());
    });

    test('refresh re-runs both ledger fetches', () async {
      final service = _FakeShardsService();
      final container = ProviderContainer(
        overrides: [shardsServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container.read(shardLedgerProvider.future);
      expect(service.shardFetches, 1);
      expect(service.preshardFetches, 1);

      await container.read(shardLedgerProvider.notifier).refresh();
      await container.read(shardLedgerProvider.future);

      expect(service.shardFetches, 2);
      expect(service.preshardFetches, 2);
    });
  });
}
