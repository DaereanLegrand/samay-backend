import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

void main() {
  group('VCountBadge', () {
    testWidgets('renders nothing for count <= 0 (zero-width box)', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: VCountBadge(count: 0)));
      final box = tester.widget<SizedBox>(find.byType(SizedBox));
      expect(box.width, 0);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('red circle: badgeRed fill, no border, white count text', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: VCountBadge(count: 3)));
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.badgeRed);
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.border, isNull, reason: 'no border ring on the badge');
      final text = tester.widget<Text>(find.text('3'));
      expect(text.style?.color, AppColors.white);
    });

    testWidgets('grows per digit so it stays a true circle', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VCountBadge(count: 123)));
      final container = tester.widget<Container>(find.byType(Container));
      final box = container.constraints as BoxConstraints;
      expect(box.maxWidth, box.maxHeight, reason: 'width == height (circle)');
      expect(box.maxWidth, greaterThan(20), reason: '2 digits grow the badge');
    });

    testWidgets('is const-constructible', (tester) async {
      const badge = VCountBadge(count: 1);
      expect(badge, isA<VCountBadge>());
    });
  });
}
