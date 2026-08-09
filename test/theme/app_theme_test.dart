import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/theme/app_theme.dart';

void main() {
  group('SamayTheme', () {
    test('provides dark ThemeData', () {
      final theme = SamayTheme.dark;
      expect(theme.brightness, Brightness.dark);
    });

    test('scaffold background is black', () {
      final theme = SamayTheme.dark;
      expect(theme.scaffoldBackgroundColor, Colors.black);
    });

    test('color scheme surface is black and onSurface is white', () {
      final theme = SamayTheme.dark;
      expect(theme.colorScheme.surface, Colors.black);
      expect(theme.colorScheme.onSurface, Colors.white);
    });

    test('primary color is white', () {
      final theme = SamayTheme.dark;
      expect(theme.colorScheme.primary, Colors.white);
    });

    test('onPrimary is black (white fills carry black text)', () {
      final theme = SamayTheme.dark;
      expect(theme.colorScheme.onPrimary, Colors.black);
    });

    group('display typography (Playfair Display)', () {
      test('displayLarge uses Playfair Display italic 700 at 64', () {
        final style = SamayTheme.dark.textTheme.displayLarge;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Playfair Display');
        expect(style.fontStyle, FontStyle.italic);
        expect(style.fontWeight, FontWeight.w700);
        expect(style.fontSize, 64);
      });

      test('displayMedium uses Playfair Display italic 700 at 40', () {
        final style = SamayTheme.dark.textTheme.displayMedium;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Playfair Display');
        expect(style.fontStyle, FontStyle.italic);
        expect(style.fontWeight, FontWeight.w700);
        expect(style.fontSize, 40);
      });

      test('displaySmall uses Playfair Display italic 700 at 32', () {
        final style = SamayTheme.dark.textTheme.displaySmall;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Playfair Display');
        expect(style.fontStyle, FontStyle.italic);
        expect(style.fontWeight, FontWeight.w700);
        expect(style.fontSize, 32);
      });

      test('headlineLarge uses Playfair Display italic 600 at 28', () {
        final style = SamayTheme.dark.textTheme.headlineLarge;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Playfair Display');
        expect(style.fontStyle, FontStyle.italic);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.fontSize, 28);
      });
    });

    group('glow title treatment', () {
      test('displayLarge carries the glow-strong shadow stack', () {
        final style = SamayTheme.dark.textTheme.displayLarge!;
        final shadows = style.shadows;
        expect(shadows, isNotNull);
        expect(shadows, isNotEmpty);
        expect(shadows!.length, 3);
        expect(shadows.first.color,
            AppColors.glowPink.withValues(alpha: 0.9));
        expect(shadows.first.blurRadius, closeTo(64 * 0.35, 0.001));
        expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.5));
        expect(shadows[1].blurRadius, closeTo(64 * 0.7, 0.001));
        expect(shadows[2].color,
            AppColors.glowPink.withValues(alpha: 0.25));
        expect(shadows[2].blurRadius, closeTo(64 * 1.0, 0.001));
      });

      test('headlineLarge carries the glow-soft stack (2 layers)', () {
        final style = SamayTheme.dark.textTheme.headlineLarge!;
        final shadows = style.shadows;
        expect(shadows, isNotNull);
        expect(shadows!.length, 2);
        expect(shadows.first.color,
            AppColors.glowPink.withValues(alpha: 0.6));
        expect(shadows.first.blurRadius, closeTo(28 * 0.3, 0.001));
        expect(shadows[1].color,
            AppColors.glowPink.withValues(alpha: 0.25));
        expect(shadows[1].blurRadius, closeTo(28 * 0.6, 0.001));
      });

      test('body styles carry no glow', () {
        final theme = SamayTheme.dark;
        expect(theme.textTheme.bodyLarge?.shadows, isNull);
        expect(theme.textTheme.bodyMedium?.shadows, isNull);
        expect(theme.textTheme.headlineMedium?.shadows, isNull);
      });

      test('glowTitleStyle computes the stack from the given fontSize', () {
        final glow = SamayTheme.glowTitleStyle(const TextStyle(fontSize: 40));
        expect(glow.shadows, hasLength(3));
        expect(glow.shadows!.first.blurRadius, closeTo(40 * 0.35, 0.001));
        expect(glow.shadows![1].blurRadius, closeTo(40 * 0.7, 0.001));
        expect(glow.shadows![2].blurRadius, closeTo(40 * 1.0, 0.001));
        expect(glow.shadows!.first.color,
            AppColors.glowPink.withValues(alpha: 0.9));
      });

      test('glowTitleStyle soft variant uses the 2-layer stack', () {
        final glow = SamayTheme.glowTitleStyle(
          const TextStyle(fontSize: 28),
          soft: true,
        );
        expect(glow.shadows, hasLength(2));
        expect(glow.shadows!.first.blurRadius, closeTo(28 * 0.3, 0.001));
        expect(glow.shadows![1].blurRadius, closeTo(28 * 0.6, 0.001));
      });

      test('glow keeps the glyph fill opaque (halo strictly behind text)', () {
        final glow = SamayTheme.glowTitleStyle(const TextStyle(fontSize: 64));
        expect(glow.shadows, isNotEmpty);
        expect(glow.color, isNull,
            reason: 'the fill color must stay inherited/full-opacity');
      });
    });

    group('body typography (Inter)', () {
      test('bodyLarge keeps Inter light 300 at 16', () {
        final style = SamayTheme.dark.textTheme.bodyLarge;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Inter');
        expect(style.fontWeight, FontWeight.w300);
        expect(style.fontSize, 16);
      });

      test('bodyMedium keeps Inter light 300 at 14', () {
        final style = SamayTheme.dark.textTheme.bodyMedium;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Inter');
        expect(style.fontWeight, FontWeight.w300);
        expect(style.fontSize, 14);
      });

      test('headlineMedium uses Inter bold at 24', () {
        final style = SamayTheme.dark.textTheme.headlineMedium;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Inter');
        expect(style.fontWeight, FontWeight.bold);
        expect(style.fontSize, 24);
      });

      test('button label is bold with uppercase letter-spacing', () {
        final style = SamayTheme.dark.textTheme.labelLarge;
        expect(style, isNotNull);
        expect(style!.fontFamily, 'Inter');
        expect(style.fontWeight, FontWeight.w700);
        expect(style.fontSize, 14);
        expect(style.letterSpacing, 1.2);
      });
    });

    test('AppBar is black with no elevation', () {
      final theme = SamayTheme.dark;
      final appBarTheme = theme.appBarTheme;
      expect(appBarTheme.elevation, 0);
      expect(appBarTheme.scrolledUnderElevation, 0);
      expect(appBarTheme.backgroundColor, Colors.black);
      expect(appBarTheme.foregroundColor, Colors.white);
    });

    test('BottomNav has black background, white selected, gray unselected',
        () {
      final theme = SamayTheme.dark;
      final navTheme = theme.bottomNavigationBarTheme;
      expect(navTheme.backgroundColor, Colors.black);
      expect(navTheme.selectedItemColor, Colors.white);
      expect(navTheme.unselectedItemColor, AppColors.muted);
      expect(navTheme.type, BottomNavigationBarType.fixed);
      expect(navTheme.showUnselectedLabels, isFalse);
      expect(navTheme.showSelectedLabels, isFalse);
    });

    test('registers the SamayThemeExtension with the disco palette', () {
      final theme = SamayTheme.dark;
      final ext = theme.extension<SamayThemeExtension>();
      expect(ext, isNotNull);
      expect(ext!.glowPink, AppColors.glowPink);
      expect(ext.glowPinkBright, AppColors.glowPinkBright);
      expect(ext.glowPinkDeep, AppColors.glowPinkDeep);
      expect(ext.discoViolet, AppColors.discoViolet);
      expect(ext.discoCyan, AppColors.discoCyan);
      expect(ext.discoGold, AppColors.discoGold);
      expect(ext.discoSilver, AppColors.discoSilver);
      expect(ext.discoBronze, AppColors.discoBronze);
    });

    test('color scheme has no accent colors, only black/white/gray', () {
      final theme = SamayTheme.dark;
      final scheme = theme.colorScheme;
      final allowedColors = [
        Colors.white,
        Colors.black,
        const Color(0xFF1A1A1A),
        const Color(0xFF333333),
        const Color(0xFF666666),
      ];
      expect(allowedColors.contains(scheme.primary), isTrue);
      expect(allowedColors.contains(scheme.onPrimary), isTrue);
    });
  });

  group('SamayThemeExtension', () {
    test('copyWith overrides only the given fields', () {
      const ext = SamayThemeExtension.dark;
      final copy = ext.copyWith(glowPink: Colors.red);
      expect(copy.glowPink, Colors.red);
      expect(copy.discoGold, AppColors.discoGold);
      expect(copy.glowPinkBright, AppColors.glowPinkBright);
    });

    test('lerp interpolates colors', () {
      const ext = SamayThemeExtension.dark;
      const other = SamayThemeExtension(
        discoBlack: Colors.black,
        surface: Colors.black,
        surfaceAlt: Colors.black,
        hairline: Colors.black,
        border: Colors.black,
        muted: Colors.black,
        mutedStrong: Colors.black,
        white: Colors.black,
        glowPink: Colors.black,
        glowPinkBright: Colors.black,
        glowPinkDeep: Colors.black,
        discoViolet: Colors.black,
        discoCyan: Colors.black,
        discoGold: Colors.black,
        discoSilver: Colors.black,
        discoBronze: Colors.black,
      );
      final mid = ext.lerp(other, 0.5);
      expect(mid, isA<SamayThemeExtension>());
      expect(mid.glowPink, isNot(ext.glowPink));
    });
  });
}
