import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';

const _black = Color(0xFF000000);

/// All 16 canonical fields, in declaration order (mirrors the extension).
List<Color> _fieldsOf(SamayThemeExtension e) => [
  e.discoBlack,
  e.surface,
  e.surfaceAlt,
  e.hairline,
  e.border,
  e.muted,
  e.mutedStrong,
  e.white,
  e.glowPink,
  e.glowPinkBright,
  e.glowPinkDeep,
  e.discoViolet,
  e.discoCyan,
  e.discoGold,
  e.discoSilver,
  e.discoBronze,
];

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

    test('the palette is complete — every §2 row of the design doc is present, '
        'plus the LUXE pastel tokens (ORCHESTRATION-LUXE)', () {
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
        'pastelRose': Color(0xFFFFD6E8),
        'pastelViolet': Color(0xFFE3D9FF),
        'pastelCyan': Color(0xFFD6F7FF),
        'pastelGold': Color(0xFFFFF3D6),
        'pastelMint': Color(0xFFD8FFEE),
        'pastelPeach': Color(0xFFFFE6D9),
        'mint': Color(0xFF37E6A5),
        'peach': Color(0xFFFF8A65),
        // Chat status ticks (2026-08-15) — verified against white (bubble).
        'statusGrey': Color(0xFF757575),
        'statusRead': Color(0xFF007AFF),
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

    test('documented ratios match the design-doc §2 tables (tolerance 0.02)',
        () {
      expect(AppColors.contrastRatio(AppColors.white, _black), closeTo(21.0, 0.02));
      expect(AppColors.contrastRatio(AppColors.mutedStrong, _black), closeTo(7.37, 0.02));
      expect(AppColors.contrastRatio(AppColors.muted, _black), closeTo(3.66, 0.02));
      expect(AppColors.contrastRatio(AppColors.glowPink, _black), closeTo(6.00, 0.02));
      expect(AppColors.contrastRatio(AppColors.glowPinkBright, _black), closeTo(7.35, 0.02));
      expect(AppColors.contrastRatio(AppColors.glowPinkDeep, _black), closeTo(3.58, 0.02));
      expect(AppColors.contrastRatio(AppColors.discoViolet, _black), closeTo(4.96, 0.02));
      expect(AppColors.contrastRatio(AppColors.discoCyan, _black), closeTo(13.65, 0.02));
      expect(AppColors.contrastRatio(AppColors.discoGold, _black), closeTo(13.71, 0.02));
      expect(AppColors.contrastRatio(AppColors.discoSilver, _black), closeTo(11.54, 0.02));
      expect(AppColors.contrastRatio(AppColors.discoBronze, _black), closeTo(6.68, 0.02));
    });

    test('doc §2.5/§5.1 cross ratios: white-on-pink 3.50, white-on-deep 5.87',
        () {
      expect(
        AppColors.contrastRatio(AppColors.white, AppColors.glowPink),
        closeTo(3.50, 0.02),
        reason: 'white text on a pink fill fails 1.4.3 — §2.5 rule 2',
      );
      expect(
        AppColors.contrastRatio(AppColors.white, AppColors.glowPinkDeep),
        closeTo(5.87, 0.02),
        reason: 'white on glowPinkDeep is the only legal white-on-pink fill',
      );
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

  group('LUXE pastel + vivid tokens (ORCHESTRATION-LUXE §"Foundation API '
      'contract")', () {
    test('every pastel token exists with the exact documented hex', () {
      expect(AppColors.pastelRose, const Color(0xFFFFD6E8));
      expect(AppColors.pastelViolet, const Color(0xFFE3D9FF));
      expect(AppColors.pastelCyan, const Color(0xFFD6F7FF));
      expect(AppColors.pastelGold, const Color(0xFFFFF3D6));
      expect(AppColors.pastelMint, const Color(0xFFD8FFEE));
      expect(AppColors.pastelPeach, const Color(0xFFFFE6D9));
    });

    test('the missing vivid ends mint and peach exist with exact hexes', () {
      expect(AppColors.mint, const Color(0xFF37E6A5));
      expect(AppColors.peach, const Color(0xFFFF8A65));
    });

    test('pastel tokens meet AA normal-text contrast (>= 4.5:1) on black', () {
      for (final color in [
        AppColors.pastelRose,
        AppColors.pastelViolet,
        AppColors.pastelCyan,
        AppColors.pastelGold,
        AppColors.pastelMint,
        AppColors.pastelPeach,
      ]) {
        expect(
          AppColors.contrastRatio(color, _black),
          greaterThanOrEqualTo(4.5),
          reason: '${color.toARGB32().toRadixString(16)} must be >= 4.5:1',
        );
      }
    });

    test('vivid mint/peach clear the non-text threshold (>= 3:1)', () {
      expect(AppColors.contrastRatio(AppColors.mint, _black),
          greaterThanOrEqualTo(3.0));
      expect(AppColors.contrastRatio(AppColors.peach, _black),
          greaterThanOrEqualTo(3.0));
    });

    test('documented LUXE ratios match the token doc comments (tolerance 0.02)',
        () {
      expect(AppColors.contrastRatio(AppColors.pastelRose, _black),
          closeTo(16.04, 0.02));
      expect(AppColors.contrastRatio(AppColors.pastelViolet, _black),
          closeTo(15.64, 0.02));
      expect(AppColors.contrastRatio(AppColors.pastelCyan, _black),
          closeTo(18.61, 0.02));
      expect(AppColors.contrastRatio(AppColors.pastelGold, _black),
          closeTo(19.04, 0.02));
      expect(AppColors.contrastRatio(AppColors.pastelMint, _black),
          closeTo(19.46, 0.02));
      expect(AppColors.contrastRatio(AppColors.pastelPeach, _black),
          closeTo(17.57, 0.02));
      expect(AppColors.contrastRatio(AppColors.mint, _black),
          closeTo(13.02, 0.02));
      expect(AppColors.contrastRatio(AppColors.peach, _black),
          closeTo(9.08, 0.02));
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

  group('semantic aliases (§2 usage roles → canonical tokens)', () {
    test('status/currency roles map to the documented tokens', () {
      expect(AppColors.statusVip, AppColors.discoViolet,
          reason: '§2.3: discoViolet = VIP/subscription tier');
      expect(AppColors.statusOnline, AppColors.discoCyan,
          reason: '§2.3: discoCyan = live/online indicators');
      expect(AppColors.statusLive, AppColors.discoCyan,
          reason: '§2.3: discoCyan = realtime dots');
      expect(AppColors.currencyShards, AppColors.discoGold,
          reason: '§2.3/§5.6: discoGold = shards currency');
    });

    test('success/error/danger roles resolve to legal accent tokens', () {
      expect(AppColors.success, AppColors.discoCyan,
          reason: 'positive signal = the bright cyan token (13.65:1)');
      expect(AppColors.error, AppColors.glowPink,
          reason: '§5.2: error TEXT is glowPink on black (6.00:1 AA)');
      expect(AppColors.errorFill, AppColors.glowPinkDeep,
          reason: '§5.2: error FILL is glowPinkDeep (white text 5.87:1)');
      expect(AppColors.danger, AppColors.glowPinkDeep,
          reason: '§5.1/§5.2: destructive accent is glowPinkDeep, never red');
    });

    test('every alias resolves to a canonical §2 token (no invented colors)',
        () {
      final canonicals = AppColors.all.values.toSet();
      expect(AppColors.semantic, isNotEmpty);
      for (final entry in AppColors.semantic.entries) {
        expect(canonicals.contains(entry.value), isTrue,
            reason: 'alias ${entry.key} must resolve to a §2 token');
      }
    });
  });

  group('SamayThemeExtension lerp (ThemeExtension contract)', () {
    test('lerp(black→white, 0.5) yields #808080 for every color field', () {
      const dark = SamayThemeExtension.dark;
      const allWhite = SamayThemeExtension(
        discoBlack: AppColors.white,
        surface: AppColors.white,
        surfaceAlt: AppColors.white,
        hairline: AppColors.white,
        border: AppColors.white,
        muted: AppColors.white,
        mutedStrong: AppColors.white,
        white: AppColors.white,
        glowPink: AppColors.white,
        glowPinkBright: AppColors.white,
        glowPinkDeep: AppColors.white,
        discoViolet: AppColors.white,
        discoCyan: AppColors.white,
        discoGold: AppColors.white,
        discoSilver: AppColors.white,
        discoBronze: AppColors.white,
      );
      final mid = dark.lerp(allWhite, 0.5);
      final darkFields = _fieldsOf(dark);
      final midFields = _fieldsOf(mid);
      for (var i = 0; i < darkFields.length; i++) {
        final start = darkFields[i];
        final midColor = midFields[i];
        // True midpoint of a field: (start + white)/2 per channel.
        expect(midColor.a, closeTo((start.a + 1) / 2, 0.0001),
            reason: 'alpha midpoint of field $i');
        expect(midColor.r, closeTo((start.r + 1) / 2, 0.0001),
            reason: 'red midpoint of field $i');
        expect(midColor.g, closeTo((start.g + 1) / 2, 0.0001),
            reason: 'green midpoint of field $i');
        expect(midColor.b, closeTo((start.b + 1) / 2, 0.0001),
            reason: 'blue midpoint of field $i');
      }
      // The doc-cited case: lerp(black→white, 0.5) quantizes to #808080.
      expect(mid.discoBlack.r, closeTo(0.5, 0.0001));
      expect(mid.discoBlack.toARGB32(), 0xFF808080,
          reason: 'black→white midpoint quantizes to #808080');
    });

    test('lerp interpolates every field independently', () {
      const a = SamayThemeExtension.dark;
      const b = SamayThemeExtension(
        discoBlack: AppColors.white,
        surface: AppColors.surface,
        surfaceAlt: AppColors.surfaceAlt,
        hairline: AppColors.hairline,
        border: AppColors.border,
        muted: AppColors.muted,
        mutedStrong: AppColors.mutedStrong,
        white: AppColors.white,
        glowPink: AppColors.glowPinkBright,
        glowPinkBright: AppColors.glowPink,
        glowPinkDeep: AppColors.glowPinkDeep,
        discoViolet: AppColors.discoViolet,
        discoCyan: AppColors.discoCyan,
        discoGold: AppColors.discoGold,
        discoSilver: AppColors.discoSilver,
        discoBronze: AppColors.discoBronze,
      );
      final mid = a.lerp(b, 0.5);
      expect(mid.discoBlack.toARGB32(), 0xFF808080,
          reason: 'only discoBlack differs → its quantized midpoint is #808080');
      expect(mid.glowPink, isNot(a.glowPink));
      expect(mid.glowPink, isNot(b.glowPink));
      expect(mid.surface, a.surface, reason: 'identical fields stay identical');
      expect(mid.discoCyan, a.discoCyan);
    });
  });

  group('SamayThemeExtension copyWith (complete)', () {
    test('each of the 16 fields can be overridden independently', () {
      const dark = SamayThemeExtension.dark;
      const other = Color(0xFF123456);
      final fieldNames = _fieldsOf(dark);
      final copies = <SamayThemeExtension>[
        dark.copyWith(discoBlack: other),
        dark.copyWith(surface: other),
        dark.copyWith(surfaceAlt: other),
        dark.copyWith(hairline: other),
        dark.copyWith(border: other),
        dark.copyWith(muted: other),
        dark.copyWith(mutedStrong: other),
        dark.copyWith(white: other),
        dark.copyWith(glowPink: other),
        dark.copyWith(glowPinkBright: other),
        dark.copyWith(glowPinkDeep: other),
        dark.copyWith(discoViolet: other),
        dark.copyWith(discoCyan: other),
        dark.copyWith(discoGold: other),
        dark.copyWith(discoSilver: other),
        dark.copyWith(discoBronze: other),
      ];
      expect(copies, hasLength(fieldNames.length));
      for (var i = 0; i < copies.length; i++) {
        final changed = _fieldsOf(copies[i]);
        expect(changed[i], other,
            reason: 'field $i must be overridden by copyWith');
        for (var j = 0; j < changed.length; j++) {
          if (j != i) {
            expect(changed[j], fieldNames[j],
                reason: 'field $j must be preserved by copyWith($i)');
          }
        }
      }
    });
  });
}
