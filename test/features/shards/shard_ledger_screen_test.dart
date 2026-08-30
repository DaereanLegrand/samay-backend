import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/shards/screens/shard_ledger_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// Mapping tests for the shard ledger (SLED — I-64): every shard/preshard
/// reason enum value maps to a non-empty localized label in both locales,
/// unknown reasons fall back to the raw value, and every reason has a
/// descriptive icon.

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
}
