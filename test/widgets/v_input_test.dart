import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/v_input.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('VInput', () {
    testWidgets('renders with label', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      expect(find.text('Email'), findsOneWidget);
    });

    testWidgets('accepts text input', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Name')));
      await tester.enterText(find.byType(TextField), 'John');
      expect(find.text('John'), findsOneWidget);
    });

    testWidgets('has white underline decoration', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      final underline = textField.decoration?.enabledBorder as UnderlineInputBorder?;
      expect(underline, isNotNull);
      expect(underline!.borderSide.color, Colors.white);
    });
  });
}
