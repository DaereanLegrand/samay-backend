import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/v_badge.dart';

void main() {
  group('VBadge', () {
    testWidgets('renders with label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VBadge(label: 'S'),
        ),
      );
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('renders with custom color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: VBadge(label: 'A', color: Colors.white),
        ),
      );
      expect(find.text('A'), findsOneWidget);
    });
  });
}
