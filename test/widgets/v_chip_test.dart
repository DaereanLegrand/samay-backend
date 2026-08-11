import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/v_chip.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('VChip', () {
    testWidgets('renders with label', (tester) async {
      await tester.pumpWidget(_buildApp(const VChip(label: 'VIP')));
      expect(find.text('VIP'), findsOneWidget);
    });

    testWidgets('unselected is not selected', (tester) async {
      await tester.pumpWidget(_buildApp(const VChip(label: 'Basic')));
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isFalse);
    });

    testWidgets('selected is selected', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VChip(label: 'Selected', selected: true)),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isTrue);
    });

    testWidgets('default chip has white border and labelMedium typography '
        '(§5.4)', (tester) async {
      await tester.pumpWidget(_buildApp(const VChip(label: 'VIP')));
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.side, const BorderSide(color: AppColors.white));
      expect(chip.backgroundColor, Colors.transparent);
      expect(chip.labelStyle?.color, AppColors.white);
      expect(chip.labelStyle?.fontSize, 12);
    });

    testWidgets('selected default chip has white fill + black label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(const VChip(label: 'VIP', selected: true)),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selectedColor, AppColors.white);
      expect(chip.labelStyle?.color, AppColors.discoBlack);
    });

    testWidgets('accent chip has pink border and pink label (§5.4)', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(const VChip.accent(label: 'VIP')));
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.side, const BorderSide(color: AppColors.glowPink));
      expect(chip.labelStyle?.color, AppColors.glowPink);
    });

    testWidgets('selected accent chip has pink fill + black label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(const VChip.accent(label: 'VIP', selected: true)),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selectedColor, AppColors.glowPink);
      expect(chip.labelStyle?.color, AppColors.discoBlack);
    });

    testWidgets('sharp corners (§4.2)', (tester) async {
      await tester.pumpWidget(_buildApp(const VChip(label: 'VIP')));
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(
        chip.shape,
        const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      );
    });
  });
}
