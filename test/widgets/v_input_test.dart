import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/shared/widgets/v_input.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('VInput', () {
    testWidgets('renders the label as the placeholder (hint) — no floating '
        'label (user override 2026-08-18)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      expect(find.text('Email'), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.hintText, 'Email');
      expect(
        textField.decoration?.floatingLabelBehavior,
        FloatingLabelBehavior.never,
        reason: 'placeholder-only — labels never float above the field',
      );
    });

    testWidgets('accepts text input', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Name')));
      await tester.enterText(find.byType(TextField), 'John');
      expect(find.text('John'), findsOneWidget);
    });

    testWidgets('is borderless and backgroundless — no border, no fill',
        (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      final decoration = textField.decoration!;
      expect(decoration.border, InputBorder.none,
          reason: 'the field draws no border (user override: no border)');
      expect(
        decoration.border,
        isNot(isA<UnderlineInputBorder>()),
        reason: 'underline inputs are still outdated (LUXE #7)',
      );
      expect(decoration.filled, isFalse,
          reason: 'the field has no background fill (user override)');
      expect(decoration.fillColor, isNull);
      expect(decoration.labelText, isNull,
          reason: 'placeholder-only — a label never renders as text above');
    });

    testWidgets('text is white 17px iOS-native with a white cursor (LUXE '
        'input voice)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.style?.color, AppColors.white);
      expect(textField.style?.fontSize, 17);
      expect(textField.style?.fontWeight, FontWeight.w400);
      expect(textField.cursorColor, AppColors.white);
    });

    testWidgets('hint is mutedStrong (AA 7.37:1), the only field cue',
        (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      final decoration = textField.decoration!;
      expect(decoration.hintStyle?.color, AppColors.mutedStrong);
      expect(decoration.hintStyle?.fontSize, 17);
      expect(decoration.contentPadding, isNotNull);
      expect(
        decoration.contentPadding,
        const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      );
    });

    testWidgets('explicit hint wins over the label', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', hint: 'tu@email.com')),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.hintText, 'tu@email.com');
    });

    testWidgets('error → errorText below in glowPink and the hint turns '
        'glowPink (§5.2 — never raw red on black)', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', errorText: 'Invalido')),
      );
      expect(find.text('Invalido'), findsOneWidget);

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.errorStyle?.color, AppColors.error);
      expect(
        textField.decoration?.hintStyle?.color,
        AppColors.glowPink,
        reason: 'on error the placeholder itself signals the state',
      );
      expect(
        textField.decoration?.errorBorder,
        InputBorder.none,
        reason: 'no border state — the error rides the text, not a ring',
      );
    });

    testWidgets('obscures text when requested', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Password', obscureText: true)),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.obscureText, isTrue);
    });

    testWidgets('passes min/max lines through for growing composer fields',
        (tester) async {
      await tester.pumpWidget(
        _buildApp(
          const VInput(label: 'Message', minLines: 1, maxLines: 3),
        ),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.minLines, 1);
      expect(textField.maxLines, 3);
    });

    testWidgets('passes textAlignVertical through (composer centers its '
        'single-line text inside the button-height box)', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          const VInput(
            label: 'Message',
            textAlignVertical: TextAlignVertical.center,
          ),
        ),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.textAlignVertical, TextAlignVertical.center);
    });
  });
}