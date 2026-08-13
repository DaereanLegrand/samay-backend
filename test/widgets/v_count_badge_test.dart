import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

void main() {
  group('VCountBadge', () {
    testWidgets('renders nothing for count <= 0 (zero-width box)', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: VCountBadge(count: 0)));
      final box = tester.widget<SizedBox>(find.byType(SizedBox));
      expect(box.width, 0);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('default accent is the violet family vivid end — never pink '
        '(LUXE 2026-08-12)', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VCountBadge(count: 3)));
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.discoBlack);
      expect(decoration.border, Border.all(color: AppColors.discoViolet));
      final text = tester.widget<Text>(find.text('3'));
      expect(text.style?.color, AppColors.discoViolet);
    });

    testWidgets('gradient param drives the accent family (cyan)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VCountBadge(count: 7, gradient: AppGradients.cyan),
        ),
      );
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.border, Border.all(color: AppColors.discoCyan));
      final text = tester.widget<Text>(find.text('7'));
      expect(text.style?.color, AppColors.discoCyan);
    });

    testWidgets('is const-constructible', (tester) async {
      const badge = VCountBadge(count: 1);
      expect(badge, isA<VCountBadge>());
      expect(badge.gradient, isNull);
    });
  });
}
