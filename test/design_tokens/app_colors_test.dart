import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';

const _black = Color(0xFF000000);

void main() {
  group('AppColors palette (DISCO-DESIGN-SYSTEM.md §2)', () {
    test('every neutral token exists with the exact documented hex', () {
      expect(AppColors.discoBlack, const Color(0xFF000000));
      expect(AppColors.surface, const Color(0xFF0A0A0A));
      expect(AppColors.surfaceAlt, const Color(0xFF111111));
      expect(AppColors.hairline, const Color(0xFF1A1A1A));
      expect(AppColors.border, const Color(0xFF333333));
      expect(AppColors.muted, const Color(0xFF666666));
      expect(AppColors.mutedStrong, const Color(0xFF999999));
      expect(AppColors.white, const Color(0xFFFFFFFF));
    });

    test('every glow-pink token exists with the exact documented hex', () {
      expect(AppColors.glowPink, const Color(0xFFFF2E88));
      expect(AppColors.glowPinkBright, const Color(0xFFFF5CA8));
      expect(AppColors.glowPinkDeep, const Color(0xFFC2185B));
    });

    test('every disco accent token exists with the exact documented hex', () {
      expect(AppColors.discoViolet, const Color(0xFF8B5CF6));
      expect(AppColors.discoCyan, const Color(0xFF00E5FF));
      expect(AppColors.discoGold, const Color(0xFFFFC94D));
      expect(AppColors.discoSilver, const Color(0xFFC0C0C0));
      expect(AppColors.discoBronze, const Color(0xFFCD7F32));
    });

    test('the palette is complete — every §2 row of the design doc is present',
        () {
      const expected = <String, Color>{
        'discoBlack': Color(0xFF000000),
        'surface': Color(0xFF0A0A0A),
        'surfaceAlt': Color(0xFF111111),
        'hairline': Color(0xFF1A1A1A),
        'border': Color(0xFF333333),
        'muted': Color(0xFF666666),
        'mutedStrong': Color(0xFF999999),
        'white': Color(0xFFFFFFFF),
        'glowPink': Color(0xFFFF2E88),
        'glowPinkBright': Color(0xFFFF5CA8),
        'glowPinkDeep': Color(0xFFC2185B),
        'discoViolet': Color(0xFF8B5CF6),
        'discoCyan': Color(0xFF00E5FF),
        'discoGold': Color(0xFFFFC94D),
        'discoSilver': Color(0xFFC0C0C0),
        'discoBronze': Color(0xFFCD7F32),
      };
      for (final entry in expected.entries) {
        expect(AppColors.all[entry.key], entry.value,
            reason: 'palette entry missing or wrong value: ${entry.key}');
      }
      expect(AppColors.all.length, expected.length);
    });
  });

  group('WCAG contrast on black (§2.5 / §7.1)', () {
    test('text-safe tokens meet AA normal-text contrast (>= 4.5:1) on black',
        () {
      const textSafe = <Color>[
        AppColors.white,
        AppColors.mutedStrong,
        AppColors.glowPink,
        AppColors.glowPinkBright,
        AppColors.discoViolet,
        AppColors.discoCyan,
        AppColors.discoGold,
        AppColors.discoSilver,
        AppColors.discoBronze,
      ];
      for (final color in textSafe) {
        expect(
          AppColors.contrastRatio(color, _black),
          greaterThanOrEqualTo(4.5),
          reason: '${color.toARGB32().toRadixString(16)} must be >= 4.5:1',
        );
      }
    });

    test('muted (#666666) is legal only for large text (3:1 <= ratio < 4.5:1)',
        () {
      final ratio = AppColors.contrastRatio(AppColors.muted, _black);
      expect(ratio, greaterThanOrEqualTo(3.0));
      expect(ratio, lessThan(4.5));
    });

    test('glowPinkDeep is legal only for AA-large / pressed states', () {
      final ratio = AppColors.contrastRatio(AppColors.glowPinkDeep, _black);
      expect(ratio, greaterThanOrEqualTo(3.0));
      expect(ratio, lessThan(4.5));
    });

    test('depth-only surfaces never pass text contrast (documented)', () {
      for (final color in [
        AppColors.surface,
        AppColors.surfaceAlt,
        AppColors.hairline,
        AppColors.border,
      ]) {
        expect(AppColors.contrastRatio(color, _black), lessThan(3.0),
            reason: '${color.toARGB32().toRadixString(16)} is depth-only');
      }
    });

    test('documented ratios match the design-doc §2 tables (tolerance 0.05)',
        () {
      expect(AppColors.contrastRatio(AppColors.white, _black), closeTo(21.0, 0.05));
      expect(AppColors.contrastRatio(AppColors.mutedStrong, _black), closeTo(7.37, 0.05));
      expect(AppColors.contrastRatio(AppColors.muted, _black), closeTo(3.66, 0.05));
      expect(AppColors.contrastRatio(AppColors.glowPink, _black), closeTo(6.00, 0.05));
      expect(AppColors.contrastRatio(AppColors.glowPinkBright, _black), closeTo(7.35, 0.05));
      expect(AppColors.contrastRatio(AppColors.glowPinkDeep, _black), closeTo(3.58, 0.05));
      expect(AppColors.contrastRatio(AppColors.discoViolet, _black), closeTo(4.96, 0.05));
      expect(AppColors.contrastRatio(AppColors.discoCyan, _black), closeTo(13.65, 0.05));
      expect(AppColors.contrastRatio(AppColors.discoGold, _black), closeTo(13.71, 0.05));
      expect(AppColors.contrastRatio(AppColors.discoSilver, _black), closeTo(11.54, 0.05));
      expect(AppColors.contrastRatio(AppColors.discoBronze, _black), closeTo(6.68, 0.05));
    });

    test('contrast is symmetric and white-on-black is 21:1', () {
      expect(
        AppColors.contrastRatio(_black, AppColors.white),
        AppColors.contrastRatio(AppColors.white, _black),
      );
      expect(
        AppColors.contrastRatio(AppColors.white, _black),
        closeTo(21.0, 0.01),
      );
    });
  });

  group('AppColors.contrastRatio helper', () {
    test('identical colors have ratio 1.0', () {
      expect(AppColors.contrastRatio(_black, _black), closeTo(1.0, 0.0001));
      expect(AppColors.contrastRatio(AppColors.white, AppColors.white),
          closeTo(1.0, 0.0001));
    });

    test('is a pure function of the two colors (no state)', () {
      final first = AppColors.contrastRatio(AppColors.glowPink, _black);
      final second = AppColors.contrastRatio(AppColors.glowPink, _black);
      expect(first, second);
      expect(first, greaterThan(0));
    });
  });
}
