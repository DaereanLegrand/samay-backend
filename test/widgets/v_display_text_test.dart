import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/shared/widgets/v_display_text.dart';

Widget _wrap(Widget child, {bool reduced = false}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(child: child),
      ),
    ),
  );
}

Text _displayText(WidgetTester tester) => tester.widget<Text>(
  find.descendant(of: find.byType(VDisplayText), matching: find.byType(Text)),
);

/// Monochrome contract (2026-08-26 user directive): display copy renders
/// VERBATIM (no case transformation) in flat WHITE Playfair bold — no
/// gradient fills, no shimmer sweep, no tickers.
void main() {
  group('VDisplayText', () {
    testWidgets('renders the text verbatim — no uppercase forcing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta')),
      );
      expect(find.text('crea tu cuenta'), findsOneWidget);
      expect(find.text('CREA TU CUENTA'), findsNothing);
    });

    testWidgets('keeps mixed case exactly as written', (tester) async {
      await tester.pumpWidget(_wrap(const VDisplayText(text: 'samay')));
      expect(find.text('samay'), findsOneWidget);
    });

    testWidgets('display voice: Playfair bold at the given size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta', size: 40)),
      );
      final style = _displayText(tester).style!;
      expect(style.fontFamily, AppTypography.playfair);
      expect(style.fontSize, AppTypography.displayMedium.fontSize);
      expect(style.fontWeight, FontWeight.w700);
      expect(
        style.fontStyle,
        isNull,
        reason: 'no italics — user directive 2026-08-14',
      );
    });

    testWidgets('glyphs render FLAT WHITE — always', (tester) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta', size: 64)),
      );
      expect(_displayText(tester).style?.color, AppColors.white);
    });

    testWidgets('NO ShaderMask — the gradient fill path is deleted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta')),
      );
      expect(find.byType(ShaderMask), findsNothing);
    });

    testWidgets('NO external glow — the halo stays deleted', (tester) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta')),
      );
      final glow = find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            ((w.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false),
      );
      expect(glow, findsNothing, reason: 'no boxShadow may sit behind glyphs');
    });

    testWidgets('no animation tickers — static render at all times', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VDisplayText(text: 'crea tu cuenta'), reduced: true),
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('textAlign and maxLines pass through to the Text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VDisplayText(
            text: 'una linea de display bastante larga para envolver',
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ),
      );
      final text = _displayText(tester);
      expect(text.textAlign, TextAlign.center);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });
}
