import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive/shared/widgets/v_card.dart';

void main() {
  group('VCard', () {
    testWidgets('renders child widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VCard(child: Text('Card content')),
        ),
      );
      expect(find.text('Card content'), findsOneWidget);
    });

    testWidgets('has black fill', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VCard(child: const SizedBox()),
        ),
      );
      final card = tester.widget<Container>(find.byType(Container));
      expect((card.decoration as BoxDecoration).color, Colors.black);
    });

    testWidgets('has gray border', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VCard(child: const SizedBox()),
        ),
      );
      final card = tester.widget<Container>(find.byType(Container));
      final border = (card.decoration as BoxDecoration).border;
      expect(border, isNotNull);
    });

    testWidgets('has sharp corners (zero border radius)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VCard(child: const SizedBox()),
        ),
      );
      final card = tester.widget<Container>(find.byType(Container));
      final borderRadius = (card.decoration as BoxDecoration).borderRadius;
      expect(borderRadius, isNull);
    });
  });
}
