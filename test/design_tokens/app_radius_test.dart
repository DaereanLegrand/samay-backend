import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_radius.dart';

/// Contract tests for the radius tokens (DISCO-DESIGN-SYSTEM.md §4.2).
///
/// The design is SHARP: every UI component radius is `0`; the doc's
/// xs/sm/md/lg scale values exist only for table parity and are marked
/// `(unused)`. The only non-sharp geometry is `full` (avatars, live dots).
void main() {
  group('AppRadius sharp scale (doc §4.2)', () {
    test('none and radiusZero are 0 (the every-component default)', () {
      expect(AppRadius.none, 0);
      expect(AppRadius.radiusZero, AppRadius.none);
    });

    test('sharp is BorderRadius.zero (component geometry)', () {
      expect(AppRadius.sharp, BorderRadius.zero);
    });

    test('nominal scale values match the doc table (marked unused)', () {
      expect(AppRadius.xs, 2);
      expect(AppRadius.sm, 4);
      expect(AppRadius.md, 8);
      expect(AppRadius.lg, 12);
    });

    test('the only non-sharp geometry is full (circles)', () {
      expect(AppRadius.full, 999);
      expect(AppRadius.avatarCircle, AppRadius.full);
    });

    test('a sharp card/button/chip shape has zero radius', () {
      const buttonShape = RoundedRectangleBorder(borderRadius: AppRadius.sharp);
      expect(buttonShape.borderRadius, BorderRadius.zero);
    });
  });
}
