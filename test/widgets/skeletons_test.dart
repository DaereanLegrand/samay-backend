import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/v_shimmer.dart';

/// Skeleton screen tests (U-22, DISCO-DESIGN-SYSTEM §5.8/§6.3/§7.5):
/// every skeleton is a const-constructible `VShimmer` composition of
/// `surfaceAlt #111111` sharp-corner boxes (no color, gray only), static
/// gray blocks under `disableAnimations` (no mask, no ticker).
///
/// NOTE: skeletons animate forever, so these tests pump explicitly — never
/// `pumpAndSettle` while a skeleton is mounted (the sweep would hang it).
Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

/// The circular avatar block a skeleton row/profile renders (the real
/// `ProfileAvatar` is a circle, so the skeleton mimics the shape — the
/// "sharp corners" §4.2 rule governs *blocks*, §5.8 lists no circle ban).
Finder _circle() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      (w.decoration as BoxDecoration?)?.shape == BoxShape.circle,
);

void main() {
  group('VSkeletonList (avatar + 2 lines, hairline-bordered rows)', () {
    testWidgets('renders N rows of 2 line boxes over a shimmer sweep (§5.8)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonList(rows: 4)));
      expect(
        find.byType(VShimmerBox),
        findsNWidgets(8),
        reason: '2 lines per row × 4 rows',
      );
      expect(
        find.byType(ShaderMask),
        findsOneWidget,
        reason: 'the sweep is on by default',
      );
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('rows are separated by 1px hairline dividers', (tester) async {
      await tester.pumpWidget(_wrap(const VSkeletonList(rows: 4)));
      final dividers = tester
          .widgetList<Divider>(find.byType(Divider))
          .toList();
      expect(dividers, hasLength(3), reason: '4 rows → 3 hairline gaps');
      for (final d in dividers) {
        expect(
          d.color,
          AppColors.hairline,
          reason: 'the §2.1 hairline token separates rows',
        );
        expect(d.thickness, 1);
      }
    });

    testWidgets('renders a circular surfaceAlt avatar block per row', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonList(rows: 2)));
      final circles = tester.widgetList<Container>(_circle()).toList();
      expect(circles, hasLength(2));
      for (final c in circles) {
        expect(
          (c.decoration as BoxDecoration).color,
          AppColors.surfaceAlt,
          reason: '§5.8 skeleton base',
        );
        expect(
          tester.getSize(find.byWidget(c)),
          const Size(40, 40),
          reason: 'the avatar circle lays out at AppSpacing.avatar',
        );
      }
    });

    testWidgets('static gray blocks under disableAnimations (§7.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: VSkeletonList(rows: 3),
            ),
          ),
        ),
      );
      expect(find.byType(VShimmerBox), findsNWidgets(6));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    test('is const-constructible', () {
      const list = VSkeletonList(rows: 2);
      expect(list, isA<VSkeletonList>());
      expect(list.rows, 2);
    });
  });

  group('VSkeletonGrid (N shimmer cards)', () {
    testWidgets('renders rows×columns cards of 3 boxes each', (tester) async {
      await tester.pumpWidget(_wrap(const VSkeletonGrid(rows: 2, columns: 3)));
      expect(
        find.byType(VShimmerBox),
        findsNWidgets(18),
        reason: 'cover + 2 lines per card × 6 cards',
      );
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('cards carry the §5.3 surface fill + hairline border', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonGrid(rows: 1, columns: 1)));
      final card = tester.widget<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.border != null,
        ),
      );
      final deco = card.decoration as BoxDecoration;
      expect(
        deco.color,
        AppColors.surface,
        reason: 'card fill mirrors VCard (§5.3)',
      );
      expect(
        (deco.border as Border).top.color,
        AppColors.hairline,
        reason: 'the §2.1 hairline outline',
      );
      expect(
        tester.getSize(find.byType(VShimmerBox).first).height,
        96,
        reason: 'the card cover block',
      );
    });

    testWidgets('static gray blocks under disableAnimations (§7.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: VSkeletonGrid(rows: 2, columns: 2),
            ),
          ),
        ),
      );
      expect(find.byType(VShimmerBox), findsNWidgets(12));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    test('is const-constructible', () {
      const grid = VSkeletonGrid(rows: 3, columns: 2);
      expect(grid, isA<VSkeletonGrid>());
      expect(grid.rows, 3);
      expect(grid.columns, 2);
    });
  });

  group('VSkeletonProfile (avatar + lines)', () {
    testWidgets('renders an avatarLarge circle plus 5 line boxes', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonProfile()));
      final circle = tester.widget<Container>(_circle());
      expect((circle.decoration as BoxDecoration).color, AppColors.surfaceAlt);
      expect(
        tester.getSize(_circle()),
        const Size(80, 80),
        reason: 'the hero avatar circle lays out at AppSpacing.avatarLarge',
      );
      expect(
        find.byType(VShimmerBox),
        findsNWidgets(4),
        reason: 'name + handle + 2 body lines',
      );
      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets('static gray blocks under disableAnimations (§7.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: VSkeletonProfile(),
            ),
          ),
        ),
      );
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    test('is const-constructible', () {
      const profile = VSkeletonProfile();
      expect(profile, isA<VSkeletonProfile>());
    });
  });

  group('VSkeletonDetail (cover + lines — feed event-card shape)', () {
    testWidgets('renders N cover+3-line cards over a shimmer sweep', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonDetail(rows: 3)));
      expect(
        find.byType(VShimmerBox),
        findsNWidgets(12),
        reason: 'cover + title + date + location per row × 3',
      );
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      final cover = tester.getSize(find.byType(VShimmerBox).first);
      expect(
        cover.height,
        140,
        reason: 'matches the feed _EventCard cover height',
      );
    });

    testWidgets('cards carry the §5.3 surface fill + hairline borders', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const VSkeletonDetail(rows: 1)));
      final card = tester.widget<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.border != null,
        ),
      );
      final deco = card.decoration as BoxDecoration;
      expect(deco.color, AppColors.surface);
      expect((deco.border as Border).top.color, AppColors.hairline);
      expect((deco.border as Border).bottom.color, AppColors.hairline);
    });

    testWidgets('static gray blocks under disableAnimations (§7.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: VSkeletonDetail(rows: 2),
            ),
          ),
        ),
      );
      expect(find.byType(VShimmerBox), findsNWidgets(8));
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    test('is const-constructible', () {
      const detail = VSkeletonDetail(rows: 2);
      expect(detail, isA<VSkeletonDetail>());
      expect(detail.rows, 2);
    });
  });
}
