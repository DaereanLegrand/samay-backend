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

    testWidgets('selected chip has white fill + black label', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VChip(label: 'VIP', selected: true)),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selectedColor, AppColors.white);
      expect(chip.labelStyle?.color, AppColors.discoBlack);
    });

    testWidgets('monochrome: no accent variant exists — every chip resolves '
        'the same white/black treatment', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          const Row(
            children: [
              VChip(label: 'A'),
              VChip(label: 'B', selected: true),
            ],
          ),
        ),
      );
      final chips = tester.widgetList<FilterChip>(find.byType(FilterChip));
      for (final chip in chips) {
        expect(chip.side?.color, AppColors.white);
        expect(
          chip.selectedColor,
          AppColors.white,
          reason: 'selection is the white fill, never an accent hue',
        );
      }
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
