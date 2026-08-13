import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/cosmetics/screens/cosmetics_shop_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Widget-level tests for the cosmetics shop screen (I-62): catalog grid
/// rendering (name/cost/type/tier badge), balance display, owned/equipped
/// states, the purchase confirm dialog (+ success / insufficient-shards
/// snackbars) and the empty/error states.
const _cosmeticId = '55555555-5555-5555-5555-555555555555';

Map<String, dynamic> _catalogItem({
  String id = _cosmeticId,
  String name = 'Marco Neon',
  String type = 'avatar_frame',
  int cost = 50,
  String tier = 'free',
}) {
  return {
    'id': id,
    'name': name,
    'type': type,
    'asset_url': 'https://cdn.example/neon.png',
    'shard_cost': cost,
    'tier_requirement': tier,
  };
}

Map<String, dynamic> _ownedRow({
  String id = 'uc-1',
  String cosmeticId = _cosmeticId,
  bool equipped = false,
}) {
  return {
    'id': id,
    'cosmetic_id': cosmeticId,
    'equipped': equipped,
    'purchased_at': DateTime(2026, 8, 1).toIso8601String(),
    'cosmetics': _catalogItem(id: cosmeticId),
  };
}

class _FakeShardsService implements ShardsService {
  _FakeShardsService({
    List<Map<String, dynamic>>? catalog,
    List<Map<String, dynamic>>? owned,
  }) : catalog = catalog ?? [_catalogItem()],
       owned = owned ?? [];

  List<Map<String, dynamic>> catalog;
  List<Map<String, dynamic>> owned;
  int catalogFetches = 0;
  final List<String> purchased = [];
  final List<(String, bool)> equips = [];
  Object? purchaseError;

  /// When set, [listCosmetics] waits on it (skeleton-frame pinning, the
  /// U-22 feed-test pattern).
  Future<void>? gate;

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
    if (gate != null) await gate;
    return List.of(catalog);
  }

  @override
  Future<List<Map<String, dynamic>>> getMyCosmetics() async => List.of(owned);

  @override
  Future<void> purchaseCosmetic(String cosmeticId) async {
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

  Future<Map<String, dynamic>?> call() => _onFetch();
}

class _StubProfileNotifier extends MyProfileNotifier {
  _StubProfileNotifier(this.fetcher);

  final _StubProfileFetcher fetcher;

  @override
  Future<Map<String, dynamic>?> build() => fetcher.call();
}

Widget _wrap({
  required _FakeShardsService service,
  Map<String, dynamic> profile = const {
    'username': 'dana',
    'personal_shards': 120,
    'preshards': 0,
    'subscription_tier': 'free',
  },
}) {
  return ProviderScope(
    overrides: [
      shardsServiceProvider.overrideWithValue(service),
      myProfileProvider.overrideWith(
        () => _StubProfileNotifier(_StubProfileFetcher(() async => profile)),
      ),
    ],
    child: const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CosmeticsShopScreen(),
    ),
  );
}

