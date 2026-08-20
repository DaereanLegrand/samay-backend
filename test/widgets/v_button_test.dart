import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
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
        reason: 'the face is the black surface, never a family gradient',
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

    group('glowAccent — LUXE violet default (no pink mains, 2026-08-12)', () {
      testWidgets('defaults to the violet family: gradient ring, white text, '
          'violet halo', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.glowAccent(
              onPressed: () {},
              child: const Text('Glow'),
            ),
          ),
        );
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(style?.backgroundColor?.resolve({}), Colors.transparent);
        expect(style?.foregroundColor?.resolve({}), AppColors.white);
        // The halo is the only DecoratedBox carrying a boxShadow stack.
        final halo = tester.widget<DecoratedBox>(
          find
              .byWidgetPredicate(
                (w) =>
                    w is DecoratedBox &&
                    w.decoration is BoxDecoration &&
                    (w.decoration as BoxDecoration).boxShadow != null,
              )
              .first,
        );
        final shadows = (halo.decoration as BoxDecoration).boxShadow!;
        expect(shadows, hasLength(3));
        expect(
          shadows[0].color,
          AppGradients.violet.colors[1].withValues(alpha: 0.35),
        );
        expect(
          shadows[1].color,
          AppGradients.violet.colors[2].withValues(alpha: 0.35 * 0.6),
        );
        expect(
          shadows[2].color,
          AppGradients.violet.colors[2].withValues(alpha: 0.35 * 0.3),
        );
      });

      testWidgets(
        'outline label carries the violet glow-hairline shadow (§5.1)',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: VButton.glowAccent(onPressed: () {}, label: 'Glow'),
            ),
          );
          final text = tester.widget<Text>(find.text('Glow'));
          expect(text.style?.shadows, [
            Shadow(
              color: AppGradients.violet.colors[1].withValues(alpha: 0.35),
              blurRadius: 3.5,
            ),
          ]);
        },
      );

      testWidgets('filled renders the violet gradient fill + black text', (
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
        final fill = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('vButtonGradientFill')),
        );
        final gradient =
            (fill.decoration as BoxDecoration).gradient! as LinearGradient;
        expect(gradient.colors, AppGradients.violet.colors);
        expect(gradient.stops, AppGradients.violet.stops);
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(style?.backgroundColor?.resolve({}), Colors.transparent);
        expect(style?.foregroundColor?.resolve({}), AppColors.discoBlack);
      });

      testWidgets('pressed resolves the darker-violet overlay + white text', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.glowAccent(
              onPressed: () {},
              child: const Text('Glow'),
            ),
          ),
        );
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(
          style?.overlayColor?.resolve({WidgetState.pressed}),
          Color.lerp(
            AppGradients.violet.colors.last,
            AppColors.discoBlack,
            0.35,
          ),
        );
        expect(
          style?.foregroundColor?.resolve({WidgetState.pressed}),
          AppColors.white,
        );
        expect(
          style?.backgroundColor?.resolve({WidgetState.pressed}),
          Colors.transparent,
        );
      });

      testWidgets('loading on a filled gradient keeps a black spinner '
          '(contrast with the fill)', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.glowAccent(
              loading: true,
              onPressed: () {},
              filled: true,
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

      testWidgets('disabled drops the gradient ring and text to muted (§5.1)', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.glowAccent(
              onPressed: null,
              child: const Text('Disabled'),
            ),
          ),
        );
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(
          style?.foregroundColor?.resolve({WidgetState.disabled}),
          AppColors.muted,
        );
      });
    });

    group('gradient param on the flat variants (LUXE v2)', () {
      testWidgets('emphasized with a gradient renders the family fill + black '
          'text', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.emphasized(
              onPressed: () {},
              gradient: AppGradients.mint,
              child: const Text('Mint'),
            ),
          ),
        );
        final fill = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('vButtonGradientFill')),
        );
        final gradient =
            (fill.decoration as BoxDecoration).gradient! as LinearGradient;
        expect(gradient.colors, AppGradients.mint.colors);
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(style?.foregroundColor?.resolve({}), AppColors.discoBlack);
      });

      testWidgets('outlined with a gradient renders a pastel ring, no fill', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VButton.outlined(
              onPressed: () {},
              gradient: AppGradients.gold,
              child: const Text('Gold'),
            ),
          ),
        );
        expect(find.byKey(const ValueKey('vButtonGradientFill')), findsNothing);
        final style = tester.widget<TextButton>(find.byType(TextButton)).style;
        expect(style?.foregroundColor?.resolve({}), AppColors.white);
      });
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
