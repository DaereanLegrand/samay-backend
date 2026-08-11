import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_status_dot.dart';

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

FadeTransition _dotFade(WidgetTester tester) {
  return tester.widget<FadeTransition>(
    find.descendant(
      of: find.byType(VStatusDot),
      matching: find.byType(FadeTransition),
    ),
  );
}

void main() {
  group('VStatusDot', () {
    testWidgets('renders the §5.5 8px statusOnline (discoCyan) circle',
        (tester) async {
      await tester.pumpWidget(_wrap(const VStatusDot()));

      final icon = tester.widget<Icon>(find.byIcon(Icons.circle));
      expect(icon.color, AppColors.statusOnline,
          reason: 'the presence dot stays on the statusOnline alias (§5.5)');
      expect(icon.size, 8, reason: 'online dot = 8px circle (§5.5)');
    });

    testWidgets('pulses the α 0.6→1.0 by default (§6.3)', (tester) async {
      await tester.pumpWidget(_wrap(const VStatusDot()));

      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the pulse is a live animation by default (§6.3)');
      expect(_dotFade(tester).opacity.value, closeTo(0.6, 0.0001),
          reason: 'the cycle starts at the α0.6 low point');

      await tester.pump(SamayDurations.liveDotPulse);
      expect(_dotFade(tester).opacity.value, closeTo(1.0, 0.0001),
          reason: 'the 1.5s ramp peaks at full α (§6.3)');

      // A pumpAndSettle lands during the static pause between pulses — the
      // whole point of the idle-safe cycle (screens with the dot settle).
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the pulse settles between cycles (pumpAndSettle-safe)');
      expect(_dotFade(tester).opacity.value, closeTo(0.6, 0.0001),
          reason: 'the hold sits at the α0.6 low point');

      await tester.pump(SamayDurations.motionCycleRest);
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the periodic restart kicks off the next pulse');
    });

    testWidgets('disableAnimations → static dot at full α, no ticker (§6.3/'
        '§7.5)', (tester) async {
      await tester.pumpWidget(_wrap(const VStatusDot(), reduced: true));

      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no pulse ticker');
      expect(_dotFade(tester).opacity.value, 1.0,
          reason: 'reduced motion → static full-α dot');
      await tester.pump(const Duration(seconds: 4));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('the pulse restarts when animations are re-enabled',
        (tester) async {
      Widget dot({required bool reduced}) => _wrap(
            const VStatusDot(),
            reduced: reduced,
          );

      await tester.pumpWidget(dot(reduced: true));
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(dot(reduced: false));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('accepts a custom size and color', (tester) async {
      await tester.pumpWidget(
        _wrap(const VStatusDot(size: 12, color: AppColors.glowPink)),
      );

      final icon = tester.widget<Icon>(find.byIcon(Icons.circle));
      expect(icon.size, 12);
      expect(icon.color, AppColors.glowPink);
    });
  });
}
