import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:samay/core/services/shards_service.dart';
import 'package:samay/features/profile/providers/profile_providers.dart';
import 'package:samay/features/shards/screens/shard_ledger_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Widget + mapping tests for the shard ledger screen (SLED — I-64): the two
/// tabs (Shards / Preshards) render their entries with delta chips (positive
/// white / negative gray-strikethrough), reason labels, timestamps and short
/// reference ids; the balance header reads the profile provider; empty/error
/// states render; and every shard/preshard reason enum value maps to a
/// non-empty localized label in both locales.
const _id = '11111111-1111-1111-1111-111111111111';
const _referenceId = '33333333-3333-3333-3333-333333333333';

/// Every `shard_reason` enum value (20260510000001_full_schema.sql:28).
const _shardReasons = [
  'event_attendance',
  'cosmetic_purchase',
  'group_donation',
  'minigame_wager',
  'minigame_win',
  'minigame_refund',
  'subscription_grant',
  'admin_grant',
  'feed_post',
];

/// Every `preshard_reason` enum value (20260510000001_full_schema.sql:29).
const _preshardReasons = [
  'purchased',
  'subscription_grant',
  'event_pool_set',
  'event_pool_consumed',
  'event_pool_returned',
  'admin_grant',
];

Map<String, dynamic> _row({
  String id = _id,
  int delta = 50,
  String reason = 'event_attendance',
  String? referenceId = _referenceId,
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
         LedgerEntry.fromJson(
           _row(
             id: '22222222-2222-2222-2222-222222222222',
             delta: -20,
             reason: 'cosmetic_purchase',
             referenceId: '99999999-9999-9999-9999-999999999999',
           ),
         ),
       ],
       preshardLedger = preshardLedger ?? [
         LedgerEntry.fromJson(
           _row(
             id: '44444444-4444-4444-4444-444444444444',
             delta: 100,
             reason: 'purchased',
           ),
         ),
       ];

  List<LedgerEntry> shardLedger;
  List<LedgerEntry> preshardLedger;
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
    if (shardError != null) throw shardError!;
    return List.of(shardLedger);
  }

  @override
  Future<List<LedgerEntry>> getPreshardLedger({int limit = 100}) async =>
      List.of(preshardLedger);
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
    'preshards': 40,
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
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ShardLedgerScreen(),
    ),
  );
}

Future<void> _pumpLedger(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  group('reason label mapping', () {
    for (final locale in const [Locale('es'), Locale('en')]) {
      test('every shard_reason maps to a non-empty label ($locale)', () async {
        final l10n = await AppLocalizations.delegate.load(locale);
        for (final reason in _shardReasons) {
          final label = shardReasonLabel(l10n, reason);
          expect(label, isNotEmpty, reason: 'empty label for $reason');
          expect(label, isNot(reason),
              reason: 'unmapped reason fell back to the raw value: $reason');
        }
      });

      test('every preshard_reason maps to a non-empty label ($locale)',
          () async {
        final l10n = await AppLocalizations.delegate.load(locale);
        for (final reason in _preshardReasons) {
          final label = preshardReasonLabel(l10n, reason);
          expect(label, isNotEmpty, reason: 'empty label for $reason');
          expect(label, isNot(reason),
              reason: 'unmapped reason fell back to the raw value: $reason');
        }
      });
    }

    test('unknown reasons fall back to the raw value (no crash)', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(shardReasonLabel(l10n, 'future_reason'), 'future_reason');
      expect(preshardReasonLabel(l10n, 'future_reason'), 'future_reason');
    });

    test('every shard reason has a descriptive icon', () async {
      for (final reason in _shardReasons) {
        expect(shardReasonIcon(reason), isNot(Icons.diamond_outlined),
            reason: 'missing icon mapping for $reason');
      }
    });

    test('every preshard reason has a descriptive icon', () async {
      for (final reason in _preshardReasons) {
        expect(preshardReasonIcon(reason), isNot(Icons.diamond_outlined),
            reason: 'missing icon mapping for $reason');
      }
    });
  });

  group('ShardLedgerScreen tabs', () {
    testWidgets('renders the balance header from the profile provider', (
      tester,
    ) async {
      final service = _FakeShardsService();
      await _pumpLedger(tester, _wrap(service: service));

      expect(find.text('120 shards'), findsOneWidget);
      expect(find.text('40 preshards'), findsOneWidget);
      expect(find.text('Ganados'), findsOneWidget);
      expect(find.text('Comprados/Bonos'), findsOneWidget);
    });

    testWidgets('renders both tab labels and switches between them', (
      tester,
    ) async {
      final service = _FakeShardsService();
      await _pumpLedger(tester, _wrap(service: service));

      expect(find.text('Shards'), findsOneWidget);
      expect(find.text('Preshards'), findsOneWidget);

      await tester.tap(find.text('Preshards'));
      await tester.pumpAndSettle();
      expect(find.text('Compra de preshards'), findsOneWidget);
    });

    testWidgets('renders shard entries with reason, delta and reference', (
      tester,
    ) async {
      final service = _FakeShardsService();
      await _pumpLedger(tester, _wrap(service: service));

      expect(find.text('Asistencia a evento'), findsOneWidget);
      expect(find.text('+50'), findsOneWidget);
      expect(find.text('Compra de cosmético'), findsOneWidget);
      expect(find.text('-20'), findsOneWidget);
      expect(find.textContaining('99999999'), findsOneWidget);
      // The row reference is shown shortened (first segment of the uuid).
      expect(find.text('Ref: 99999999-9999-9999-9999-999999999999'), findsNothing);
    });

    testWidgets('renders the preshard tab entries', (tester) async {
      final service = _FakeShardsService();
      await _pumpLedger(tester, _wrap(service: service));

      await tester.tap(find.text('Preshards'));
      await tester.pumpAndSettle();

      expect(find.text('Compra de preshards'), findsOneWidget);
      // +100 appears twice: the net header (Neto: +100) and the entry delta.
      expect(find.text('+100'), findsNWidgets(2));
      expect(find.text('Neto'), findsOneWidget);
    });

    testWidgets('renders the empty state when both ledgers have no rows', (
      tester,
    ) async {
      final service = _FakeShardsService(shardLedger: [], preshardLedger: []);
      await _pumpLedger(tester, _wrap(service: service));

      expect(find.text('Sin movimientos todavía'), findsOneWidget);
    });

    testWidgets('renders an ErrorView with retry when the ledger fails', (
      tester,
    ) async {
      final throwing = _ThrowingLedgerService();
      await _pumpLedger(tester, _wrap(service: throwing));

      expect(find.byType(ErrorView), findsOneWidget);
      expect(
        find.text('No se pudieron cargar los movimientos'),
        findsOneWidget,
      );

      throwing.recover();
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('Asistencia a evento'), findsOneWidget);
    });
  });
}

class _ThrowingLedgerService extends _FakeShardsService {
  _ThrowingLedgerService() : super(shardLedger: [], preshardLedger: []);

  bool _throwing = true;

  void recover() {
    _throwing = false;
    shardLedger = [
      LedgerEntry.fromJson(_row()),
      LedgerEntry.fromJson(
        _row(
          id: '22222222-2222-2222-2222-222222222222',
          delta: -20,
          reason: 'cosmetic_purchase',
        ),
      ),
    ];
  }

  @override
  Future<List<LedgerEntry>> getShardLedger({int limit = 100}) async {
    if (_throwing) throw Exception('ledger exploded');
    return super.getShardLedger();
  }
}
