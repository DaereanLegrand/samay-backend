import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/shared/widgets/v_card.dart';

void main() {
  group('VCard', () {
    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VCard(child: Text('Card content'))),
      );
      expect(find.text('Card content'), findsOneWidget);
    });

    testWidgets('has surface fill per §5.3', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VCard(child: SizedBox())),
      );
      final card = tester.widget<Container>(find.byType(Container));
      expect((card.decoration as BoxDecoration).color, AppColors.surface);
    });

    testWidgets('has hairline border per §5.3', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VCard(child: SizedBox())),
      );
      final card = tester.widget<Container>(find.byType(Container));
      final border = (card.decoration as BoxDecoration).border;
      expect(border, isNotNull);
      final side = border!.top;
      expect(side.color, AppColors.hairline);
      expect(side.width, 1);
    });

    testWidgets('has sharp corners (zero border radius)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VCard(child: SizedBox())),
      );
      final card = tester.widget<Container>(find.byType(Container));
      final borderRadius = (card.decoration as BoxDecoration).borderRadius;
      expect(borderRadius, isNull);
    });

    testWidgets('uses cardPadding for the inner padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: VCard(child: SizedBox())),
      );
      final card = tester.widget<Container>(find.byType(Container));
      expect(card.padding, const EdgeInsets.all(AppSpacing.cardPadding));
    });
  });
}
