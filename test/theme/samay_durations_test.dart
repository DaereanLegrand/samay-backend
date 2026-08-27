import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/samay_durations.dart';

/// Contract tests for the motion-duration tokens
/// (DESIGN.md §4.5 — the source of truth, owned by U-18).
///
/// Screens and shared widgets must take their durations from here; never
/// hardcode ms values in features (U-06's `_shimmerSweep` local const was
/// the last one — promoted by U-18). The glow/sweep LUXE tokens were
/// deleted with the monochrome refactor (2026-08-26); the ambient tokens
/// that remain are pinned here.
void main() {
  group('SamayDurations (doc §4.5)', () {
    test('motion-scale tokens match the documented values', () {
      expect(SamayDurations.fast, const Duration(milliseconds: 150));
      expect(SamayDurations.standard, const Duration(milliseconds: 250));
      expect(SamayDurations.slow, const Duration(milliseconds: 500));
    });

    test('ambient-motion tokens match the §4.5 table', () {
      expect(SamayDurations.shimmer, const Duration(milliseconds: 1200));
      expect(SamayDurations.liveDotPulse, const Duration(milliseconds: 1500));
      expect(SamayDurations.motionCycleRest, const Duration(milliseconds: 300));
      expect(SamayDurations.auroraDrift, const Duration(milliseconds: 10000));
      expect(SamayDurations.thinkingDot, const Duration(milliseconds: 900));
    });

    test('defaultCurve is easeOutCubic (§6.1)', () {
      expect(SamayDurations.defaultCurve, Curves.easeOutCubic);
    });

    test('tokens are const-constructible (compile-time canonical)', () {
      const fast = SamayDurations.fast;
      const shimmer = SamayDurations.shimmer;
      const liveDotPulse = SamayDurations.liveDotPulse;
      const auroraDrift = SamayDurations.auroraDrift;
      const thinkingDot = SamayDurations.thinkingDot;
      expect(fast, const Duration(milliseconds: 150));
      expect(shimmer, const Duration(milliseconds: 1200));
      expect(liveDotPulse, const Duration(milliseconds: 1500));
      expect(auroraDrift, const Duration(milliseconds: 10000));
      expect(thinkingDot, const Duration(milliseconds: 900));
    });

    test('the U-18 engine settle is short but non-zero (the pumpAndSettle '
        'compatibility tax)', () {
      expect(SamayDurations.motionCycleRest, greaterThan(Duration.zero));
      expect(
        SamayDurations.motionCycleRest,
        lessThan(SamayDurations.liveDotPulse),
      );
    });
  });
}
