import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';

void main() {
  group('AppSpacing scale (DESIGN.md §4.1)', () {
    test('the 8-step scale matches the documented values', () {
      expect(AppSpacing.none, 0);
      expect(AppSpacing.xs, 4);
      expect(AppSpacing.sm, 8);
      expect(AppSpacing.md, 12);
      expect(AppSpacing.lg, 16);
      expect(AppSpacing.xl, 24);
      expect(AppSpacing.xxl, 32);
      expect(AppSpacing.xxxl, 48);
    });

    test('the scale is strictly monotonic', () {
      final scale = [
        AppSpacing.none,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xxxl,
      ];
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]),
            reason: 'step $i must be larger than step ${i - 1}');
      }
    });

    test('semantic aliases map onto the scale (§4.1 table)', () {
      expect(AppSpacing.screenHorizontal, AppSpacing.xl);
      expect(AppSpacing.screenVertical, AppSpacing.xl);
      expect(AppSpacing.cardPadding, AppSpacing.lg);
      expect(AppSpacing.buttonPadding, AppSpacing.lg);
      expect(AppSpacing.inputPadding, AppSpacing.lg);
      expect(AppSpacing.listGap, AppSpacing.sm);
      expect(AppSpacing.sectionGap, AppSpacing.xl);
      expect(AppSpacing.avatar, 40);
      expect(AppSpacing.avatarLarge, 80);
    });

    test('semantic aliases carry the exact documented pixel values', () {
      expect(AppSpacing.screenHorizontal, 24);
      expect(AppSpacing.screenVertical, 24);
      expect(AppSpacing.cardPadding, 16);
      expect(AppSpacing.buttonPadding, 16);
      expect(AppSpacing.inputPadding, 16);
      expect(AppSpacing.listGap, 8);
      expect(AppSpacing.sectionGap, 24);
      expect(AppSpacing.avatar, 40);
      expect(AppSpacing.avatarLarge, 80);
    });
  });

  group('AppSpacing.scale (responsive spacing, §7.3)', () {
    testWidgets('scale returns the raw value at the default text scale',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      expect(AppSpacing.scale(context, 8), 8);
      expect(AppSpacing.scale(context, 24), 24);
    });

    testWidgets('scale multiplies by the MediaQuery textScaler',
        (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: MaterialApp(home: SizedBox()),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(AppSpacing.scale(context, 8), closeTo(12.0, 0.0001));
      expect(AppSpacing.scale(context, 24), closeTo(36.0, 0.0001));
    });
  });
}
