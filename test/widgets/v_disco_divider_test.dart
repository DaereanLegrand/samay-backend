import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/shared/widgets/v_disco_divider.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('VDiscoDivider', () {
    testWidgets('renders a full-width hairline split by a centered violet '
        'accent (§2.1/§4.2 spirit — LUXE no-pink-mains)', (tester) async {
      await tester.pumpWidget(_wrap(const VDiscoDivider()));

      final hairlineBoxes = tester
          .widgetList<Container>(
            find.byWidgetPredicate(
              (w) => w is Container && w.color == AppColors.hairline,
            ),
          )
          .toList();
      expect(hairlineBoxes, hasLength(2));

      final accentFinder = find.byWidgetPredicate(
        (w) => w is Container && w.color == AppColors.statusVip,
      );
      expect(accentFinder, findsOneWidget);
      expect(tester.getSize(accentFinder), const Size(AppSpacing.xxxl, 1));

      expect(tester.getSize(find.byType(VDiscoDivider)), const Size(800, 1));
    });

    testWidgets('hairline boxes are exactly 1px tall', (tester) async {
      await tester.pumpWidget(_wrap(const VDiscoDivider()));
      for (final box in tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == AppColors.hairline,
        ),
      )) {
        final size = tester.getSize(find.byWidget(box));
        expect(size.height, 1);
        expect(size.width, greaterThan(0));
      }
    });

    testWidgets('thickness, accent width and colors are configurable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VDiscoDivider(
            thickness: 2,
            accentWidth: 24,
            color: AppColors.border,
            accentColor: AppColors.discoCyan,
          ),
        ),
      );

      final hairlineBoxes = tester
          .widgetList<Container>(
            find.byWidgetPredicate(
              (w) => w is Container && w.color == AppColors.border,
            ),
          )
          .toList();
      expect(hairlineBoxes, hasLength(2));
      for (final box in hairlineBoxes) {
        expect(tester.getSize(find.byWidget(box)).height, 2);
      }

      final accentFinder = find.byWidgetPredicate(
        (w) => w is Container && w.color == AppColors.discoCyan,
      );
      expect(accentFinder, findsOneWidget);
      expect(tester.getSize(accentFinder), const Size(24, 2));
    });

    testWidgets('is const-constructible', (tester) async {
      const divider = VDiscoDivider();
      expect(divider, isA<VDiscoDivider>());
    });
  });
}
