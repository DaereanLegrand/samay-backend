import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/state_views.dart';

/// Every flag's expected default (I-49 release-gating contract, refreshed by
/// the R1 events sweep): every feature that ships a real screen is LIVE by
/// default — chat (I-38 E2EE), notifications (I-53), feed (I-58 — it's the
/// landing tab), events (R1), qr (I-57), partyFinder (I-60), minigames
/// (I-63), photoUpload (I-59), cosmeticsSection (I-62) and e2ee (always on
/// by design). Only subscriptions stays dark until the RevenueCat SDK key
/// lands (I-61).
const Map<AppFeatureFlag, bool> kDefaultFlagStates = {
  AppFeatureFlag.cosmeticsSection: true,
  AppFeatureFlag.events: true,
  AppFeatureFlag.chat: true,
  AppFeatureFlag.qr: true,
  AppFeatureFlag.feed: true,
  AppFeatureFlag.notifications: true,
  AppFeatureFlag.subscriptions: false,
  AppFeatureFlag.partyFinder: true,
  AppFeatureFlag.minigames: true,
  AppFeatureFlag.photoUpload: true,
  AppFeatureFlag.e2ee: true,
  AppFeatureFlag.themePersistence: false,
};

/// Small consumer that renders the [isEnabled] WidgetRef helper result, so
/// the helper itself is exercised through a real ref.
class _FlagProbe extends ConsumerWidget {
  const _FlagProbe({required this.flag});

  final AppFeatureFlag flag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text(ref.isEnabled(flag) ? 'on' : 'off');
  }
}

/// Probe provider reading the `Ref`-based helper inside a provider build —
/// the seam I-69's router gating will use (`routerProvider` has a `Ref`).
/// Reads the subscriptions flag: the one flag that stays dark by default
/// (RevenueCat key pending, I-61), so the probe's default is deterministic.
final _refProbeProvider = Provider<String>((ref) {
  return ref.isEnabled(AppFeatureFlag.subscriptions) ? 'on' : 'off';
});

Future<void> _pumpGate(
  WidgetTester tester,
  Widget gate, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: gate,
      ),
    ),
  );
}

