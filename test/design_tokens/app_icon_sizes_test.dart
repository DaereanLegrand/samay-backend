import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';

/// Contract tests for the icon-size tokens (DESIGN.md §4.4).
void main() {
  group('AppIconSizes scale (doc §4.4)', () {
    test('the scale matches the documented values', () {
      expect(AppIconSizes.xs, 12);
      expect(AppIconSizes.sm, 16);
      expect(AppIconSizes.md, 20);
      expect(AppIconSizes.lg, 24);
      expect(AppIconSizes.xl, 32);
      expect(AppIconSizes.xxl, 48);
      expect(AppIconSizes.avatar, 40);
      expect(AppIconSizes.avatarLarge, 80);
    });

    test('the scale is strictly monotonic', () {
      final scale = [
        AppIconSizes.xs,
        AppIconSizes.sm,
        AppIconSizes.md,
        AppIconSizes.lg,
        AppIconSizes.xl,
        AppIconSizes.xxl,
      ];
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]),
            reason: 'step $i must be larger than step ${i - 1}');
      }
    });

    test('avatar sizes mirror the AppSpacing avatar scale', () {
      expect(AppIconSizes.avatar, 40);
      expect(AppIconSizes.avatarLarge, 80);
    });
  });
}
