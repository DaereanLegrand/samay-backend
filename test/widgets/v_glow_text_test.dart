import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/shared/widgets/v_glow_text.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('VGlowText', () {
    testWidgets('renders the given text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(text: 'SAMAY', style: AppTypography.displaySmall),
        ),
      );
      expect(find.text('SAMAY'), findsOneWidget);
    });

    testWidgets('strong default applies the canonical 3-layer glow stack '
        '(§3.4)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(text: 'SAMAY', style: AppTypography.displaySmall),
        ),
      );
      final text = tester.widget<Text>(find.text('SAMAY'));
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontSize, 32);
      final shadows = text.style!.shadows!;
      expect(shadows, hasLength(3));
      expect(shadows[0].color, AppColors.glowPink.withValues(alpha: 0.9));
      expect(shadows[0].blurRadius, closeTo(32 * 0.35, 0.001));
      expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.5));
      expect(shadows[1].blurRadius, closeTo(32 * 0.7, 0.001));
      expect(shadows[2].color, AppColors.glowPink.withValues(alpha: 0.25));
      expect(shadows[2].blurRadius, closeTo(32 * 1.0, 0.001));
    });

    testWidgets('soft applies the 2-layer glow stack (§3.4)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(
            text: 'Próximamente',
            style: AppTypography.displaySmall,
            soft: true,
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Pr\u00f3ximamente'));
      final shadows = text.style!.shadows!;
      expect(shadows, hasLength(2));
      expect(shadows[0].color, AppColors.glowPink.withValues(alpha: 0.6));
      expect(shadows[0].blurRadius, closeTo(32 * 0.3, 0.001));
      expect(shadows[1].color, AppColors.glowPink.withValues(alpha: 0.25));
      expect(shadows[1].blurRadius, closeTo(32 * 0.6, 0.001));
    });

    testWidgets('strong output is identical to AppTypography.fancyTitle '
        '(parity)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(text: 'SAMAY', style: AppTypography.displaySmall),
        ),
      );
      final text = tester.widget<Text>(find.text('SAMAY'));
      final expected = AppTypography.fancyTitle(AppTypography.displaySmall);
      expect(text.style?.shadows, expected.shadows);
    });

    testWidgets('soft output is identical to AppTypography.fancyTitle '
        '(parity)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(
            text: 'Próximamente',
            style: AppTypography.headlineLarge,
            soft: true,
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Pr\u00f3ximamente'));
      final expected = AppTypography.fancyTitle(
        AppTypography.headlineLarge,
        soft: true,
      );
      expect(text.style?.shadows, expected.shadows);
    });

    testWidgets('color param tints the halo', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(
            text: 'LIVE',
            style: AppTypography.displaySmall,
            color: AppColors.discoCyan,
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('LIVE'));
      final shadows = text.style!.shadows!;
      expect(shadows, hasLength(3));
      expect(shadows[0].color, AppColors.discoCyan.withValues(alpha: 0.9));
      expect(shadows[1].color, AppColors.discoCyan.withValues(alpha: 0.5));
      expect(shadows[2].color, AppColors.discoCyan.withValues(alpha: 0.25));
    });

    testWidgets('blur radii scale with the style fontSize (em-relative)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowText(text: 'HEADER', style: AppTypography.displayLarge),
        ),
      );
      final text = tester.widget<Text>(find.text('HEADER'));
      final shadows = text.style!.shadows!;
      expect(text.style?.fontSize, 64);
      expect(shadows[0].blurRadius, closeTo(64 * 0.35, 0.001));
      expect(shadows[1].blurRadius, closeTo(64 * 0.7, 0.001));
      expect(shadows[2].blurRadius, closeTo(64 * 1.0, 0.001));
    });

    testWidgets('is const-constructible', (tester) async {
      const glow = VGlowText(text: 'SAMAY', style: AppTypography.displaySmall);
      expect(glow, isA<VGlowText>());
    });
  });
}
