import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_glow_pulse.dart';

/// LUXE v2 motion tests (ORCHESTRATION-LUXE.md — owned by XL-04): the
/// pulsing glow wrapper follows the [VBreathingGlow] idle-safe engine
/// contract — pulse by default, static under reduce-motion, and a static
/// settle between cycles so every `pumpAndSettle`-based test lands.
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

BoxDecoration _boxDecoration(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(VGlowPulse),
      matching: find.byType(DecoratedBox),
    ),
  );
  return box.decoration as BoxDecoration;
}

void main() {
  group('VGlowPulse', () {
    testWidgets('renders the child inside a shadowed box at the α0.35 floor '
        '(§: slow pulsing glow)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowPulse(
            gradient: AppGradients.rose,
            child: Text('glow'),
          ),
        ),
      );

      expect(find.text('glow'), findsOneWidget);
      final shadows = _boxDecoration(tester).boxShadow!;
      expect(shadows, isNotEmpty);
      expect(
        shadows.first.blurRadius,
        AppGradients.glowShadows(AppGradients.rose).first.blurRadius,
        reason: 'the default blur (48) is forwarded to glowShadows',
      );
      expect(
        shadows.first.color.a,
        AppGradients.glowShadows(AppGradients.rose, alpha: 0.35)
            .first
            .color
            .a,
        reason: 'the first frame sits at the α0.35 pulse floor',
      );
    });

    testWidgets('pulses the shadow alpha from alphaMin up to alphaMax '
        '(easeInOut alternate)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowPulse(
            gradient: AppGradients.violet,
            child: Text('glow'),
          ),
        ),
      );

      final atRest = _boxDecoration(tester).boxShadow!.first.color.a;
      expect(
        atRest,
        AppGradients.glowShadows(AppGradients.violet, alpha: 0.35)
            .first
            .color
            .a,
      );

      await tester.pump(SamayDurations.glowPulse ~/ 4);
      final midCycle = _boxDecoration(tester).boxShadow!.first.color.a;
      expect(midCycle, greaterThan(atRest),
          reason: 'the up leg raises the halo alpha');

      await tester.pump(SamayDurations.glowPulse ~/ 4);
      final atPeak = _boxDecoration(tester).boxShadow!.first.color.a;
      expect(
        atPeak,
        AppGradients.glowShadows(AppGradients.violet, alpha: 0.7)
            .first
            .color
            .a,
        reason: 'the peak of the alternate is the α0.7 ceiling',
      );

      // The reverse starts on the frame after the up leg completes (the
      // TickerFuture fires in the post-frame microtask), so its clock begins
      // at the first reverse tick — pump two legs to reach the floor.
      await tester.pump(SamayDurations.glowPulse ~/ 2);
      await tester.pump(SamayDurations.glowPulse ~/ 2);
      expect(
        _boxDecoration(tester).boxShadow!.first.color.a,
        atRest,
        reason: 'the down leg returns to the α0.35 floor',
      );
    });

    testWidgets('custom alphaMin/alphaMax/duration drive the pulse range',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowPulse(
            gradient: AppGradients.gold,
            alphaMin: 0.2,
            alphaMax: 0.5,
            duration: Duration(milliseconds: 2000),
            child: Text('glow'),
          ),
        ),
      );

      final atRest = _boxDecoration(tester).boxShadow!.first.color.a;
      expect(
        atRest,
        AppGradients.glowShadows(AppGradients.gold, alpha: 0.2)
            .first
            .color
            .a,
      );
      await tester.pump(const Duration(milliseconds: 1000));
      expect(
        _boxDecoration(tester).boxShadow!.first.color.a,
        AppGradients.glowShadows(AppGradients.gold, alpha: 0.5)
            .first
            .color
            .a,
        reason: 'one full direction of the custom duration reaches alphaMax',
      );
    });

    testWidgets('disableAnimations → static α0.55 glow and no ticker',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowPulse(
            gradient: AppGradients.rose,
            child: Text('glow'),
          ),
          reduced: true,
        ),
      );

      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no pulse ticker');
      final staticShadows = _boxDecoration(tester).boxShadow!;
      final expected =
          AppGradients.glowShadows(AppGradients.rose, alpha: 0.55);
      for (var i = 0; i < staticShadows.length; i++) {
        expect(staticShadows[i].color.a, expected[i].color.a,
            reason: 'reduced motion → shadows fixed at α0.55');
      }

      await tester.pump(const Duration(seconds: 4));
      expect(tester.binding.transientCallbackCount, 0);
      expect(_boxDecoration(tester).boxShadow, isNotEmpty);
    });

    testWidgets('the pulse restarts when animations are re-enabled',
        (tester) async {
      Widget glow({required bool reduced}) {
        return _wrap(
          const VGlowPulse(
            gradient: AppGradients.cyan,
            child: Text('glow'),
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
        'land (idle-safe engine)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VGlowPulse(
            gradient: AppGradients.rose,
            child: Text('glow'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the controller settles after one alternate');
      expect(
        _boxDecoration(tester).boxShadow!.first.color.a,
        AppGradients.glowShadows(AppGradients.rose, alpha: 0.35)
            .first
            .color
            .a,
        reason: 'and the hold sits at the α0.35 floor',
      );

      await tester.pump(SamayDurations.motionCycleRest);
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the periodic restart kicks off the next pulse');
    });

    testWidgets('is const-constructible with the spec defaults',
        (tester) async {
      const pulse = VGlowPulse(
        gradient: AppGradients.rose,
        child: SizedBox.shrink(),
      );
      expect(pulse, isA<VGlowPulse>());
      expect(pulse.blur, 48);
      expect(pulse.alphaMin, 0.35);
      expect(pulse.alphaMax, 0.7);
      expect(pulse.duration, SamayDurations.glowPulse);
    });
  });
}