Future<void> _pumpShop(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  group('CosmeticsShopScreen catalog', () {
    testWidgets(
        'shows the card-grid skeleton while the catalog is pending '
        '(U-22 handoff, §5.8)', (tester) async {
      final gate = Completer<void>();
      final service = _FakeShardsService(
        catalog: [_catalogItem(name: 'Marco Neon')],
      )..gate = gate.future;
      // Bounded pump: the shimmer sweep never settles while the gate is
      // pending, so pumpAndSettle would time out (the U-22 feed-test pattern).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(service: service));
      await tester.pump();

      expect(
        find.byType(VSkeletonGrid),
        findsOneWidget,
        reason: 'the grid shop shows the §5.3 card-grid skeleton on first '
            'load, not the bare spinner',
      );
      expect(find.byType(VLoadingView), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(VSkeletonGrid), findsNothing);
      expect(find.text('Marco Neon'), findsOneWidget);
    });

    testWidgets('renders items with name, cost, type label and tier badge', (
      tester,
    ) async {
      final service = _FakeShardsService(
        catalog: [
          _catalogItem(name: 'Marco Neon', cost: 50),
          _catalogItem(
            id: '66666666-6666-6666-6666-666666666666',
            name: 'Marco VIP Oro',
            cost: 300,
            tier: 'vip',
          ),
        ],
      );
      await _pumpShop(tester, _wrap(service: service));

      expect(find.text('Marco Neon'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
      expect(find.text('300'), findsOneWidget);
      expect(find.text('MARCOS'), findsNWidgets(2));
      expect(find.text('Requiere VIP'), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsOneWidget);
    });

    testWidgets('shows the personal shards balance from the profile provider', (
      tester,
    ) async {
      final service = _FakeShardsService();
      await _pumpShop(tester, _wrap(service: service));

      expect(find.text('120 shards'), findsOneWidget);
    });

    testWidgets('renders the empty state when the catalog has no items', (
      tester,
    ) async {
      final service = _FakeShardsService(catalog: []);
      await _pumpShop(tester, _wrap(service: service));

      expect(find.text('No hay cosméticos disponibles aún'), findsOneWidget);
      expect(find.byType(VEmptyView), findsOneWidget);
    });

    testWidgets('renders an ErrorView with retry when the catalog fails', (
      tester,
    ) async {
      final throwing = _ThrowingCatalogService();
      await _pumpShop(tester, _wrap(service: throwing));

      expect(find.byType(ErrorView), findsOneWidget);
      expect(
        find.text('Error del servidor. Intenta de nuevo.'),
        findsOneWidget,
      );

      // Retry re-fetches and recovers.
      throwing.recover();
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('Marco Neon'), findsOneWidget);
    });
  });

  group('CosmeticsShopScreen owned / equip', () {
    testWidgets('marks owned items as Adquirido with an Equipar button', (
      tester,
    ) async {
      final service = _FakeShardsService(owned: [_ownedRow()]);
      await _pumpShop(tester, _wrap(service: service));

      expect(find.text('ADQUIRIDO'), findsOneWidget);
      expect(find.text('Equipar'), findsOneWidget);
    });

    testWidgets('marks the equipped item with the Equipado button and '
        'tapping it unequips', (tester) async {
      final service = _FakeShardsService(owned: [_ownedRow(equipped: true)]);
      await _pumpShop(tester, _wrap(service: service));

      expect(find.text('Equipado'), findsOneWidget);

      await tester.tap(find.text('Equipado'));
      await tester.pumpAndSettle();

      expect(service.equips, [('uc-1', false)]);
      expect(find.text('Equipar'), findsOneWidget);
    });

    testWidgets('tapping Equipar equips through the service', (tester) async {
      final service = _FakeShardsService(owned: [_ownedRow()]);
      await _pumpShop(tester, _wrap(service: service));

      await tester.tap(find.text('Equipar'));
      await tester.pumpAndSettle();

      expect(service.equips, [('uc-1', true)]);
      expect(find.text('Equipado'), findsOneWidget);
    });
  });

  group('CosmeticsShopScreen purchase flow', () {
    testWidgets('confirm dialog → purchase → success snackbar', (tester) async {
      final service = _FakeShardsService();
      await _pumpShop(tester, _wrap(service: service));

      await tester.tap(find.text('Comprar — 50'));
      await tester.pumpAndSettle();

      expect(find.text('Confirmar compra'), findsOneWidget);
      expect(find.text('¿Comprar Marco Neon por 50 shards?'), findsOneWidget);

      await tester.tap(find.text('Comprar'));
      // Bounded pumps, not pumpAndSettle: the screen's VAurora drift keeps
      // frames scheduled for ~10s of fake time, which would run the snackbar
      // through its full 4s lifecycle and dismiss it (LUXE restyle, XL-13).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(service.purchased, [_cosmeticId]);
      expect(find.text('¡Cosmético adquirido!'), findsOneWidget);
      expect(find.text('ADQUIRIDO'), findsOneWidget);
    });

    testWidgets('cancelling the dialog does not purchase', (tester) async {
      final service = _FakeShardsService();
      await _pumpShop(tester, _wrap(service: service));

      await tester.tap(find.text('Comprar — 50'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(service.purchased, isEmpty);
      expect(find.text('Comprar — 50'), findsOneWidget);
    });

    testWidgets('insufficient shards shows the friendly mapped message', (
      tester,
    ) async {
      final service = _FakeShardsService()
        ..purchaseError = const InsufficientShardsException(
          required: 50,
          balance: 10,
        );
      await _pumpShop(tester, _wrap(service: service));

      await tester.tap(find.text('Comprar — 50'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comprar'));
      // Bounded pumps — see the success test above (VAurora drift vs the 4s
      // snackbar lifecycle under pumpAndSettle).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('No tienes suficientes shards'), findsOneWidget);
      expect(find.text('ADQUIRIDO'), findsNothing);
    });

    testWidgets('tier-locked items cannot be bought', (tester) async {
      final service = _FakeShardsService(catalog: [_catalogItem(tier: 'vip')]);
      await _pumpShop(tester, _wrap(service: service));

      await tester.tap(find.text('Comprar — 50'));
      await tester.pumpAndSettle();

      // The disabled button never opens the confirm dialog.
      expect(find.text('Confirmar compra'), findsNothing);
      expect(service.purchased, isEmpty);
    });
  });
}

class _ThrowingCatalogService extends _FakeShardsService {
  _ThrowingCatalogService() : super(catalog: []);

  bool _throwing = true;

  void recover() {
    _throwing = false;
    catalog = [_catalogItem()];
  }

  @override
  Future<List<Map<String, dynamic>>> listCosmetics() async {
    if (_throwing) throw Exception('catalog exploded');
    return super.listCosmetics();
  }
}
