import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/v_chip.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('VChip', () {
    testWidgets('renders with label', (tester) async {
      await tester.pumpWidget(_buildApp(VChip(label: 'VIP')));
      expect(find.text('VIP'), findsOneWidget);
    });

    testWidgets('unselected is not selected', (tester) async {
      await tester.pumpWidget(_buildApp(VChip(label: 'Basic')));
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isFalse);
    });

    testWidgets('selected is selected', (tester) async {
      await tester.pumpWidget(
        _buildApp(VChip(label: 'Selected', selected: true)),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isTrue);
    });
  });
}