void main() {
  group('AppFeatureFlags defaults table', () {
    test('every flag resolves to its documented default state', () {
      const flags = AppFeatureFlags();
      for (final flag in AppFeatureFlag.values) {
        expect(
          flags.isEnabled(flag),
          kDefaultFlagStates[flag],
          reason: 'unexpected default for ${flag.name}',
        );
      }
    });

    test('isEnabled matches the per-flag getters', () {
      const flags = AppFeatureFlags();
      expect(flags.isEnabled(AppFeatureFlag.chat), flags.chat);
      expect(flags.isEnabled(AppFeatureFlag.e2ee), flags.e2ee);
      expect(
        flags.isEnabled(AppFeatureFlag.cosmeticsSection),
        flags.cosmeticsSection,
      );
      expect(flags.isEnabled(AppFeatureFlag.events), flags.events);
      expect(
        flags.isEnabled(AppFeatureFlag.notifications),
        flags.notifications,
      );
      expect(
        flags.isEnabled(AppFeatureFlag.subscriptions),
        flags.subscriptions,
      );
      expect(flags.isEnabled(AppFeatureFlag.partyFinder), flags.partyFinder);
      expect(flags.isEnabled(AppFeatureFlag.minigames), flags.minigames);
      expect(flags.isEnabled(AppFeatureFlag.photoUpload), flags.photoUpload);
      expect(
        flags.isEnabled(AppFeatureFlag.themePersistence),
        flags.themePersistence,
      );
      expect(flags.isEnabled(AppFeatureFlag.qr), flags.qr);
      expect(flags.isEnabled(AppFeatureFlag.feed), flags.feed);
    });

    test('a custom instance overrides only the passed flags', () {
      const flags = AppFeatureFlags(events: true, chat: false);
      expect(flags.events, isTrue);
      expect(flags.chat, isFalse);
      expect(flags.subscriptions, isFalse);
      expect(flags.e2ee, isTrue);
    });

    test('instances compare by their full flag set', () {
      expect(const AppFeatureFlags(), const AppFeatureFlags());
      expect(
        const AppFeatureFlags(subscriptions: true),
        isNot(const AppFeatureFlags()),
      );
    });
  });

  group('featureFlagsProvider', () {
    test('resolves to the const default instance', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(featureFlagsProvider), const AppFeatureFlags());
    });

    test('is overridable in tests (ProviderContainer override)', () {
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(events: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      final flags = container.read(featureFlagsProvider);
      expect(flags.events, isTrue);
      expect(flags.chat, isTrue); // untouched flags keep their defaults
      expect(flags.subscriptions, isFalse);
    });

    test('Ref.isEnabled reads the overridden provider', () {
      final container = ProviderContainer(
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(subscriptions: true),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(_refProbeProvider), 'on');
    });

    test('Ref.isEnabled resolves false for a disabled flag', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(_refProbeProvider), 'off');
    });
  });

  group('FlagGate', () {
    test('is const-constructible', () {
      const gate = FlagGate(
        flag: AppFeatureFlag.events,
        child: SizedBox.shrink(),
      );
      expect(gate.flag, AppFeatureFlag.events);
      expect(gate, isA<FlagGate>());
    });

    testWidgets('renders the child when the flag is enabled', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(flag: AppFeatureFlag.events, child: Text('REAL EVENTS')),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(events: true),
          ),
        ],
      );

      expect(find.text('REAL EVENTS'), findsOneWidget);
      expect(find.byType(VEmptyView), findsNothing);
    });

    testWidgets('renders the neutral unavailable fallback when disabled', (
      tester,
    ) async {
      await _pumpGate(
        tester,
        const FlagGate(flag: AppFeatureFlag.events, child: Text('REAL EVENTS')),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(events: false),
          ),
        ],
      );

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('No disponible'), findsOneWidget);
      expect(find.text('REAL EVENTS'), findsNothing);
    });

    testWidgets('the default fallback is the same neutral state for every '
        'dark flag (no per-feature coming-soon copy after R1 sweep)', (
      tester,
    ) async {
      for (final flag in [
        AppFeatureFlag.events,
        AppFeatureFlag.subscriptions,
        AppFeatureFlag.partyFinder,
        AppFeatureFlag.qr,
      ]) {
        // Every feature now ships live by default — flip the flag under test
        // dark so the fallback is exercised.
        await _pumpGate(
          tester,
          FlagGate(flag: flag, child: const Text('REAL')),
          overrides: [
            featureFlagsProvider.overrideWithValue(switch (flag) {
              AppFeatureFlag.events => const AppFeatureFlags(events: false),
              AppFeatureFlag.subscriptions => const AppFeatureFlags(
                subscriptions: false,
              ),
              AppFeatureFlag.partyFinder => const AppFeatureFlags(
                partyFinder: false,
              ),
              AppFeatureFlag.qr => const AppFeatureFlags(qr: false),
              _ => const AppFeatureFlags(),
            }),
          ],
        );
        expect(
          find.byType(VEmptyView),
          findsOneWidget,
          reason: '${flag.name} fallback type',
        );
        expect(
          find.text('No disponible'),
          findsOneWidget,
          reason: '${flag.name} fallback title',
        );
        expect(
          find.text('Esta función aún no está disponible.'),
          findsOneWidget,
          reason: '${flag.name} fallback body',
        );
      }
    });

    testWidgets('a live flag renders its child, not the neutral fallback '
        '(notifications is LIVE via I-53)', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.notifications,
          child: Text('NOTIFICATION CENTER'),
        ),
      );
      expect(find.text('NOTIFICATION CENTER'), findsOneWidget);
      expect(find.byType(VEmptyView), findsNothing);
    });

    testWidgets('flipping a live flag dark restores the neutral unavailable '
        'fallback (kill-switch seam)', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.notifications,
          child: Text('NOTIFICATION CENTER'),
        ),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(notifications: false),
          ),
        ],
      );
      expect(find.text('No disponible'), findsOneWidget);
      expect(find.text('NOTIFICATION CENTER'), findsNothing);
      expect(find.byType(VEmptyView), findsOneWidget);
    });

    testWidgets('an explicit fallback replaces the default', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.events,
          fallback: Text('CUSTOM FALLBACK'),
          child: Text('REAL EVENTS'),
        ),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(events: false),
          ),
        ],
      );

      expect(find.text('CUSTOM FALLBACK'), findsOneWidget);
      expect(find.byType(VEmptyView), findsNothing);
    });

    testWidgets('enabled flag renders the child even when a fallback is set', (
      tester,
    ) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.events,
          fallback: Text('CUSTOM FALLBACK'),
          child: Text('REAL EVENTS'),
        ),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(events: true),
          ),
        ],
      );

      expect(find.text('REAL EVENTS'), findsOneWidget);
      expect(find.text('CUSTOM FALLBACK'), findsNothing);
    });
  });

  group('isEnabled helper via WidgetRef', () {
    testWidgets('resolves false for the dark subscriptions flag', (
      tester,
    ) async {
      await _pumpGate(
        tester,
        const _FlagProbe(flag: AppFeatureFlag.subscriptions),
      );
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('resolves true with an overridden provider', (tester) async {
      await _pumpGate(
        tester,
        const _FlagProbe(flag: AppFeatureFlag.subscriptions),
        overrides: [
          featureFlagsProvider.overrideWithValue(
            const AppFeatureFlags(subscriptions: true),
          ),
        ],
      );
      expect(find.text('on'), findsOneWidget);
    });
  });
}
