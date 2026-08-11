import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/rank_badge.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('RankBadge', () {
    testWidgets('displays Full Vibe for b90_100', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b90_100')));
      expect(find.text('FULL VIBE'), findsOneWidget);
    });

    testWidgets('displays Leyendas de la Vibra for b80_90', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b80_90')));
      expect(find.text('LEYENDAS DE LA VIBRA'), findsOneWidget);
    });

    testWidgets('displays Creadores de la Vibra for b60_80', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b60_80')));
      expect(find.text('CREADORES DE LA VIBRA'), findsOneWidget);
    });

    testWidgets('displays Seguidores de la Vibra for b40_60', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b40_60')));
      expect(find.text('SEGUIDORES DE LA VIBRA'), findsOneWidget);
    });

    testWidgets('displays Buscadores de la Vibra for b20_40', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b20_40')));
      expect(find.text('BUSCADORES DE LA VIBRA'), findsOneWidget);
    });

    testWidgets('displays En la Busqueda for b0_20', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b0_20')));
      expect(find.text('EN LA BÚSQUEDA'), findsOneWidget);
    });

    testWidgets('renders text uppercase with the §5.5 11px bold label', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b90_100')));
      final text = tester.widget<Text>(find.text('FULL VIBE'));
      expect(text.style?.fontSize, 11);
      expect(text.style?.fontWeight, FontWeight.bold);
    });

    testWidgets('default fill is border #333333 with a white label (§5.5)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b90_100')));
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.border);
      expect(decoration.border, Border.all(color: AppColors.border));
      final text = tester.widget<Text>(find.text('FULL VIBE'));
      expect(text.style?.color, AppColors.white);
    });

    testWidgets('rank 1 accents the border and label with discoGold (§5.5)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const RankBadge(bracket: 'b90_100', rank: 1)),
      );
      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, AppColors.border);
      expect(decoration.border, Border.all(color: AppColors.discoGold));
      final text = tester.widget<Text>(find.text('FULL VIBE'));
      expect(text.style?.color, AppColors.discoGold);
    });

    testWidgets('rank 2 accents with discoSilver and rank 3 with discoBronze', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const RankBadge(bracket: 'b90_100', rank: 2)),
      );
      var decoration =
          tester.widget<Container>(find.byType(Container)).decoration
              as BoxDecoration;
      expect(decoration.border, Border.all(color: AppColors.discoSilver));

      await tester.pumpWidget(
        _wrap(const RankBadge(bracket: 'b90_100', rank: 3)),
      );
      decoration =
          tester.widget<Container>(find.byType(Container)).decoration
              as BoxDecoration;
      expect(decoration.border, Border.all(color: AppColors.discoBronze));
    });

    testWidgets('ranks outside 1-3 keep the default white label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const RankBadge(bracket: 'b90_100', rank: 5)),
      );
      final text = tester.widget<Text>(find.text('FULL VIBE'));
      expect(text.style?.color, AppColors.white);
    });
  });
}
