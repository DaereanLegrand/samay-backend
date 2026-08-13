import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/shared/widgets/v_input.dart';

Widget _buildApp(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

BoxDecoration _shell(WidgetTester tester) {
  final shell = tester.widget<AnimatedContainer>(
    find.byKey(VInput.glassShellKey),
  );
  return shell.decoration! as BoxDecoration;
}

BoxDecoration _fill(WidgetTester tester) {
  final fill = tester.widget<AnimatedContainer>(
    find.byKey(VInput.glassFillKey),
  );
  return fill.decoration! as BoxDecoration;
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

    testWidgets('is a radius-16 liquid-glass field — no underline (§5.2 → '
        'LUXE directive #7)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.border, InputBorder.none,
          reason: 'the glass shell draws the border — no decoration border');
      expect(textField.decoration?.border, isNot(isA<UnderlineInputBorder>()),
          reason: 'underline inputs are outdated (LUXE #7)');

      final shell = _shell(tester);
      expect(shell.borderRadius, VInput.radius);
      final ring = shell.gradient! as LinearGradient;
      expect(ring.colors.first, AppColors.white.withValues(alpha: 0.25));
      expect(ring.colors.last, AppColors.white.withValues(alpha: 0.25));
      expect(shell.boxShadow, isEmpty, reason: 'no glow while unfocused');
    });

    testWidgets('fill is surfaceAlt α0.5 inside the 1px ring', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      expect(
        _fill(tester).color,
        AppColors.surfaceAlt.withValues(alpha: 0.5),
      );
      final shell = tester.widget<AnimatedContainer>(
        find.byKey(VInput.glassShellKey),
      );
      expect(
        shell.padding,
        const EdgeInsets.all(1),
        reason: 'the outer shell is the 1px gradient ring',
      );
    });

    testWidgets('focus → white diagonal ring + soft white glow, animated '
        'through the 200ms shell (LUXE #7)', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Test')));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      final shell = _shell(tester);
      final ring = shell.gradient! as LinearGradient;
      expect(ring.colors.first, AppColors.white.withValues(alpha: 0.8),
          reason: 'focused ring brightens top-left');
      expect(ring.colors.last, AppColors.white.withValues(alpha: 0.25));
      expect(shell.boxShadow, hasLength(1));
      expect(
        shell.boxShadow!.first.color,
        AppColors.white.withValues(alpha: 0.12),
      );
      expect(shell.boxShadow!.first.blurRadius, 24);

      await tester.pump(VInput.shellDuration + const Duration(milliseconds: 10));
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the shell animates once and settles');
    });

    testWidgets('label always floats above the field; mutedStrong → white on '
        'focus', (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      var textField = tester.widget<TextField>(find.byType(TextField));
      expect(
        textField.decoration?.floatingLabelBehavior,
        FloatingLabelBehavior.always,
        reason: 'labels are always visible above the field (LUXE #7)',
      );
      expect(
        textField.decoration?.labelStyle?.color,
        AppColors.mutedStrong,
      );
      expect(
        textField.decoration?.labelStyle?.fontSize,
        AppTypography.labelMedium.fontSize,
        reason: 'the label rides the labelMedium voice (LUXE input voice)',
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.labelStyle?.color, AppColors.white);
    });

    testWidgets('label is mutedStrong, hint is mutedStrong (LUXE input '
        'voice — hints must stay legible at 7.37:1)', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', hint: 'tu@email.com')),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      final decoration = textField.decoration!;
      expect(decoration.labelStyle?.color, AppColors.mutedStrong);
      expect(decoration.hintStyle?.color, AppColors.mutedStrong);
      expect(decoration.contentPadding, isNotNull);
      expect(
        decoration.contentPadding,
        const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 18),
      );
    });

    testWidgets('text style is white 17px iOS-native (LUXE input voice)',
        (tester) async {
      await tester.pumpWidget(_buildApp(const VInput(label: 'Email')));
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.style?.color, AppColors.white);
      expect(textField.style?.fontSize, 17);
      expect(textField.style?.fontWeight, FontWeight.w400);
      expect(textField.cursorColor, AppColors.white);
    });

    testWidgets('error → glowPink ring + pink label, error text below in '
        'glowPink (§5.2)', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Email', errorText: 'Invalido')),
      );
      expect(find.text('Invalido'), findsOneWidget);

      final shell = _shell(tester);
      final ring = shell.gradient! as LinearGradient;
      expect(
        ring.colors.first,
        AppColors.glowPink.withValues(alpha: 0.8),
      );
      expect(ring.colors.last, AppColors.glowPink.withValues(alpha: 0.8));
      expect(shell.boxShadow, isEmpty,
          reason: 'the focus glow yields to the error ring');

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.decoration?.errorStyle?.color, AppColors.error);
      expect(textField.decoration?.labelStyle?.color, AppColors.glowPink);
    });

    testWidgets('obscures text when requested', (tester) async {
      await tester.pumpWidget(
        _buildApp(const VInput(label: 'Password', obscureText: true)),
      );
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.obscureText, isTrue);
    });
  });
}
