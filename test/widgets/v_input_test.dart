import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
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
      final underline =
          textField.decoration?.enabledBorder as UnderlineInputBorder?;
      expect(underline, isNotNull);
      expect(underline!.borderSide.color, Colors.white);
    });

    testWidgets('focused underline is 2px white (§5.2)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      final focused =
          textField.decoration?.focusedBorder as UnderlineInputBorder?;
      expect(focused, isNotNull);
      expect(focused!.borderSide.color, Colors.white);
      expect(focused.borderSide.width, 2);
    });

    testWidgets('label is mutedStrong and hint is muted (§5.2)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', hint: 'tu@email.com')),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      final decoration = textField.decoration!;
      expect(decoration.labelStyle?.color, AppColors.mutedStrong);
      expect(decoration.hintStyle?.color, AppColors.muted);
    });

    testWidgets('text style is white bodyLarge (§5.2)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.style?.color, AppColors.white);
      expect(textField.style?.fontSize, AppTypography.bodyLarge.fontSize);
    });

    testWidgets('error text renders in glowPink (§5.2)', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', errorText: 'Invalido')),
      );
      expect(find.text('Invalido'), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.errorStyle?.color, AppColors.error);
    });
  });
}
