import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/app_router.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/features/profile/screens/profile_screen.dart';
import 'package:samay/features/shards/screens/shard_ledger_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Route-level navigation tests for the shard ledger (SLED — I-64): the
/// profile balance card navigates to `/shards/ledger`, and the route renders
/// the ledger screen. The shards economy is LIVE (donations exist), so the
/// route is NOT flag-gated — it always renders the screen.
const _id = '11111111-1111-1111-1111-111111111111';

Map<String, dynamic> _row({String id = _id, int delta = 50}) => {
  'id': id,
  'delta': delta,
  'reason': 'event_attendance',
  'reference_id': null,
  'created_at': DateTime.utc(2026, 8, 1, 21, 30).toIso8601String(),
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
  Future<List<LedgerEntry>> getShardLedger({int limit = 100}) async => [
    LedgerEntry.fromJson(_row()),
  ];

  @override
  Future<List<LedgerEntry>> getPreshardLedger({int limit = 100}) async => const [];
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

ProviderContainer _newContainer() {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_FakeAuthNotifier.new),
      shardsServiceProvider.overrideWithValue(_FakeShardsService()),
      myProfileProvider.overrideWith(
        () => _StubProfileNotifier(
          _StubProfileFetcher(
            () async => const {
              'username': 'dana',
              'personal_shards': 120,
              'preshards': 40,
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

  group('shards ledger route', () {
    testWidgets('${RoutePaths.shardsLedger} renders the ledger screen '
        '(live route — no flag)', (tester) async {
      final container = _newContainer();
      await _pumpRoute(tester, container, RoutePaths.shardsLedger);

      expect(find.byType(ShardLedgerScreen), findsOneWidget);
      expect(find.text('Asistencia a evento'), findsOneWidget);
    });
  });

  group('profile → shards ledger navigation', () {
    testWidgets('tapping the balance card navigates to the ledger', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final container = _newContainer();
      await _pumpRoute(tester, container, RoutePaths.mainProfile);

      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('120 shards'), findsOneWidget);

      await tester.tap(find.text('120 shards'));
      await tester.pumpAndSettle();

      expect(find.byType(ShardLedgerScreen), findsOneWidget);
      expect(find.text('Asistencia a evento'), findsOneWidget);
    });
  });
}
