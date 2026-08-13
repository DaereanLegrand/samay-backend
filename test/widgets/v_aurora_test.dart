import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_aurora.dart';

/// LUXE v2 ambient-aurora tests (ORCHESTRATION-LUXE.md — owned by XL-04):
/// 2–3 huge radial pastel blobs drifting slowly, reduce-motion → static,
/// on the [VBreathingGlow] idle-safe engine.
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

BoxDecoration _blobDecoration(WidgetTester tester, int index) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byKey(ValueKey('vAuroraBlob$index')),
      matching: find.byType(DecoratedBox),
    ),
  );
  return box.decoration as BoxDecoration;
}

void main() {
  group('VAurora', () {
    testWidgets('renders one drifting blob per gradient — 3 by default '
        '(cyan/violet/mint — no pink mains)', (tester) async {
      await tester.pumpWidget(_wrap(const VAurora()));

      for (var i = 0; i < 3; i++) {
        expect(
          find.byKey(ValueKey('vAuroraBlob$i')),
          findsOneWidget,
          reason: 'the default gradient list yields the $i-th blob',
        );
      }
      expect(find.byKey(const ValueKey('vAuroraBlob3')), findsNothing);
    });

    testWidgets('each blob is a circular radial fill watered to the opacity '
        'prop (α0.10 default)', (tester) async {
      await tester.pumpWidget(_wrap(const VAurora()));

      for (var i = 0; i < 3; i++) {
        final decoration = _blobDecoration(tester, i);
        expect(decoration.shape, BoxShape.circle);
        final radial = decoration.gradient! as RadialGradient;
        expect(
          radial.colors,
          hasLength(AppGradients.cyan.colors.length),
          reason: 'every gradient stop is kept (pastel → vivid)',
        );
        for (final color in radial.colors) {
          expect(color.a, closeTo(0.10, 0.0001),
              reason: 'blobs carry alpha fills only — no shadows');
        }
      }
    });

    testWidgets('custom gradients + opacity drive the blob set', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const VAurora(
            gradients: [AppGradients.cyan, AppGradients.gold],
            opacity: 0.05,
          ),
        ),
      );

      expect(find.byKey(const ValueKey('vAuroraBlob0')), findsOneWidget);
      expect(find.byKey(const ValueKey('vAuroraBlob1')), findsOneWidget);
      expect(find.byKey(const ValueKey('vAuroraBlob2')), findsNothing);
      for (final color in _blobDecoration(tester, 0).gradient!.colors) {
        expect(color.a, closeTo(0.05, 0.0001));
      }
    });

    testWidgets('passes the child through above the aurora layer',
        (tester) async {
      await tester.pumpWidget(
        _wrap(const VAurora(child: Text('over the aurora'))),
      );
      expect(find.text('over the aurora'), findsOneWidget);
    });

    testWidgets('drifts by default: ticker running on mount', (tester) async {
      await tester.pumpWidget(_wrap(const VAurora()));
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the ambient drift is a live animation by default');
    });

    testWidgets('disableAnimations → static positions and no ticker',
        (tester) async {
      await tester.pumpWidget(_wrap(const VAurora(), reduced: true));

      expect(tester.binding.transientCallbackCount, 0,
          reason: 'reduced motion → no drift ticker');
      expect(find.byKey(const ValueKey('vAuroraBlob0')), findsOneWidget);

      await tester.pump(const Duration(seconds: 12));
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byKey(const ValueKey('vAuroraBlob2')), findsOneWidget);
    });

    testWidgets('holds a static pause between orbits so pumpAndSettle tests '
        'land (idle-safe engine)', (tester) async {
      await tester.pumpWidget(_wrap(const VAurora()));

      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0,
          reason: 'the controller settles after one drift orbit');
      expect(find.byKey(const ValueKey('vAuroraBlob0')), findsOneWidget);

      await tester.pump(SamayDurations.motionCycleRest);
      expect(tester.binding.transientCallbackCount, greaterThan(0),
          reason: 'the periodic restart kicks off the next orbit');
    });

    testWidgets('is const-constructible with the spec defaults',
        (tester) async {
      const aurora = VAurora();
      expect(aurora, isA<VAurora>());
      expect(aurora.opacity, 0.10);
      expect(aurora.gradients, hasLength(3));
      expect(aurora.gradients.first, AppGradients.cyan);
    });
  });
}
