import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/shared/widgets/glass/glass.dart';

void main() {
  const rose = AppGradients.rose;

  List<DecoratedBox> shadowedBoxes(WidgetTester tester) => tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .where(
        (d) =>
            d.decoration is BoxDecoration &&
            ((d.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false),
      )
      .toList();

  // The VGradientBorder ring container inside VGlass: the only Container
  // whose BoxDecoration gradient sits behind `padding: EdgeInsets.all(1)`
  // (the highlight line is a gradient Container with no padding).
  Container borderRing(WidgetTester tester) => tester
      .widgetList<Container>(find.byType(Container))
      .where(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).gradient != null &&
            c.padding == const EdgeInsets.all(1),
      )
      .first;

  group('VGlass', () {
    testWidgets('renders child', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(child: Text('Glass content'))),
      );
      expect(find.text('Glass content'), findsOneWidget);
    });

    testWidgets('applies a backdrop blur over the surface', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(child: Text('Glass content'))),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('white fill gradient: α0.05 top-left → α0.01 bottom-right',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(child: Text('Glass content'))),
      );
      final fill = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(BackdropFilter),
          matching: find.byType(DecoratedBox),
        ),
      );
      final gradient = (fill.decoration as BoxDecoration).gradient!
          as LinearGradient;
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
      expect(gradient.colors.first.a, closeTo(0.05, 0.001));
      expect(gradient.colors.last.a, closeTo(0.01, 0.001));
    });

    testWidgets('gradient border: white α0.28 → pastel α0.18 → transparent',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(gradient: rose, child: Text('Glass'))),
      );
      final gradient = (borderRing(tester).decoration! as BoxDecoration)
          .gradient! as LinearGradient;
      expect(gradient.colors[0].a, closeTo(0.28, 0.001));
      expect(gradient.colors[1].a, closeTo(0.18, 0.001));
      expect(gradient.colors[2].a, closeTo(0.0, 0.001));
      expect(
        gradient.colors[1],
        rose.colors.first.withValues(alpha: 0.18),
      );
    });

    testWidgets('glow shadows present when glowAlpha > 0 with a gradient',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VGlass(
            gradient: rose,
            glowAlpha: 0.18,
            child: Text('Glass'),
          ),
        ),
      );
      expect(shadowedBoxes(tester), hasLength(1));
    });

    testWidgets('no glow shadows when glowAlpha is 0', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(gradient: rose, child: Text('Glass'))),
      );
      expect(shadowedBoxes(tester), isEmpty);
    });

    testWidgets('no glow when gradient is null even with glowAlpha > 0 '
        '(white-only glass has no pastel glow)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(glowAlpha: 0.5, child: Text('Glass'))),
      );
      expect(shadowedBoxes(tester), isEmpty);
    });

    testWidgets('default radius is zero (brutalism)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(gradient: rose, child: Text('Glass'))),
      );
      final decoration = borderRing(tester).decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.zero);
    });

    testWidgets('top highlight line sits at the top edge inside the radius',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlass(child: Text('Glass'))),
      );
      final highlight = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) => d.decoration is BoxDecoration)
          .where((d) {
            final gradient = (d.decoration as BoxDecoration).gradient;
            return gradient is LinearGradient &&
                gradient.colors.any((c) => c.a == 0.10);
          })
          .first;
      final gradient = (highlight.decoration as BoxDecoration).gradient!
          as LinearGradient;
      expect(gradient.colors[1].a, closeTo(0.10, 0.001));
    });
  });

  group('VGlassCard', () {
    testWidgets('renders child with card padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlassCard(child: Text('Card'))),
      );
      expect(find.text('Card'), findsOneWidget);
      final padded = tester
          .widgetList<Padding>(find.byType(Padding))
          .where((p) => p.padding == const EdgeInsets.all(AppSpacing.lg))
          .toList();
      expect(padded, isNotEmpty);
    });

    testWidgets('is sharp (radius zero) with glowAlpha 0.18', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VGlassCard(gradient: rose, child: Text('Card'))),
      );
      final decoration = borderRing(tester).decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.zero);
      expect(shadowedBoxes(tester), hasLength(1));
    });
  });
}
