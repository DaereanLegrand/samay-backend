import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/shared/widgets/v_display_text.dart';

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

Text _displayText(WidgetTester tester) => tester.widget<Text>(
  find.descendant(
    of: find.byType(VDisplayText),
    matching: find.byType(Text),
  ),
);

/// LUXE directive (2026-08-12): "glowing pulsation outside letters must be
/// deleted" — NO DecoratedBox with a boxShadow stack may exist inside
/// VDisplayText.
BoxDecoration? _outsideGlow(WidgetTester tester) {
  final glow = find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false) &&
        find
            .descendant(
              of: find.byType(VDisplayText),
              matching: find.byWidgetPredicate((w2) => identical(w2, w)),
            )
            .evaluate()
            .isNotEmpty,
  );
  if (glow.evaluate().isEmpty) return null;
  return tester.widget<DecoratedBox>(glow).decoration as BoxDecoration;
}

void main() {
  group('VDisplayText', () {
    testWidgets('renders the text UPPERCASE — the MAYUS rule (directive #6)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', gradient: AppGradients.violet),
        ),
      );
      expect(find.text('CREA TU CUENTA'), findsOneWidget);
      expect(find.text('crea tu cuenta'), findsNothing);
    });

    testWidgets('display voice: Playfair italic bold at the given size',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', size: 40),
        ),
      );
      final style = _displayText(tester).style!;
      expect(style.fontFamily, AppTypography.playfair);
      expect(style.fontSize, AppTypography.displayMedium.fontSize);
      expect(style.fontWeight, FontWeight.w700);
      expect(style.fontStyle, FontStyle.italic);
    });

    testWidgets('wraps the glyphs in a ShaderMask (gradient fill via '
        'AppGradients.textShader)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', gradient: AppGradients.cyan),
        ),
      );
      final mask = tester.widget<ShaderMask>(find.byType(ShaderMask).first);
      expect(mask.blendMode, BlendMode.srcIn);
      expect(mask.shaderCallback, isNotNull);
    });

    testWidgets('gradient null → white glyphs', (tester) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta')),
      );
      expect(_displayText(tester).style?.color, AppColors.white);
      expect(find.byType(ShaderMask), findsWidgets);
    });

    testWidgets('NO external glow — the halo is deleted (user directive '
        '2026-08-12)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', gradient: AppGradients.violet),
        ),
      );
      expect(_outsideGlow(tester), isNull,
          reason: 'no boxShadow may sit behind the glyphs');
    });

    testWidgets('reduce-motion → no shimmer sweep, no tickers (§6.2/§7.5)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', gradient: AppGradients.violet),
          reduced: true,
        ),
      );
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no shimmer ticker');

      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('the once-only shimmer completes and stops (no pending '
        'frames after settle)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(text: 'crea tu cuenta', gradient: AppGradients.violet),
        ),
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the sweep is live on first build');

      await tester.pump(VDisplayText.shimmerDuration);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the sweep completes and stops — no timer leftovers');
    });
  });
}
