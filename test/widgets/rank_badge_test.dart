import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/rank_badge.dart';

Widget _wrap(Widget child) {
  return MaterialApp(home: child);
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

    testWidgets('renders text uppercase', (tester) async {
      await tester.pumpWidget(_wrap(const RankBadge(bracket: 'b90_100')));
      final text = tester.widget<Text>(find.text('FULL VIBE'));
      expect(text.style?.fontSize, 11);
    });
  });
}
