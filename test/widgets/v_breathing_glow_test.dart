import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_breathing_glow.dart';
import 'package:samay/shared/widgets/v_glow_text.dart';

/// The §3.4 glow-strong canonical alphas (mirror of
/// [AppTypography.fancyTitle] — the parity is pinned below).
const _strongAlphas = [0.9, 0.5, 0.25];

/// The canonical stack with the LUXE violet halo — the §3.4 alphas and
/// em-relative blur radii of [AppTypography.fancyTitle] with the hue swapped
/// to the violet family's vivid end ([AppColors.discoViolet]; never pink,
/// 2026-08-12).
List<Shadow> _violetCanonical(TextStyle base) {
  final halo = AppColors.discoViolet;
  return [
    for (final s in AppTypography.fancyTitle(base).shadows!)
      Shadow(
        color: halo.withValues(alpha: s.color.a),
        blurRadius: s.blurRadius,
        offset: s.offset,
      ),
  ];
}

Widget _wrap(Widget child, {bool reduced = false}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(child: child),
      ),
    ),
  );
}

Text _glowText(WidgetTester tester) => tester.widget<Text>(
  find.descendant(
    of: find.byType(VBreathingGlow),
    matching: find.text('SAMAY'),
  ),
);

void main() {
  group('VBreathingGlow', () {
    testWidgets('renders the text with the canonical glow stack on top of '
        'the given style (§6.2)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
          ),
        ),
      );

      final text = _glowText(tester);
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontSize, AppTypography.displayLarge.fontSize);
      expect(text.style?.shadows, isNotEmpty);
    });

    testWidgets('breathes by default: ticker running and the glow starts at '
        'the §6.2 α0.75 floor then reaches the full violet stack', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
          ),
        ),
      );

      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: 'the breath loop is a live animation by default (§6.2)',
      );

      final canonical = _violetCanonical(AppTypography.displayLarge);
      final atFloor = _glowText(tester).style!.shadows!;
      expect(atFloor, hasLength(canonical.length));
      for (var i = 0; i < canonical.length; i++) {
        expect(
          atFloor[i].blurRadius,
          canonical[i].blurRadius,
          reason: 'blur radii stay em-relative (§3.4)',
        );
        expect(
          atFloor[i].color.a,
          canonical[i].color.a * 0.75,
          reason: 'the first frame sits at the α0.75 legibility floor (§6.2)',
        );
      }

      await tester.pump(SamayDurations.glowBreath ~/ 2);
      final atPeak = _glowText(tester).style!.shadows!;
      for (var i = 0; i < canonical.length; i++) {
        expect(
          atPeak[i].color,
          canonical[i].color,
          reason:
              'the peak of the alternate is the full violet canonical '
              'stack — the default is violet, never pink (LUXE 2026-08-12)',
        );
      }
    });

    testWidgets('the animated stack is byte-identical to VGlowText at the '
        'peak (§3.4 parity)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Column(
            children: [
              VBreathingGlow(text: 'SAMAY', style: AppTypography.displaySmall),
              VGlowText(text: 'SAMAY', style: AppTypography.displaySmall),
            ],
          ),
        ),
      );
      await tester.pump(SamayDurations.glowBreath ~/ 2);

      final staticGlow = tester
          .widget<Text>(
            find.descendant(
              of: find.byType(VGlowText),
              matching: find.text('SAMAY'),
            ),
          )
          .style!
          .shadows;
      expect(staticGlow, isNotNull);
      expect(
        _glowText(tester).style?.shadows,
        staticGlow,
        reason:
            'at α1.0 the breath renders the identical glow stack '
            '(U-06 parity contract)',
      );
    });

    testWidgets('gradient: rose peaks byte-identical to '
        'AppTypography.fancyTitle (parity)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
            gradient: AppGradients.rose,
          ),
        ),
      );
      await tester.pump(SamayDurations.glowBreath ~/ 2);
      final expected = AppTypography.fancyTitle(
        AppTypography.displayLarge,
      ).shadows!;
      expect(_glowText(tester).style?.shadows, expected);
    });

    testWidgets('soft: true applies the 2-layer glow-soft stack (§3.4)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.headlineLarge,
            soft: true,
          ),
        ),
      );

      final shadows = _glowText(tester).style!.shadows!;
      expect(shadows, hasLength(2));
      expect(shadows[0].color.a, closeTo(0.6 * 0.75, 0.0001));
      expect(shadows[1].color.a, closeTo(0.25 * 0.75, 0.0001));
    });

    testWidgets('gradient param drives the halo family (cyan)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displaySmall,
            gradient: AppGradients.cyan,
          ),
        ),
      );
      await tester.pump(SamayDurations.glowBreath ~/ 2);
      final shadows = _glowText(tester).style!.shadows!;
      expect(
        shadows[0].color,
        AppGradients.cyan.colors.last.withValues(alpha: 0.9),
      );
      expect(
        shadows[1].color,
        AppGradients.cyan.colors.last.withValues(alpha: 0.5),
      );
      expect(
        shadows[2].color,
        AppGradients.cyan.colors.last.withValues(alpha: 0.25),
      );
    });

    testWidgets('disableAnimations → static full-α glow and no ticker (§6.2/'
        '§7.5)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
          ),
          reduced: true,
        ),
      );

      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'reduced motion → no breath ticker',
      );
      final canonical = _violetCanonical(AppTypography.displayLarge);
      final staticShadows = _glowText(tester).style!.shadows!;
      for (var i = 0; i < canonical.length; i++) {
        expect(
          staticShadows[i].color,
          canonical[i].color,
          reason: 'reduced motion → shadows fixed at α1.0 (§6.2)',
        );
      }

      await tester.pump(const Duration(seconds: 4));
      expect(tester.binding.transientCallbackCount, 0);
      expect(_glowText(tester).style!.shadows, isNotEmpty);
    });

    testWidgets('the breath restarts when animations are re-enabled', (
      tester,
    ) async {
      Widget glow({required bool reduced}) {
        return _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
          ),
          reduced: reduced,
        );
      }

      await tester.pumpWidget(glow(reduced: true));
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(glow(reduced: false));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('holds a static pause between cycles so pumpAndSettle tests '
        'land (§6.2 cycle note)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VBreathingGlow(
            text: 'SAMAY',
            style: AppTypography.displayLarge,
          ),
        ),
      );

      // A pumpAndSettle lands during the static pause between cycles — the
      // whole point of the idle-safe engine (every brand screen with the
      // breathing must settle in widget tests).
      await tester.pumpAndSettle();
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason:
            'the controller settles at the low point after one '
            'alternate (pumpAndSettle-compatible)',
      );
      expect(
        _glowText(tester).style!.shadows!.first.color.a,
        closeTo(_strongAlphas.first * 0.75, 0.0001),
        reason: 'and the hold sits at the α0.75 floor',
      );

      // The next cycle begins only after the rest gap.
      await tester.pump(SamayDurations.motionCycleRest);
      expect(
        tester.binding.transientCallbackCount,
        greaterThan(0),
        reason: 'the periodic restart kicks off the next cycle',
      );
    });

    testWidgets('is const-constructible and defaults to the violet family '
        '(no pink mains)', (tester) async {
      const glow = VBreathingGlow(
        text: 'SAMAY',
        style: AppTypography.displayLarge,
      );
      expect(glow, isA<VBreathingGlow>());
      expect(glow.gradient, isNull);
      expect(glow.color, isNull);
      const violet = VBreathingGlow(
        text: 'SAMAY',
        style: AppTypography.displayLarge,
        gradient: AppGradients.violet,
      );
      expect(violet.gradient, AppGradients.violet);
    });
  });
}
