import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vive_app/shared/widgets/v_button.dart';

void main() {
  group('VButton', () {
    testWidgets('renders outlined variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.outlined(
            onPressed: () {},
            child: const Text('Tap me'),
          ),
        ),
      );
      expect(find.text('Tap me'), findsOneWidget);
    });

    testWidgets('renders emphasized variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.emphasized(
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      );
      expect(find.text('Go'), findsOneWidget);
    });

    testWidgets('fires onPressed', (tester) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.outlined(
            onPressed: () => pressed = true,
            child: const Text('Press'),
          ),
        ),
      );
      await tester.tap(find.text('Press'));
      expect(pressed, isTrue);
    });

    testWidgets('outlined has white border', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.outlined(
            onPressed: () {},
            child: const Text('Outlined'),
          ),
        ),
      );
      final container = tester.widget<TextButton>(find.byType(TextButton));
      final style = container.style;
      expect(style?.side?.resolve({}), const BorderSide(color: Colors.white));
    });

    testWidgets('emphasized has white fill', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.emphasized(
            onPressed: () {},
            child: const Text('Fill'),
          ),
        ),
      );
      final container = tester.widget<TextButton>(find.byType(TextButton));
      final style = container.style;
      expect(style?.backgroundColor?.resolve({}), Colors.white);
    });
  });
}
