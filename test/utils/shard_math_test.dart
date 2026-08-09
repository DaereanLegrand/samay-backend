import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/shard_math.dart';

void main() {
  group('distribute (mirrors distribute_shards SQL)', () {
    test('splits the pool evenly with floor division', () {
      expect(distribute(100, 5), 20);
      expect(distribute(100, 7), 14);
      expect(distribute(5, 3), 1);
      expect(distribute(10, 3), 3);
    });

    test('applies the per-user cap when it binds', () {
      expect(distribute(100, 7, capPerUser: 10), 10);
      expect(distribute(100, 5, capPerUser: 4), 4);
    });

    test('ignores a cap that does not bind', () {
      expect(distribute(100, 7, capPerUser: 99), 14);
      expect(distribute(100, 7, capPerUser: 14), 14);
      expect(distribute(100, 7, capPerUser: 25), 14);
    });

    test('never returns negative or infinite results', () {
      expect(distribute(-10, 5), 0);
      expect(distribute(10, -5), 0);
      expect(distribute(-10, -5), 0);
      expect(distribute(10, 5, capPerUser: -3), 0);
    });

    test('returns 0 for empty pools or audiences', () {
      expect(distribute(0, 5), 0);
      expect(distribute(100, 0), 0);
      expect(distribute(0, 0), 0);
      expect(distribute(1, 10), 0);
    });
  });

  group('totalActive', () {
    test('sums current and delta', () {
      expect(totalActive(10, -3), 7);
      expect(totalActive(10, 3), 13);
      expect(totalActive(0, 0), 0);
    });

    test('clamps at zero — balances never go negative', () {
      expect(totalActive(10, -15), 0);
      expect(totalActive(0, -1), 0);
      expect(totalActive(-5, 3), 0);
    });
  });

  group('aggregateContributions', () {
    test('returns an empty list for no rows', () {
      expect(aggregateContributions(const []), isEmpty);
    });

    test('sums shards_contributed per user_id', () {
      final rows = [
        {'user_id': 'u1', 'shards_contributed': 10},
        {'user_id': 'u2', 'shards_contributed': 20},
        {'user_id': 'u1', 'shards_contributed': 5},
      ];
      final result = aggregateContributions(rows);
      expect(result, hasLength(2));
      final byId = {for (final r in result) r['user_id']: r};
      expect(byId['u1']!['shards_contributed'], 15);
      expect(byId['u2']!['shards_contributed'], 20);
    });

    test('sorts contributors descending by shards_contributed', () {
      final rows = [
        {'user_id': 'u1', 'shards_contributed': 10},
        {'user_id': 'u2', 'shards_contributed': 50},
        {'user_id': 'u3', 'shards_contributed': 30},
      ];
      final result = aggregateContributions(rows);
      expect(
        result.map((r) => r['shards_contributed']).toList(),
        [50, 30, 10],
      );
    });

    test('keeps the other fields of the first row for a user', () {
      final rows = [
        {
          'user_id': 'u1',
          'shards_contributed': 10,
          'users': {'username': 'ana'},
        },
        {'user_id': 'u1', 'shards_contributed': 5},
      ];
      final result = aggregateContributions(rows);
      expect(result, hasLength(1));
      expect((result.single['users'] as Map)['username'], 'ana');
      expect(result.single['shards_contributed'], 15);
    });

    test('does not mutate the input rows', () {
      final rows = [
        {'user_id': 'u1', 'shards_contributed': 10},
        {'user_id': 'u1', 'shards_contributed': 5},
      ];
      aggregateContributions(rows);
      expect(rows, hasLength(2));
      expect(rows[0]['shards_contributed'], 10);
      expect(rows[1]['shards_contributed'], 5);
    });
  });
}
