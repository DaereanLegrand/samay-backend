import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/v_button.dart';

void main() {
  group('VButton', () {
    testWidgets('renders outlined variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.outlined(onPressed: () {}, child: const Text('Tap me')),
        ),
      );
      expect(find.text('Tap me'), findsOneWidget);
    });

    testWidgets('renders emphasized variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.emphasized(onPressed: () {}, child: const Text('Go')),
        ),
      );
      expect(find.text('Go'), findsOneWidget);
    });

    testWidgets('renders glowAccent variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.glowAccent(onPressed: () {}, child: const Text('Glow')),
        ),
      );
      expect(find.text('Glow'), findsOneWidget);
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

    testWidgets('emphasized has white fill and no border', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.emphasized(onPressed: () {}, child: const Text('Fill')),
        ),
      );
      final container = tester.widget<TextButton>(find.byType(TextButton));
      final style = container.style;
      expect(style?.backgroundColor?.resolve({}), Colors.white);
      expect(
        style?.side?.resolve({}),
        const BorderSide(color: Colors.transparent),
      );
    });

    testWidgets('glowAccent has pink border and pink text (non-filled)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.glowAccent(onPressed: () {}, child: const Text('Glow')),
        ),
      );
      final style = tester.widget<TextButton>(find.byType(TextButton)).style;
      expect(
        style?.side?.resolve({}),
        const BorderSide(color: AppColors.glowPink),
      );
      expect(style?.backgroundColor?.resolve({}), Colors.transparent);
      expect(style?.foregroundColor?.resolve({}), AppColors.glowPink);
    });

    testWidgets('glowAccent filled has pink fill and black text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.glowAccent(
            onPressed: () {},
            filled: true,
            child: const Text('Glow filled'),
          ),
        ),
      );
      final style = tester.widget<TextButton>(find.byType(TextButton)).style;
      expect(style?.backgroundColor?.resolve({}), AppColors.glowPink);
      expect(style?.foregroundColor?.resolve({}), AppColors.discoBlack);
    });

    testWidgets('glowAccent pressed state is glowPinkDeep fill + white text '
        '(§5.1)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.glowAccent(onPressed: () {}, child: const Text('Glow')),
        ),
      );
      final style = tester.widget<TextButton>(find.byType(TextButton)).style;
      expect(
        style?.backgroundColor?.resolve({WidgetState.pressed}),
        AppColors.glowPinkDeep,
      );
      expect(
        style?.foregroundColor?.resolve({WidgetState.pressed}),
        AppColors.white,
      );
    });

    testWidgets('disabled drops outline and text to muted (§5.1)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.outlined(
            onPressed: null,
            child: const Text('Disabled'),
          ),
        ),
      );
      final style = tester.widget<TextButton>(find.byType(TextButton)).style;
      expect(
        style?.side?.resolve({WidgetState.disabled}),
        const BorderSide(color: AppColors.muted),
      );
      expect(
        style?.foregroundColor?.resolve({WidgetState.disabled}),
        AppColors.muted,
      );
    });

    testWidgets('loading renders a spinner in the foreground color', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.emphasized(
            loading: true,
            onPressed: () {},
            child: const Text('Loading'),
          ),
        ),
      );
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(spinner.strokeWidth, 2);
      expect(spinner.color, AppColors.discoBlack);
    });

    group('press feedback (U-18 verify — §5.1/§6.1)', () {
      testWidgets('pressed state resolves the α0.1 overlay of the variant '
          'base color (§5.1)', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.outlined(
              onPressed: () {},
              child: const Text('Press'),
            ),
          ),
        );
        final overlay = tester
            .widget<TextButton>(find.byType(TextButton))
            .style
            ?.overlayColor
            ?.resolve({WidgetState.pressed});
        expect(overlay, isNotNull,
            reason: 'VButton must carry the §5.1 press overlay');
        expect(overlay!.a, closeTo(0.1, 0.01),
            reason: 'pressed overlay = α0.1 of the base (§5.1)');
        expect(overlay.r, AppColors.white.r);
        expect(overlay.g, AppColors.white.g);
        expect(overlay.b, AppColors.white.b);
      });

      testWidgets('a real press never applies a scale transform (§6.1 '
          '"no scale, no bounce")', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.outlined(
              onPressed: () {},
              child: const Text('Press'),
            ),
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Press')),
        );
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(TextButton),
            matching: find.byType(Transform),
          ),
          findsNothing,
          reason: 'DISCO §6.1 bans scale on press — the α0.1 overlay is the '
              'whole press effect (the user CSS scale(0.97) does not apply)',
        );
        expect(
          find.descendant(
            of: find.byType(TextButton),
            matching: find.byType(ScaleTransition),
          ),
          findsNothing,
        );
        await gesture.up();
        await tester.pump();
      });

      testWidgets('pressing the button does not crash', (tester) async {
        var pressed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.emphasized(
              onPressed: () => pressed = true,
              child: const Text('Press'),
            ),
          ),
        );
        await tester.tap(find.text('Press'));
        await tester.pumpAndSettle();
        expect(pressed, isTrue);
      });
    });
  });
}
