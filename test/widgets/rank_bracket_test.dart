import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/rank_bracket.dart';

void main() {
  group('rankBracketLabel', () {
    test('maps every bracket to its Spanish label', () {
      expect(rankBracketLabel('b90_100'), 'Full Vibe');
      expect(rankBracketLabel('b80_90'), 'Leyendas de la Vibra');
      expect(rankBracketLabel('b60_80'), 'Creadores de la Vibra');
      expect(rankBracketLabel('b40_60'), 'Seguidores de la Vibra');
      expect(rankBracketLabel('b20_40'), 'Buscadores de la Vibra');
      expect(rankBracketLabel('b0_20'), 'En la Búsqueda');
    });

    test('falls back to the raw bracket for unknown values', () {
      expect(rankBracketLabel('b99_100'), 'b99_100');
      expect(rankBracketLabel(''), '');
    });
  });

  group('rankBracketForPercentile (mirrors recalculate_ranks CASE)', () {
    test('top bracket from 90 up to 100', () {
      expect(rankBracketForPercentile(90), 'b90_100');
      expect(rankBracketForPercentile(95.5), 'b90_100');
      expect(rankBracketForPercentile(100), 'b90_100');
    });

    test('b80_90 covers [80, 90)', () {
      expect(rankBracketForPercentile(80), 'b80_90');
      expect(rankBracketForPercentile(89.99), 'b80_90');
      expect(rankBracketForPercentile(89.9999), 'b80_90');
    });

    test('b60_80 covers [60, 80)', () {
      expect(rankBracketForPercentile(60), 'b60_80');
      expect(rankBracketForPercentile(79.99), 'b60_80');
    });

    test('b40_60 covers [40, 60)', () {
      expect(rankBracketForPercentile(40), 'b40_60');
      expect(rankBracketForPercentile(59.99), 'b40_60');
    });

    test('b20_40 covers [20, 40)', () {
      expect(rankBracketForPercentile(20), 'b20_40');
      expect(rankBracketForPercentile(39.99), 'b20_40');
    });

    test('b0_20 covers [0, 20)', () {
      expect(rankBracketForPercentile(0), 'b0_20');
      expect(rankBracketForPercentile(19.99), 'b0_20');
      expect(rankBracketForPercentile(19.9999), 'b0_20');
    });

    test('clamps sub-zero values to the bottom bracket', () {
      expect(rankBracketForPercentile(-5), 'b0_20');
    });
  });
}
