import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/shared/widgets/v_shard_icon.dart';

void main() {
  group('VShardIcon (§5.6)', () {
    testWidgets('renders a diamond in discoGold by default', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VShardIcon()));
      final icon = tester.widget<Icon>(find.byIcon(Icons.diamond));
      expect(icon.color, AppColors.currencyShards);
      expect(icon.color, AppColors.discoGold);
    });

    testWidgets('defaults to the sm (16px) size', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: VShardIcon()));
      final icon = tester.widget<Icon>(find.byIcon(Icons.diamond));
      expect(icon.size, AppIconSizes.sm);
    });

    testWidgets('supports the xs and lg sizes', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(children: [VShardIcon(size: AppIconSizes.xs)]),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.diamond));
      expect(icon.size, AppIconSizes.xs);
    });

    testWidgets('supports the white-only mode via color override', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: VShardIcon(color: AppColors.white)),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.diamond));
      expect(icon.color, AppColors.white);
    });
  });
}
