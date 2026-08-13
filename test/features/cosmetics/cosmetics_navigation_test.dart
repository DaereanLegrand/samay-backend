import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/cosmetics/screens/cosmetics_shop_screen.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Route-level navigation tests for the cosmetics shop (I-62): the profile
/// "Cosméticos" section navigates to `/cosmetics` (flag-gated, I-49 release
/// gating), and the route renders the shop by default (R1 events sweep
/// flipped the flag live) / the neutral flag-gate fallback when it is off.
const _cosmeticId = '55555555-5555-5555-5555-555555555555';

Map<String, dynamic> _catalogItem() => {
  'id': _cosmeticId,
  'name': 'Marco Neon',
  'type': 'avatar_frame',
  'asset_url': 'https://cdn.example/neon.png',
  'shard_cost': 50,
  'tier_requirement': 'free',
};

class _FakeShardsService implements ShardsService {
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
  Future<List<Map<String, dynamic>>> listCosmetics() async => [_catalogItem()];

  @override
  Future<List<Map<String, dynamic>>> getMyCosmetics() async => [];

  @override
  Future<void> purchaseCosmetic(String cosmeticId) async {}

  @override
  Future<void> setCosmeticEquipped(
    String userCosmeticId,
    bool equipped,
  ) async {}

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

class _StubGroupsFetcher {
  _StubGroupsFetcher(this._onFetch);

  final Future<List<Map<String, dynamic>>> Function() _onFetch;

  Future<List<Map<String, dynamic>>> call() => _onFetch();
}

class _StubGroupsNotifier extends ProfileGroupsNotifier {
  _StubGroupsNotifier(this.fetcher);

  final _StubGroupsFetcher fetcher;

  @override
  Future<List<Map<String, dynamic>>> build() => fetcher.call();
}

class _MemoryStorage extends LocalStorage {
  String? _token;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => _token != null;

  @override
  Future<String?> accessToken() async => _token;

  @override
  Future<void> persistSession(String persistSessionString) async {
    _token = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    _token = null;
  }
}

class _MemoryAsyncStorage extends GotrueAsyncStorage {
  final Map<String, String> _items = {};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _items[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _items.remove(key);
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(authenticated: true, hasProfile: true);
}

ProviderContainer _newContainer({bool cosmeticsOn = false}) {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_FakeAuthNotifier.new),
      featureFlagsProvider.overrideWithValue(
        AppFeatureFlags(cosmeticsSection: cosmeticsOn),
      ),
      shardsServiceProvider.overrideWithValue(_FakeShardsService()),
      myProfileProvider.overrideWith(
        () => _StubProfileNotifier(
          _StubProfileFetcher(
            () async => const {
              'username': 'dana',
              'personal_shards': 120,
              'preshards': 0,
              'subscription_tier': 'free',
            },
          ),
        ),
      ),
      myGroupsProvider.overrideWith(
        () => _StubGroupsNotifier(_StubGroupsFetcher(() async => const [])),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpRoute(
  WidgetTester tester,
  ProviderContainer container,
  String path,
) async {
  final router = container.read(routerProvider);
  router.go(path);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await Supabase.initialize(
      url: 'http://127.0.0.1:54386',
      anonKey: 'test-anon-key',
      authOptions: FlutterAuthClientOptions(
        localStorage: _MemoryStorage(),
        pkceAsyncStorage: _MemoryAsyncStorage(),
        detectSessionInUri: false,
      ),
    );
  });

  group('cosmetics route', () {
    testWidgets(
      '${RoutePaths.cosmetics} renders the shop when the flag is on',
      (tester) async {
        final container = _newContainer(cosmeticsOn: true);
        await _pumpRoute(tester, container, RoutePaths.cosmetics);

        expect(find.byType(CosmeticsShopScreen), findsOneWidget);
        expect(find.byType(VEmptyView), findsNothing);
        expect(find.text('Marco Neon'), findsOneWidget);
      },
    );

    testWidgets('${RoutePaths.cosmetics} renders the neutral flag-gate '
        'fallback while the flag is off (kill-switch seam)', (tester) async {
      final container = _newContainer(cosmeticsOn: false);
      await _pumpRoute(tester, container, RoutePaths.cosmetics);

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.byType(CosmeticsShopScreen), findsNothing);
      expect(find.text('No disponible'), findsOneWidget);
    });
  });

  group('profile → cosmetics navigation', () {
    testWidgets('the flag-gated profile section navigates to the shop', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final container = _newContainer(cosmeticsOn: true);
      await _pumpRoute(tester, container, RoutePaths.mainProfile);

      // U-15 R9's VEmptyView (empty groups) grew the profile list — the
      // cosmetics row sits below the 800px logical fold; scroll to it first.
      await tester.scrollUntilVisible(find.text('Cosméticos'), 100);
      await tester.ensureVisible(find.text('Cosméticos'));
      await tester.pumpAndSettle();
      expect(find.text('Cosméticos'), findsOneWidget);

      await tester.tap(find.text('Cosméticos'));
      await tester.pumpAndSettle();

      expect(find.byType(CosmeticsShopScreen), findsOneWidget);
      expect(find.text('Marco Neon'), findsOneWidget);
    });

    testWidgets(
      'the profile cosmetics section is hidden while the flag is off',
      (tester) async {
        final container = _newContainer(cosmeticsOn: false);
        await _pumpRoute(tester, container, RoutePaths.mainProfile);

        expect(find.text('Cosméticos'), findsNothing);
      },
    );
  });
}
