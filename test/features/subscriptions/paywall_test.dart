import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/features/subscriptions/paywall_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/v_button.dart';

import '../../support/fake_config_provider.dart';

/// Paywall screen tests (I-61, PLAN): tier table rendered from a fake
/// `app_config` (`subs.*_price_pen`), PEN formatting, current-tier badge from
/// the auth state, and stub-mode disabled purchase buttons.
///
/// Prices are asserted as formatted PEN strings — the screen must read
/// `app_config` and never hardcode a price.
const _proMonthly = '1999';
const _proAnnual = '19990';
const _vipMonthly = '4999';
const _vipAnnual = '49990';

Map<String, String> _fakeConfig() => {
      'subs.pro_monthly_price_pen': _proMonthly,
      'subs.pro_annual_price_pen': _proAnnual,
      'subs.vip_monthly_price_pen': _vipMonthly,
      'subs.vip_annual_price_pen': _vipAnnual,
    };

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.user);

  final Map<String, dynamic>? user;

  @override
  Future<AuthState> build() async => AuthState(
        authenticated: true,
        hasProfile: true,
        user: user,
      );
}

ProviderContainer _container({Map<String, dynamic>? user}) {
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(() => _FakeAuthNotifier(user)),
    appConfigProvider.overrideWith(() => FakeAppConfigNotifier(_fakeConfig())),
  ]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  // The paywall is a vertical scroll of 3 tier cards; give the widget tests a
  // tall surface so every card (incl. the VIP "Actual" badge and the third
  // tooltip) is rendered and findable (the ListView only builds visible
  // children otherwise).
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PaywallScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('paywall pure helpers', () {
    test('formatPEN renders centimos as Peruvian soles', () {
      expect(formatPEN(1999), 'S/ 19.99');
      expect(formatPEN(4999), 'S/ 49.99');
      expect(formatPEN(0), 'S/ 0.00');
      expect(formatPEN(1666), 'S/ 16.66');
    });

    test('paywallMonthlyPrice/paywallAnnualPrice read app_config keys', () {
      final config = _fakeConfig();
      expect(paywallMonthlyPrice('free', config), 0);
      expect(paywallMonthlyPrice('pro', config), 1999);
      expect(paywallMonthlyPrice('vip', config), 4999);
      expect(paywallAnnualPrice('pro', config), 19990);
      expect(paywallAnnualPrice('vip', config), 49990);
    });

    test('prices fall back to the seeded defaults when keys are missing', () {
      expect(paywallMonthlyPrice('pro', {}), 1999);
      expect(paywallMonthlyPrice('vip', {}), 4999);
      expect(paywallAnnualPrice('pro', {}), 19990);
      expect(paywallAnnualPrice('vip', {}), 49990);
      expect(paywallMonthlyPrice('free', {}), 0);
    });

    test('currentTierFromAuth resolves the tier from the auth user JSON', () {
      expect(currentTierFromAuth(const AuthState()), isNull);
      expect(
        currentTierFromAuth(
          const AuthState(user: {'subscription_tier': 'free'}),
        ),
        'free',
      );
      expect(
        currentTierFromAuth(
          const AuthState(user: {'subscription_tier': 'pro'}),
        ),
        'pro',
      );
      expect(
        currentTierFromAuth(
          const AuthState(user: {'subscription_tier': 'vip'}),
        ),
        'vip',
      );
      expect(
        currentTierFromAuth(
          const AuthState(user: {
            'user_metadata': {'subscription_tier': 'vip'},
          }),
        ),
        'vip',
      );
      // Unknown tiers and absent user JSON must NOT claim the free tier —
      // the screen renders no badge instead (null).
      expect(
        currentTierFromAuth(
          const AuthState(user: {'subscription_tier': 'admin'}),
        ),
        isNull,
      );
    });

    test('paywallRows covers the full spec §7 comparison table', () {
      expect(paywallRows, hasLength(8));
      expect(paywallTiers, hasLength(3));
      expect(paywallTiers.map((t) => t.id), ['free', 'pro', 'vip']);
    });
  });

  group('PaywallScreen', () {
    testWidgets('renders the three tiers with prices from the fake app_config',
        (tester) async {
      await _pump(tester, _container());

      expect(find.byType(PaywallScreen), findsOneWidget);

      // Tier names (all three visible — App Store compliance).
      for (final title in ['Free', 'PRO', 'VIP']) {
        expect(find.text(title), findsOneWidget);
      }

      // Monthly prices, formatted PEN from app_config (never hardcoded).
      expect(find.text('S/ 19.99/mes'), findsOneWidget);
      expect(find.text('S/ 49.99/mes'), findsOneWidget);

      // Annual rows: monthly equivalent of the annual price + 17% savings.
      expect(find.textContaining('S/ 16.66/mes'), findsOneWidget);
      expect(find.textContaining('S/ 41.66/mes'), findsOneWidget);
      expect(find.textContaining('ahorrando 17%'), findsNWidgets(2));

      // Feature table rows render for each tier card.
      expect(find.text('Eventos por día'), findsNWidgets(3));
      // The spec §7 "Miembros" row: Free=14 / PRO=256 / VIP=Ilimitado —
      // each card shows the full row, so the cell appears once per card.
      expect(find.text('Ilimitado'), findsNWidgets(3));
    });

    testWidgets('marks the current tier with the Actual badge', (tester) async {
      await _pump(
        tester,
        _container(user: {'subscription_tier': 'vip'}),
      );
      expect(find.text('Actual'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PaywallScreen),
          matching: find.text('VIP'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no Actual badge when the tier is unknown or absent',
        (tester) async {
      await _pump(tester, _container());
      expect(find.text('Actual'), findsNothing);
    });

    testWidgets('purchase buttons are disabled with a Próximamente tooltip '
        'in stub mode', (tester) async {
      await _pump(tester, _container());

      // Two upgrade buttons + the restore button — all disabled.
      final buttons = tester.widgetList<VButton>(find.byType(VButton));
      expect(buttons.length, 3);
      for (final button in buttons) {
        expect(button.onPressed, isNull,
            reason: 'stub mode must never enable a purchase');
      }
      expect(find.byTooltip('Próximamente'), findsNWidgets(3));
    });

    testWidgets('renders the ErrorView when app_config fails to load',
        (tester) async {
      final container = ProviderContainer(overrides: [
        authStateProvider.overrideWith(() => _FakeAuthNotifier(null)),
        appConfigProvider.overrideWith(
          () => FailingAppConfigNotifier(Exception('connection refused')),
        ),
      ]);
      addTearDown(container.dispose);

      await _pump(tester, container);

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('S/ 19.99/mes'), findsNothing);
    });
  });
}
