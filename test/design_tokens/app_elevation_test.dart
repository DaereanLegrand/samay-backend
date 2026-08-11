import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_elevation.dart';

/// Contract tests for the elevation tokens (DISCO-DESIGN-SYSTEM.md §4.3).
///
/// The design is FLAT: no drop shadows on boxes; `none` and `card` are
/// empty. The only shadows are the two brand glow stacks (`glowPink`,
/// `glowCyan`): two layered halos at α0.45/blur 24 + α0.2/blur 48 over the
/// §2 hexes. Stacks are `static const` — the composited alpha hexes are the
/// const-legal encoding of `AppColors.x.withValues(alpha: …)` (see the U-03
/// daily log for the withValues evaluation).
void main() {
  group('AppElevation flat tokens (doc §4.3)', () {
    test('none and card are empty shadow lists', () {
      expect(AppElevation.none, isEmpty);
      expect(AppElevation.card, isEmpty);
    });

    test('glow stacks have exactly two layered halos', () {
      expect(AppElevation.glowPink.length, 2);
      expect(AppElevation.glowCyan.length, 2);
    });

    test('glowPink: glowPink hex at α0.45 (blur 24) + α0.2 (blur 48)', () {
      final pink = AppElevation.glowPink;
      final tight = pink[0];
      final wide = pink[1];

      expect(tight.offset, Offset.zero);
      expect(tight.blurRadius, 24);
      expect(tight.color.toARGB32(), const Color(0x73FF2E88).toARGB32());
      expect(tight.color.a, closeTo(0.45, 0.002));
      expectRgb(tight.color, AppColors.glowPink);

      expect(wide.offset, Offset.zero);
      expect(wide.blurRadius, 48);
      expect(wide.color.toARGB32(), const Color(0x33FF2E88).toARGB32());
      expect(wide.color.a, closeTo(0.2, 0.002));
      expectRgb(wide.color, AppColors.glowPink);
    });

    test('glowCyan: discoCyan hex at α0.45 (blur 24) + α0.2 (blur 48)', () {
      final cyan = AppElevation.glowCyan;
      final tight = cyan[0];
      final wide = cyan[1];

      expect(tight.offset, Offset.zero);
      expect(tight.blurRadius, 24);
      expect(tight.color.toARGB32(), const Color(0x7300E5FF).toARGB32());
      expect(tight.color.a, closeTo(0.45, 0.002));
      expectRgb(tight.color, AppColors.discoCyan);

      expect(wide.offset, Offset.zero);
      expect(wide.blurRadius, 48);
      expect(wide.color.toARGB32(), const Color(0x3300E5FF).toARGB32());
      expect(wide.color.a, closeTo(0.2, 0.002));
      expectRgb(wide.color, AppColors.discoCyan);
    });

    test('glow stacks are const-constructible', () {
      // Compile-time const canonicalization — only compiles if the static
      // lists are true consts (the withValues form would break this).
      const pink = AppElevation.glowPink;
      const cyan = AppElevation.glowCyan;
      expect(pink.length, 2);
      expect(cyan.length, 2);
    });
  });
}

/// Asserts [color] carries the same RGB channels as [expected]
/// (alpha is compared separately via `closeTo`).
void expectRgb(Color color, Color expected) {
  expect(color.r, expected.r, reason: 'red channel');
  expect(color.g, expected.g, reason: 'green channel');
  expect(color.b, expected.b, reason: 'blue channel');
}
