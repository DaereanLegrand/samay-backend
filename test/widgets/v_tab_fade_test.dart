import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_tab_fade.dart';

Widget _wrap(Widget child, {bool reduced = false}) {
  return MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: child,
      ),
    ),
  );
}

void main() {
  group('VTabFade (promoted from U-17 _ShellTabFade — R19)', () {
    testWidgets('fades the child in over SamayDurations.fast', (tester) async {
      await tester.pumpWidget(
        _wrap(const VTabFade(child: Text('Tab body'))),
      );

      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(VTabFade),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, lessThan(1.0),
          reason: 'the fade starts from opacity 0');

      await tester.pump(SamayDurations.fast);
      expect(fade.opacity.value, 1.0,
          reason: 'the fade completes at SamayDurations.fast (R19)');
    });

    testWidgets('is static (no ticker) under disableAnimations (§7.5)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const VTabFade(child: Text('Tab body')), reduced: true),
      );
      await tester.pump();

      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no fade ticker');
      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(VTabFade),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, 1.0,
          reason: 'the child renders statically at full opacity');
      expect(find.text('Tab body'), findsOneWidget);
    });

    testWidgets('the child stays mounted after the fade completes',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const VTabFade(child: Text('Tab body'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tab body'), findsOneWidget);
    });

    testWidgets('is const-constructible', (tester) async {
      const fade = VTabFade(child: Text('Tab body'));
      expect(fade, isA<VTabFade>());
    });
  });
}
