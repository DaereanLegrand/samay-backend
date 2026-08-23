import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_thinking_dots.dart';

/// LUXE v2 AI-thinking indicator tests (the LUXE restyle pass (historical) — owned by
/// XL-04): 3 staggered dots, α0.4↔1.0 easeInOut, reduce-motion → static
/// full alpha, on the [VBreathingGlow] idle-safe engine.
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

List<BoxDecoration> _dots(WidgetTester tester) {
  return tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(VThinkingDots),
          matching: find.byType(DecoratedBox),
        ),
      )
      .map((box) => box.decoration as BoxDecoration)
      .toList();
}

void main() {
  group('VThinkingDots', () {
    testWidgets('renders 3 circular dots in the given color', (tester) async {
      await tester.pumpWidget(_wrap(const VThinkingDots()));

      final dots = _dots(tester);
      expect(dots, hasLength(3));
      for (final dot in dots) {
        expect(dot.shape, BoxShape.circle);
        expect(
          dot.color!.withValues(alpha: 1.0),
          AppColors.mutedStrong,
          reason: 'the default fill is the muted-strong neutral',
        );
      }
    });

    testWidgets('custom color and size apply to every dot', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VThinkingDots(color: AppColors.discoCyan, size: 8),
        ),
      );

      final dots = _dots(tester);
      expect(dots, hasLength(3));
      for (final dot in dots) {
        expect(dot.color!.withValues(alpha: 1.0), AppColors.discoCyan);
      }
      final row = tester.widget<Row>(
        find.descendant(
          of: find.byType(VThinkingDots),
          matching: find.byType(Row),
        ),
      );
      final dotBoxes = row.children
          .whereType<SizedBox>()
          .where((box) => box.height != null)
          .toList();
      expect(dotBoxes, hasLength(3));
      for (final box in dotBoxes) {
        expect(box.width, 8);
        expect(box.height, 8);
      }
    });

    testWidgets('staggered pulse: dot alphas differ mid-cycle', (tester) async {
      await tester.pumpWidget(_wrap(const VThinkingDots()));

      await tester.pump(SamayDurations.thinkingDot ~/ 4);
      final dots = _dots(tester);
      expect(dots[0].color!.a, isNot(closeTo(dots[1].color!.a, 0.0001)),
          reason: 'the wave is staggered — dots are a third of a period '
              'apart');
    });

    testWidgets('disableAnimations → static full-alpha dots and no ticker',
        (tester) async {
      await tester.pumpWidget(_wrap(const VThinkingDots(), reduced: true));

      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no pulse ticker');
      for (final dot in _dots(tester)) {
        expect(dot.color!.a, 1.0,
            reason: 'reduced motion → dots fixed at full alpha');
      }

      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.transientCallbackCount, 0);
      for (final dot in _dots(tester)) {
        expect(dot.color!.a, 1.0);
      }
    });

    testWidgets('the pulse restarts when animations are re-enabled',
        (tester) async {
      Widget dots({required bool reduced}) {
        return _wrap(const VThinkingDots(), reduced: reduced);
      }

      await tester.pumpWidget(dots(reduced: true));
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(dots(reduced: false));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('holds a static pause between cycles so pumpAndSettle tests '
        'land (idle-safe engine)', (tester) async {
      await tester.pumpWidget(_wrap(const VThinkingDots()));

      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the controller settles after one alternate');
      expect(_dots(tester), hasLength(3));

      await tester.pump(SamayDurations.motionCycleRest);
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the periodic restart kicks off the next pulse');
    });

    testWidgets('is const-constructible with the spec defaults',
        (tester) async {
      const dots = VThinkingDots();
      expect(dots, isA<VThinkingDots>());
      expect(dots.color, AppColors.mutedStrong);
      expect(dots.size, 6);
      expect(dots.spacing, 8);
    });
  });
}
