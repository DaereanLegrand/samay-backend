import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/features/subscriptions/screens/paywall_screen.dart';


/// Paywall pure-logic tests (I-61, PLAN): PEN formatting, price lookup from a
/// fake `app_config` (`subs.*_price_pen`), current-tier resolution from the
/// auth state, and the full §7 comparison table.
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
          const AuthState(
            user: {
              'user_metadata': {'subscription_tier': 'vip'},
            },
          ),
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
}
