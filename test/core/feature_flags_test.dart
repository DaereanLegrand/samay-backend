import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';

/// Every flag's expected default (I-49 release-gating contract): only the
/// features that are LIVE today ship enabled — chat (I-38 E2EE),
/// notifications (I-53 notification center), feed (I-58 — it's the landing
/// tab) and e2ee (always on by design). Everything else ships dark until its
/// feature stack lands behind the flag.
const Map<AppFeatureFlag, bool> kDefaultFlagStates = {
  AppFeatureFlag.cosmeticsSection: false,
  AppFeatureFlag.events: false,
  AppFeatureFlag.chat: true,
  AppFeatureFlag.qr: false,
  AppFeatureFlag.feed: true,
  AppFeatureFlag.notifications: true,
  AppFeatureFlag.subscriptions: false,
  AppFeatureFlag.partyFinder: false,
  AppFeatureFlag.minigames: false,
  AppFeatureFlag.photoUpload: false,
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
final _refProbeProvider = Provider<String>((ref) {
  return ref.isEnabled(AppFeatureFlag.events) ? 'on' : 'off';
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
      expect(flags.isEnabled(AppFeatureFlag.notifications),
          flags.notifications);
      expect(flags.isEnabled(AppFeatureFlag.subscriptions),
          flags.subscriptions);
      expect(flags.isEnabled(AppFeatureFlag.partyFinder), flags.partyFinder);
      expect(flags.isEnabled(AppFeatureFlag.minigames), flags.minigames);
      expect(flags.isEnabled(AppFeatureFlag.photoUpload), flags.photoUpload);
      expect(flags.isEnabled(AppFeatureFlag.themePersistence),
          flags.themePersistence);
      expect(flags.isEnabled(AppFeatureFlag.qr), flags.qr);
      expect(flags.isEnabled(AppFeatureFlag.feed), flags.feed);
    });

    test('a custom instance overrides only the passed flags', () {
      const flags = AppFeatureFlags(events: true, chat: false);
      expect(flags.events, isTrue);
      expect(flags.chat, isFalse);
      expect(flags.cosmeticsSection, isFalse);
      expect(flags.e2ee, isTrue);
    });

    test('instances compare by their full flag set', () {
      expect(const AppFeatureFlags(), const AppFeatureFlags());
      expect(
        const AppFeatureFlags(events: true),
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
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(events: true)),
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
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(events: true)),
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
        const FlagGate(
          flag: AppFeatureFlag.events,
          child: Text('REAL EVENTS'),
        ),
        overrides: [
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(events: true)),
        ],
      );

      expect(find.text('REAL EVENTS'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });

    testWidgets('renders the VComingSoonScreen fallback when disabled',
        (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.events,
          child: Text('REAL EVENTS'),
        ),
      );

      expect(find.byType(VComingSoonScreen), findsOneWidget);
      expect(find.text('Pr\u00f3ximamente'), findsOneWidget);
      expect(find.text('REAL EVENTS'), findsNothing);
    });

    testWidgets('default fallback carries the localized title per gated flag',
        (tester) async {
      for (final (flag, title, icon) in [
        (AppFeatureFlag.events, 'Eventos', Icons.event),
        (AppFeatureFlag.subscriptions, 'Suscripciones', Icons.subscriptions),
        (AppFeatureFlag.partyFinder, 'Party Finder', Icons.celebration),
        (AppFeatureFlag.qr, 'QR', Icons.qr_code),
      ]) {
        await _pumpGate(
          tester,
          FlagGate(flag: flag, child: const Text('REAL')),
        );
        expect(find.text(title), findsOneWidget,
            reason: '${flag.name} fallback title');
        expect(find.byType(VComingSoonScreen), findsOneWidget,
            reason: '${flag.name} fallback type');
        expect(find.byIcon(icon), findsOneWidget,
            reason: '${flag.name} fallback icon');
      }
    });

    testWidgets('partyFinder fallback icon uses the §5.7 faint glowPink hero '
        'color', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.partyFinder,
          child: Text('REAL'),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.celebration));
      expect(icon.color, AppColors.glowPink.withValues(alpha: 0.5));
    });

    testWidgets(
        'a live flag renders its child, not the coming-soon fallback '
        '(notifications is LIVE via I-53)', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.notifications,
          child: Text('NOTIFICATION CENTER'),
        ),
      );
      expect(find.text('NOTIFICATION CENTER'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });

    testWidgets(
        'flipping a live flag dark restores the localized coming-soon '
        'fallback (kill-switch seam)', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.notifications,
          child: Text('NOTIFICATION CENTER'),
        ),
        overrides: [
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(notifications: false)),
        ],
      );
      expect(find.text('Notificaciones'), findsOneWidget);
      expect(find.byIcon(Icons.notifications), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsOneWidget);
    });

    testWidgets('an explicit fallback replaces the default', (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.events,
          fallback: Text('CUSTOM FALLBACK'),
          child: Text('REAL EVENTS'),
        ),
      );

      expect(find.text('CUSTOM FALLBACK'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });

    testWidgets('enabled flag renders the child even when a fallback is set',
        (tester) async {
      await _pumpGate(
        tester,
        const FlagGate(
          flag: AppFeatureFlag.events,
          fallback: Text('CUSTOM FALLBACK'),
          child: Text('REAL EVENTS'),
        ),
        overrides: [
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(events: true)),
        ],
      );

      expect(find.text('REAL EVENTS'), findsOneWidget);
      expect(find.text('CUSTOM FALLBACK'), findsNothing);
    });
  });

  group('isEnabled helper via WidgetRef', () {
    testWidgets('resolves false with the default flags', (tester) async {
      await _pumpGate(tester, const _FlagProbe(flag: AppFeatureFlag.events));
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('resolves true with an overridden provider', (tester) async {
      await _pumpGate(
        tester,
        const _FlagProbe(flag: AppFeatureFlag.events),
        overrides: [
          featureFlagsProvider
              .overrideWithValue(const AppFeatureFlags(events: true)),
        ],
      );
      expect(find.text('on'), findsOneWidget);
    });
  });
}
