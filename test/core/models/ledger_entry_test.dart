import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/ledger_entry.dart';

/// LedgerEntry model roundtrip (SLED — I-64): the freezed shape shared by the
/// `shard_ledger` and `preshard_ledger` tables (id, delta, reason,
/// reference_id, created_at) must serialize to/from the exact PostgREST row
/// shape the services await.
const _id = '11111111-1111-1111-1111-111111111111';
const _referenceId = '33333333-3333-3333-3333-333333333333';

Map<String, dynamic> _row({
  String id = _id,
  int delta = 50,
  String reason = 'event_attendance',
  String? referenceId = _referenceId,
  DateTime? createdAt,
}) => {
  'id': id,
  'delta': delta,
  'reason': reason,
  'reference_id': referenceId,
  'created_at': (createdAt ?? DateTime.utc(2026, 8, 1, 21, 30)).toIso8601String(),
};

void main() {
  group('LedgerEntry.fromJson', () {
    test('maps a shard_ledger row (snake_case → camelCase fields)', () {
      final entry = LedgerEntry.fromJson(_row());

      expect(entry.id, _id);
      expect(entry.delta, 50);
      expect(entry.reason, 'event_attendance');
      expect(entry.referenceId, _referenceId);
      expect(entry.createdAt, DateTime.utc(2026, 8, 1, 21, 30));
    });

    test('parses the ISO timestamp into a DateTime', () {
      final entry = LedgerEntry.fromJson(_row());
      expect(entry.createdAt, isA<DateTime>());
      expect(entry.createdAt.isUtc, isTrue);
    });

    test('tolerates a null reference_id', () {
      final entry = LedgerEntry.fromJson(_row(referenceId: null));
      expect(entry.referenceId, isNull);
    });

    test('parses negative deltas (spends)', () {
      final entry = LedgerEntry.fromJson(_row(delta: -50));
      expect(entry.delta, -50);
    });
  });

  group('LedgerEntry.toJson', () {
    test('round-trips back to the exact row shape', () {
      final entry = LedgerEntry.fromJson(_row());
      final json = entry.toJson();

      expect(json['id'], _id);
      expect(json['delta'], 50);
      expect(json['reason'], 'event_attendance');
      expect(json['reference_id'], _referenceId);
      expect(json['created_at'], DateTime.utc(2026, 8, 1, 21, 30).toIso8601String());
      expect(json.containsKey('user_id'), isFalse);
    });
  });

  group('LedgerEntry copyWith', () {
    test('keeps the remaining fields while overriding one', () {
      final base = LedgerEntry.fromJson(_row());
      final negative = base.copyWith(delta: -10, referenceId: null);

      expect(negative.delta, -10);
      expect(negative.referenceId, isNull);
      expect(negative.id, base.id);
      expect(negative.reason, base.reason);
      expect(negative.createdAt, base.createdAt);
    });
  });
}
