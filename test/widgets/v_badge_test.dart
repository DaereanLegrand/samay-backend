import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/shared/widgets/v_badge.dart';

void main() {
  group('VBadge', () {
    testWidgets('renders with label', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VBadge(label: 'S')));
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('renders with custom fill color and black text', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VBadge(label: 'A', color: Colors.white),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      final container = tester.widget<Container>(find.byType(Container));
      expect((container.decoration as BoxDecoration).color, Colors.white);
      final text = tester.widget<Text>(find.text('A'));
      expect(text.style?.color, AppColors.discoBlack);
    });

    testWidgets('default is border #333333 fill + white labelSmall uppercase '
        '(§5.5)', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VBadge(label: 'Nuevo')));
      expect(find.text('NUEVO'), findsOneWidget);
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.border);
      expect(decoration.borderRadius, BorderRadius.zero);
      final text = tester.widget<Text>(find.text('NUEVO'));
      expect(text.style?.color, AppColors.white);
      expect(text.style?.fontSize, 10);
    });

    testWidgets('emphasized variant is white fill + black text (§5.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: VBadge.emphasized(label: 'Pago')),
      );
      final container = tester.widget<Container>(find.byType(Container));
      expect((container.decoration as BoxDecoration).color, AppColors.white);
      final text = tester.widget<Text>(find.text('PAGO'));
      expect(text.style?.color, AppColors.discoBlack);
    });

    testWidgets('accent variant has accent border + same-color text on black '
        'fill (§5.5)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VBadge.accent(label: 'Live', color: AppColors.statusLive),
        ),
      );
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.discoBlack);
      expect(decoration.border, Border.all(color: AppColors.statusLive));
      final text = tester.widget<Text>(find.text('LIVE'));
      expect(text.style?.color, AppColors.statusLive);
    });

    group('LUXE accent family (no pink mains, 2026-08-12)', () {
      testWidgets('accent without args defaults to the violet family: pale '
          'watered fill, mid-stop border, black label', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: VBadge.accent(label: 'Nuevo')),
        );
        final container = tester.widget<Container>(find.byType(Container));
        final decoration = container.decoration as BoxDecoration;
        expect(
          decoration.color,
          AppGradients.watered(AppGradients.violet.colors).first,
          reason: 'the fill is the family watered down with white (pastel)',
        );
        expect(
          decoration.border,
          Border.all(color: AppGradients.violet.colors[1]),
          reason: 'the border is the family mid stop',
        );
        final text = tester.widget<Text>(find.text('NUEVO'));
        expect(
          text.style?.color,
          AppColors.discoBlack,
          reason: 'black label keeps contrast on the pale fill',
        );
      });

      testWidgets('accent gradient param drives the family (cyan)', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: VBadge.accent(label: 'Cian', gradient: AppGradients.cyan),
          ),
        );
        final container = tester.widget<Container>(find.byType(Container));
        final decoration = container.decoration as BoxDecoration;
        expect(
          decoration.color,
          AppGradients.watered(AppGradients.cyan.colors).first,
        );
        expect(
          decoration.border,
          Border.all(color: AppGradients.cyan.colors[1]),
        );
        final text = tester.widget<Text>(find.text('CIAN'));
        expect(text.style?.color, AppColors.discoBlack);
      });

      testWidgets('accent with color keeps the legacy flat accent', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: VBadge.accent(label: 'Vip', color: AppColors.discoGold),
          ),
        );
        final container = tester.widget<Container>(find.byType(Container));
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, AppColors.discoBlack);
        expect(decoration.border, Border.all(color: AppColors.discoGold));
        final text = tester.widget<Text>(find.text('VIP'));
        expect(text.style?.color, AppColors.discoGold);
      });
    });
  });
}
