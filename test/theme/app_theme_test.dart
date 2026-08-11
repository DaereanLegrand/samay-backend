import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_radius.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
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

    group('typography table completeness (U-02 → U-27 consolidation)', () {
      test('all 14 composed textTheme roles match their AppTypography tokens '
          'field-for-field', () {
        final theme = SamayTheme.dark.textTheme;
        final tokens = AppTypography.textTheme;
        // (name, theme role, token role) — every §3.3 role that
        // AppTypography.textTheme composes must surface in SamayTheme.dark
        // with the token's exact values. `ThemeData` merges Material
        // defaults under the tokens, so each field the token sets wins.
        final roles = <(String, TextStyle, TextStyle)>[
          ('displayLarge', theme.displayLarge!, tokens.displayLarge!),
          ('displayMedium', theme.displayMedium!, tokens.displayMedium!),
          ('displaySmall', theme.displaySmall!, tokens.displaySmall!),
          ('headlineLarge', theme.headlineLarge!, tokens.headlineLarge!),
          ('headlineMedium', theme.headlineMedium!, tokens.headlineMedium!),
          ('headlineSmall', theme.headlineSmall!, tokens.headlineSmall!),
          ('titleLarge', theme.titleLarge!, tokens.titleLarge!),
          ('titleMedium', theme.titleMedium!, tokens.titleMedium!),
          ('bodyLarge', theme.bodyLarge!, tokens.bodyLarge!),
          ('bodyMedium', theme.bodyMedium!, tokens.bodyMedium!),
          ('bodySmall', theme.bodySmall!, tokens.bodySmall!),
          ('labelLarge', theme.labelLarge!, tokens.labelLarge!),
          ('labelMedium', theme.labelMedium!, tokens.labelMedium!),
          ('labelSmall', theme.labelSmall!, tokens.labelSmall!),
        ];
        expect(roles, hasLength(14));
        for (final (name, themed, token) in roles) {
          expect(themed.fontFamily, token.fontFamily, reason: '$name family');
          expect(themed.fontSize, token.fontSize, reason: '$name size');
          expect(themed.fontWeight, token.fontWeight, reason: '$name weight');
          expect(themed.fontStyle, token.fontStyle, reason: '$name style');
          expect(
            themed.letterSpacing,
            token.letterSpacing,
            reason: '$name letter-spacing',
          );
          expect(themed.height, token.height, reason: '$name height');
          expect(themed.shadows, token.shadows, reason: '$name glow');
        }
      });

      test('display roles are Playfair Display italic (the fancy voice)', () {
        final theme = SamayTheme.dark.textTheme;
        for (final style in [
          theme.displayLarge!,
          theme.displayMedium!,
          theme.displaySmall!,
          theme.headlineLarge!,
        ]) {
          expect(style.fontFamily, AppTypography.playfair);
          expect(style.fontStyle, FontStyle.italic);
        }
      });

      test('otpInputText is a token-only role — deliberately NOT in '
          'textTheme (the OTP field styles itself)', () {
        // otpInputText is a §3.3 token, not a TextTheme role — no composed
        // role may collide with its metrics.
        expect(AppTypography.otpInputText.fontSize, 30);
        expect(
          SamayTheme.dark.textTheme.labelLarge?.fontSize,
          isNot(AppTypography.otpInputText.fontSize),
          reason: 'no §3.3 role may collide with the OTP field metrics',
        );
      });

      test('non-table roles keep Material defaults (no regressions)', () {
        final theme = SamayTheme.dark;
        // titleSmall is a TextTheme role outside the §3.3 table — it must
        // survive the token takeover with the default Inter family.
        expect(theme.textTheme.titleSmall, isNotNull);
        expect(theme.textTheme.titleSmall!.fontFamily, 'Inter');
        expect(theme.textTheme.bodySmall, isNotNull);
        expect(theme.textTheme.labelSmall, isNotNull);
      });
    });

    group('glow title treatment', () {
      test('displayLarge carries the glow-strong shadow stack', () {
        final style = SamayTheme.dark.textTheme.displayLarge!;
        final shadows = style.shadows;
        expect(shadows, isNotNull);
        expect(shadows, isNotEmpty);
        expect(shadows!.length, 3);
        expect(shadows.first.color, AppColors.glowPink.withValues(alpha: 0.9));
        expect(shadows.first.blurRadius, closeTo(64 * 0.35, 0.001));
        expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.5));
        expect(shadows[1].blurRadius, closeTo(64 * 0.7, 0.001));
        expect(shadows[2].color, AppColors.glowPink.withValues(alpha: 0.25));
        expect(shadows[2].blurRadius, closeTo(64 * 1.0, 0.001));
      });

      test('headlineLarge carries the glow-soft stack (2 layers)', () {
        final style = SamayTheme.dark.textTheme.headlineLarge!;
        final shadows = style.shadows;
        expect(shadows, isNotNull);
        expect(shadows!.length, 2);
        expect(shadows.first.color, AppColors.glowPink.withValues(alpha: 0.6));
        expect(shadows.first.blurRadius, closeTo(28 * 0.3, 0.001));
        expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.25));
        expect(shadows[1].blurRadius, closeTo(28 * 0.6, 0.001));
      });

      test('body styles carry no glow', () {
        final theme = SamayTheme.dark;
        expect(theme.textTheme.bodyLarge?.shadows, isNull);
        expect(theme.textTheme.bodyMedium?.shadows, isNull);
        expect(theme.textTheme.headlineMedium?.shadows, isNull);
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

    test('BottomNav has black background, white selected, gray unselected', () {
      final theme = SamayTheme.dark;
      final navTheme = theme.bottomNavigationBarTheme;
      expect(navTheme.backgroundColor, Colors.black);
      expect(navTheme.selectedItemColor, Colors.white);
      expect(navTheme.unselectedItemColor, AppColors.muted);
      expect(navTheme.type, BottomNavigationBarType.fixed);
      expect(navTheme.showUnselectedLabels, isFalse);
      expect(navTheme.showSelectedLabels, isFalse);
    });

    group('component themes (U-04 — DISCO-DESIGN-SYSTEM §2/§4.2/§5)', () {
      test('snackBar: surface fill, white content, sharp', () {
        final theme = SamayTheme.dark;
        expect(theme.snackBarTheme.backgroundColor, AppColors.surface);
        expect(theme.snackBarTheme.contentTextStyle?.color, AppColors.white);
        final shape = theme.snackBarTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('dialog: black surface, sharp corners', () {
        final theme = SamayTheme.dark;
        expect(theme.dialogTheme.backgroundColor, AppColors.discoBlack);
        expect(theme.dialogTheme.surfaceTintColor, Colors.transparent);
        final shape = theme.dialogTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('input: white underline 1px/2px, §5.2 label mutedStrong, hint '
          'muted, error glowPink', () {
        final theme = SamayTheme.dark;
        expect(
          theme.inputDecorationTheme.labelStyle?.color,
          AppColors.mutedStrong,
        );
        expect(theme.inputDecorationTheme.hintStyle?.color, AppColors.muted);
        final enabled =
            theme.inputDecorationTheme.enabledBorder! as UnderlineInputBorder;
        expect(enabled.borderSide.color, AppColors.white);
        expect(enabled.borderSide.width, 1);
        final focused =
            theme.inputDecorationTheme.focusedBorder! as UnderlineInputBorder;
        expect(focused.borderSide.color, AppColors.white);
        expect(focused.borderSide.width, 2);
        expect(theme.inputDecorationTheme.errorStyle?.color, AppColors.error);
      });

      test('card: surface fill, hairline border, sharp (§5.3)', () {
        final theme = SamayTheme.dark;
        expect(theme.cardTheme.color, AppColors.surface);
        expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
        final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
        expect(shape.side.color, AppColors.hairline);
      });

      test('chip: transparent, white fill + black label on select (§5.4)', () {
        final theme = SamayTheme.dark;
        expect(theme.chipTheme.backgroundColor, Colors.transparent);
        expect(theme.chipTheme.selectedColor, AppColors.white);
        expect(theme.chipTheme.labelStyle?.color, AppColors.white);
        expect(
          theme.chipTheme.secondaryLabelStyle?.color,
          AppColors.discoBlack,
        );
        expect(theme.chipTheme.side?.color, AppColors.white);
        expect(theme.chipTheme.showCheckmark, isFalse);
        final shape = theme.chipTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('divider: hairline color (§2.1)', () {
        expect(SamayTheme.dark.dividerTheme.color, AppColors.hairline);
      });

      test('textButton: white label, muted disabled, α0.1 overlay, sharp '
          '(§5.1)', () {
        final theme = SamayTheme.dark;
        final style = theme.textButtonTheme.style!;
        expect(style.foregroundColor!.resolve({}), AppColors.white);
        expect(
          style.foregroundColor!.resolve({WidgetState.disabled}),
          AppColors.muted,
        );
        final pressedOverlay = style.overlayColor!.resolve({
          WidgetState.pressed,
        });
        expect(pressedOverlay, isNotNull);
        expect(
          pressedOverlay!.a,
          closeTo(0.1, 0.01),
          reason: '§5.1 press feedback = α0.1 overlay on the base color',
        );
        final shape = style.shape!.resolve({})! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
        expect(
          style.textStyle?.resolve({}),
          AppTypography.labelLarge,
          reason: '§3.3 labelLarge is the button voice',
        );
      });

      test(
        'checkbox: transparent, white fill + black check on select, sharp',
        () {
          final theme = SamayTheme.dark;
          expect(
            theme.checkboxTheme.fillColor!.resolve({}),
            isNull,
            reason: 'unselected keeps the border-only look (no fill)',
          );
          expect(
            theme.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
            AppColors.white,
          );
          expect(
            theme.checkboxTheme.checkColor!.resolve({}),
            AppColors.discoBlack,
          );
          final shape = theme.checkboxTheme.shape! as RoundedRectangleBorder;
          expect(shape.borderRadius, AppRadius.sharp);
        },
      );

      test('tabBar: white indicator and label', () {
        final theme = SamayTheme.dark;
        expect(theme.tabBarTheme.indicatorColor, AppColors.white);
        expect(theme.tabBarTheme.labelColor, AppColors.white);
      });

      test('popupMenu: black surface, white text/icons, sharp', () {
        final theme = SamayTheme.dark;
        expect(theme.popupMenuTheme.color, AppColors.discoBlack);
        expect(theme.popupMenuTheme.surfaceTintColor, Colors.transparent);
        expect(theme.popupMenuTheme.textStyle?.color, AppColors.white);
        expect(theme.popupMenuTheme.iconColor, AppColors.white);
        final shape = theme.popupMenuTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('datePicker: black surface + header, white header text, sharp', () {
        final theme = SamayTheme.dark;
        expect(theme.datePickerTheme.backgroundColor, AppColors.discoBlack);
        expect(theme.datePickerTheme.surfaceTintColor, Colors.transparent);
        expect(
          theme.datePickerTheme.headerBackgroundColor,
          AppColors.discoBlack,
        );
        expect(theme.datePickerTheme.headerForegroundColor, AppColors.white);
        final shape = theme.datePickerTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('progressIndicator: white per §5.8 (pink is brand-moment only)', () {
        expect(SamayTheme.dark.progressIndicatorTheme.color, AppColors.white);
      });

      test('segmentedButton: §5.4 chip treatment promoted from the settings '
          'screen (U-09 → U-27)', () {
        final theme = SamayTheme.dark;
        final style = theme.segmentedButtonTheme.style!;
        expect(
          style.backgroundColor!.resolve({WidgetState.selected}),
          AppColors.white,
        );
        expect(
          style.backgroundColor!.resolve(const {}),
          Colors.transparent,
        );
        expect(
          style.foregroundColor!.resolve({WidgetState.selected}),
          AppColors.discoBlack,
        );
        expect(style.foregroundColor!.resolve(const {}), AppColors.white);
        final side = style.side!.resolve(const {});
        expect(side!.color, AppColors.white);
        expect(side.width, 1);
        final shape = style.shape!.resolve(const {})! as RoundedRectangleBorder;
        expect(shape.borderRadius, AppRadius.sharp);
      });

      test('tooltip: dark raised surface, white text, sharp', () {
        final theme = SamayTheme.dark;
        final decoration = theme.tooltipTheme.decoration! as BoxDecoration;
        expect(decoration.color, AppColors.surfaceAlt);
        expect(theme.tooltipTheme.textStyle?.color, AppColors.white);
        expect(decoration.borderRadius, AppRadius.sharp);
      });
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

    test('SamayTheme.dark is value-equal and hash-stable (ThemeData '
        'contract — U-04)', () {
      // U-04's MISTAKE: a `WidgetStateProperty.resolveWith` closure broke
      // `SamayTheme.dark == SamayTheme.dark` (identity-hashed). The theme
      // persistence tests pin `app.theme == SamayTheme.dark` indirectly;
      // this is the direct pin the ledger promised. Any future
      // `resolveWith` in a component theme fails red here.
      final a = SamayTheme.dark;
      final b = SamayTheme.dark;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == SamayTheme.dark, isTrue);
      expect(a.hashCode, SamayTheme.dark.hashCode);
    });
  });
}
