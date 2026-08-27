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

    testWidgets('dark variant: black fill, white text, white hairline '
        '(user directive 2026-08-14)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VButton.dark(onPressed: () {}, child: const Text('Black')),
        ),
      );
      final button = tester.widget<VButton>(find.byType(VButton));
      expect(button.variant, VButtonVariant.dark);
      final textButton = tester.widget<TextButton>(find.byType(TextButton));
      final style = textButton.style;
      expect(
        style?.backgroundColor?.resolve({}),
        AppColors.surfaceAlt,
        reason: 'the face is the black surface',
      );
      expect(
        style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'white text on the black face',
      );
      expect(style?.side?.resolve({}), const BorderSide(color: Colors.white));
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

    testWidgets('monochrome: NO gradient fill path, NO glow halo', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              VButton.outlined(onPressed: () {}, child: const Text('A')),
              VButton.emphasized(onPressed: () {}, child: const Text('B')),
              VButton.dark(onPressed: () {}, child: const Text('C')),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('vButtonGradientFill')), findsNothing);
      final halo = find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false),
      );
      expect(halo, findsNothing, reason: 'no boxShadow on buttons');
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
        expect(
          overlay,
          isNotNull,
          reason: 'VButton must carry the §5.1 press overlay',
        );
        expect(
          overlay!.a,
          closeTo(0.1, 0.01),
          reason: 'pressed overlay = α0.1 of the base (§5.1)',
        );
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
          reason:
              'DISCO §6.1 bans scale on press — the α0.1 overlay is the '
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
