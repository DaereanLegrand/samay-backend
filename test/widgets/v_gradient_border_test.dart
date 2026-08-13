import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/glass/glass.dart';

void main() {
  const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.white, AppColors.glowPink],
  );

  List<Container> containers(WidgetTester tester) =>
      tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .toList();

  group('VGradientBorder', () {
    testWidgets('renders child', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(gradient: gradient, child: Text('Bordered')),
        ),
      );
      expect(find.text('Bordered'), findsOneWidget);
    });

    testWidgets('outer box carries the gradient decoration', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(gradient: gradient, child: SizedBox()),
        ),
      );
      final outer = containers(tester).first;
      final decoration = outer.decoration! as BoxDecoration;
      expect(decoration.gradient, gradient);
    });

    testWidgets('inner box uses the fill color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(
            gradient: gradient,
            color: AppColors.surface,
            child: SizedBox(),
          ),
        ),
      );
      final inner = containers(tester).last;
      final decoration = inner.decoration! as BoxDecoration;
      expect(decoration.color, AppColors.surface);
    });

    testWidgets('width is applied as the outer padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(gradient: gradient, width: 2, child: SizedBox()),
        ),
      );
      expect(containers(tester).first.padding, const EdgeInsets.all(2));
    });

    testWidgets('default width is 1', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(gradient: gradient, child: SizedBox()),
        ),
      );
      expect(containers(tester).first.padding, const EdgeInsets.all(1));
    });

    testWidgets('default radius is zero', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(gradient: gradient, child: SizedBox()),
        ),
      );
      final outer = containers(tester).first;
      final decoration = outer.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.zero);
    });

    testWidgets('radius is respected: outer keeps it, inner is deflated by '
        'the width', (tester) async {
      const radius = BorderRadius.all(Radius.circular(16));
      await tester.pumpWidget(
        const MaterialApp(
          home: VGradientBorder(
            gradient: gradient,
            radius: radius,
            child: SizedBox(),
          ),
        ),
      );
      final boxes = containers(tester);
      final outer = boxes.first.decoration! as BoxDecoration;
      final inner = boxes.last.decoration! as BoxDecoration;
      expect(outer.borderRadius, radius);
      expect(
        inner.borderRadius,
        radius.subtract(const BorderRadius.all(Radius.circular(1))),
      );
    });
  });
}
