import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';

/// Contract tests for the typography token layer
/// (DISCO-DESIGN-SYSTEM.md §3.3 type-scale table + §3.4 glow stacks).
///
/// The §3.3 table is the authoritative contract: every role's family, size,
/// weight, letter-spacing and height are asserted table-driven. §3.4 defines
/// the two canonical glow stacks (strong 3-layer, soft 2-layer) with blur
/// radii computed from the style's fontSize (`em`-relative).
void main() {
  const playfair = 'Playfair Display';
  const inter = 'Inter';

  // ── Role table (doc §3.3, verbatim) ─────────────────────────────────────
  // (name, style, family, size, weight, fontStyle, letterSpacing, height)
  const roles = <(String, TextStyle, String, double, FontWeight, FontStyle?,
      double, double)>[
    ('displayLarge', AppTypography.displayLarge, playfair, 64,
        FontWeight.w700, FontStyle.italic, -1.9, 1.0),
    ('displayMedium', AppTypography.displayMedium, playfair, 40,
        FontWeight.w700, FontStyle.italic, -1.2, 1.0),
    ('displaySmall', AppTypography.displaySmall, playfair, 32,
        FontWeight.w700, FontStyle.italic, -1.0, 1.05),
    ('headlineLarge', AppTypography.headlineLarge, playfair, 28,
        FontWeight.w600, FontStyle.italic, -0.8, 1.1),
    ('headlineMedium', AppTypography.headlineMedium, inter, 24,
        FontWeight.w700, null, -0.3, 1.2),
    ('headlineSmall', AppTypography.headlineSmall, inter, 20,
        FontWeight.w600, null, -0.2, 1.3),
    ('titleLarge', AppTypography.titleLarge, inter, 18, FontWeight.w600, null,
        0, 1.4),
    ('titleMedium', AppTypography.titleMedium, inter, 16, FontWeight.w500,
        null, 0, 1.4),
    ('bodyLarge', AppTypography.bodyLarge, inter, 16, FontWeight.w300, null, 0,
        1.5),
    ('bodyMedium', AppTypography.bodyMedium, inter, 14, FontWeight.w300, null,
        0, 1.5),
    ('bodySmall', AppTypography.bodySmall, inter, 12, FontWeight.w400, null, 0,
        1.5),
    ('labelLarge', AppTypography.labelLarge, inter, 14, FontWeight.w700, null,
        1.2, 1.2),
    ('labelMedium', AppTypography.labelMedium, inter, 12, FontWeight.w600,
        null, 0.8, 1.3),
    ('labelSmall', AppTypography.labelSmall, inter, 10, FontWeight.w500, null,
        1.2, 1.3),
    ('otpInputText', AppTypography.otpInputText, inter, 30, FontWeight.w800,
        null, 8, 1.5),
  ];

  group('AppTypography role table (doc §3.3)', () {
    for (final (name, style, family, size, weight, fontStyle, ls, height)
        in roles) {
      test('$name is $family $size '
          '${fontStyle == FontStyle.italic ? 'italic ' : ''}ls $ls h $height',
          () {
        expect(style.fontFamily, family, reason: '$name family');
        expect(style.fontSize, size, reason: '$name size');
        expect(style.fontWeight, weight, reason: '$name weight');
        expect(style.fontStyle, fontStyle, reason: '$name style');
        expect(style.letterSpacing, ls, reason: '$name letter-spacing');
        expect(style.height, height, reason: '$name height');
      });
    }
  });

  group('AppTypography const-constructibility', () {
    test('role styles are const-constructible', () {
      // Declaring them as compile-time consts only compiles if the static
      // styles are true const TextStyles (const canonicalization).
      const displayLarge = AppTypography.displayLarge;
      const headlineMedium = AppTypography.headlineMedium;
      const otpInputText = AppTypography.otpInputText;
      expect(displayLarge.fontSize, 64);
      expect(headlineMedium.fontSize, 24);
      expect(otpInputText.fontSize, 30);
    });

    test('const styles are canonical (identical across references)', () {
      expect(identical(AppTypography.displayLarge, AppTypography.displayLarge),
          isTrue);
      expect(identical(AppTypography.bodyLarge, AppTypography.bodyLarge),
          isTrue);
    });
  });

  group('AppTypography.fancyTitle (glow treatment, doc §3.4)', () {
    test('strong variant applies the 3-layer canonical stack', () {
      const base = TextStyle(fontSize: 40);
      final glow = AppTypography.fancyTitle(base);
      final shadows = glow.shadows;
      expect(shadows, isNotNull);
      expect(shadows, hasLength(3));
      expect(shadows![0].color, AppColors.glowPink.withValues(alpha: 0.9));
      expect(shadows[0].blurRadius, closeTo(40 * 0.35, 0.001));
      expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.5));
      expect(shadows[1].blurRadius, closeTo(40 * 0.7, 0.001));
      expect(shadows[2].color, AppColors.glowPink.withValues(alpha: 0.25));
      expect(shadows[2].blurRadius, closeTo(40 * 1.0, 0.001));
    });

    test('soft variant applies the 2-layer canonical stack', () {
      const base = TextStyle(fontSize: 28);
      final glow = AppTypography.fancyTitle(base, soft: true);
      final shadows = glow.shadows;
      expect(shadows, isNotNull);
      expect(shadows, hasLength(2));
      expect(shadows![0].color, AppColors.glowPink.withValues(alpha: 0.6));
      expect(shadows[0].blurRadius, closeTo(28 * 0.3, 0.001));
      expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.25));
      expect(shadows[1].blurRadius, closeTo(28 * 0.6, 0.001));
    });

    test('keeps the base italic + bold treatment', () {
      final glow = AppTypography.fancyTitle(AppTypography.displayLarge);
      expect(glow.fontStyle, FontStyle.italic);
      expect(glow.fontWeight, FontWeight.w700);
      expect(glow.fontFamily, playfair);
      expect(glow.fontSize, 64);
    });

    test('keeps the glyph fill opaque (halo strictly behind text, §7.4)', () {
      final glow = AppTypography.fancyTitle(const TextStyle(fontSize: 64));
      expect(glow.shadows, isNotEmpty);
      expect(glow.color, isNull,
          reason: 'the fill color must stay inherited/full-opacity');
      expect(glow.foreground, isNull,
          reason: 'a foreground paint would override the fill');
    });

    test('blur radii scale with fontSize (em-relative)', () {
      final small = AppTypography.fancyTitle(const TextStyle(fontSize: 32));
      final large = AppTypography.fancyTitle(const TextStyle(fontSize: 64));
      expect(small.shadows![0].blurRadius, closeTo(32 * 0.35, 0.001));
      expect(large.shadows![0].blurRadius, closeTo(64 * 0.35, 0.001));
      expect(large.shadows![2].blurRadius, closeTo(64 * 1.0, 0.001));
    });
  });

  group('AppTypography.textTheme (composed, consumed by SamayTheme)', () {
    test('display roles use Playfair Display italic with glow', () {
      final theme = AppTypography.textTheme;
      for (final style in [
        theme.displayLarge,
        theme.displayMedium,
        theme.displaySmall,
      ]) {
        expect(style!.fontFamily, playfair);
        expect(style.fontStyle, FontStyle.italic);
        expect(style.shadows, isNotNull);
        expect(style.shadows, isNotEmpty);
      }
    });

    test('headlineLarge is Playfair italic 28 with the soft stack', () {
      final style = AppTypography.textTheme.headlineLarge!;
      expect(style.fontFamily, playfair);
      expect(style.fontStyle, FontStyle.italic);
      expect(style.fontWeight, FontWeight.w600);
      expect(style.shadows, hasLength(2));
      expect(style.shadows!.first.color,
          AppColors.glowPink.withValues(alpha: 0.6));
    });

    test('body/UI roles use Inter and carry no glow', () {
      final theme = AppTypography.textTheme;
      for (final style in [
        theme.headlineMedium,
        theme.headlineSmall,
        theme.titleLarge,
        theme.titleMedium,
        theme.bodyLarge,
        theme.bodyMedium,
        theme.bodySmall,
        theme.labelLarge,
        theme.labelMedium,
        theme.labelSmall,
      ]) {
        expect(style!.fontFamily, inter, reason: 'role must be Inter');
        expect(style.shadows, isNull, reason: 'no glow on UI/body roles');
      }
    });

    test('textTheme displayLarge matches the const base plus glow', () {
      final themed = AppTypography.textTheme.displayLarge!;
      expect(themed.fontFamily, AppTypography.displayLarge.fontFamily);
      expect(themed.fontSize, AppTypography.displayLarge.fontSize);
      expect(themed.fontWeight, AppTypography.displayLarge.fontWeight);
      expect(themed.fontStyle, AppTypography.displayLarge.fontStyle);
      expect(themed.letterSpacing, AppTypography.displayLarge.letterSpacing);
      expect(themed.shadows, isNotNull);
      expect(themed.shadows, hasLength(3));
    });
  });
}
