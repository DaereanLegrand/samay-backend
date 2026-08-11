import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/v_shimmer.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('VShimmerBox', () {
    testWidgets('renders a fixed-size surfaceAlt box with sharp corners '
        '(§5.8/§4.2)', (tester) async {
      await tester.pumpWidget(_wrap(const VShimmerBox(width: 120, height: 24)));
      final box = tester.widget<Container>(find.byType(Container));
      expect(box.color, AppColors.surfaceAlt);
      expect(box.decoration, isNull);
      expect(tester.getSize(find.byType(VShimmerBox)), const Size(120, 24));
    });

    testWidgets('is const-constructible', (tester) async {
      const box = VShimmerBox(width: 48, height: 16);
      expect(box, isA<VShimmerBox>());
    });
  });

  group('VShimmer', () {
    testWidgets('wraps its child in an animated sweep by default (§5.8)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VShimmer(child: VShimmerBox(width: 120, height: 24))),
      );
      expect(find.byType(VShimmerBox), findsOneWidget);
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('disableAnimations → static gray blocks, no sweep and no '
        'ticker (§7.5)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: VShimmer(child: VShimmerBox(width: 120, height: 24)),
            ),
          ),
        ),
      );
      expect(find.byType(VShimmerBox), findsOneWidget);
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('sweep restarts when animations are re-enabled', (
      tester,
    ) async {
      Widget shimmer({required bool reduced}) {
        return MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: const VShimmer(child: VShimmerBox(width: 120, height: 24)),
            ),
          ),
        );
      }

      await tester.pumpWidget(shimmer(reduced: true));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(shimmer(reduced: false));
      await tester.pump();
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('is const-constructible', (tester) async {
      const shimmer = VShimmer(child: VShimmerBox(width: 120, height: 24));
      expect(shimmer, isA<VShimmer>());
    });
  });
}
