import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/pagination.dart';
import 'package:samay/features/chat/providers/chat_providers.dart';

/// Thread-state ordering + read-receipt merge behavior (2026-08-15 UI
/// overhaul): deterministic (created_at, id) display order, sorted realtime
/// inserts, pending-row lifecycle and the `read_at` flip.
Map<String, dynamic> _row(
  String id, {
  String createdAt = '2026-08-01T00:00:00Z',
  bool pending = false,
  String sender = 'peer',
}) => {
  'id': id,
  'sender_id': sender,
  'content': 'contenido $id',
  'media_url': null,
  'created_at': createdAt,
  if (pending) 'pending': true,
};

ChatMessagesState _state(List<Map<String, dynamic>> rows, {bool hasMore = true}) =>
    ChatMessagesState(messages: rows, hasMore: hasMore);

void main() {
  group('ChatMessagesState ordering', () {
    test('compareRows orders by created_at then id (deterministic ties)', () {
      final sorted = ChatMessagesState.sortRows([
        _row('b', createdAt: '2026-08-01T00:00:02Z'),
        _row('a', createdAt: '2026-08-01T00:00:00Z'),
        // equal timestamps → id tie-break
        _row('y', createdAt: '2026-08-01T00:00:01Z'),
        _row('x', createdAt: '2026-08-01T00:00:01Z'),
      ]);
      expect(sorted.map((r) => r['id']).toList(), ['a', 'x', 'y', 'b']);
    });

    test('fromPaged re-sorts merged pages into thread order', () {
      final state = ChatMessagesState.fromPaged(
        PagedState<Map<String, dynamic>>(
          items: [_row('m-2'), _row('m-1')],
          hasMore: false,
          pageSize: chatPageSize,
        ),
      );
      expect(state.messages.map((r) => r['id']).toList(), ['m-1', 'm-2']);
    });
  });

  group('ChatMessagesState.insertMessage (realtime)', () {
    test('inserts a late-delivered OLDER row at its sorted position', () {
      final state = _state([
        _row('newest', createdAt: '2026-08-01T00:00:02Z'),
        _row('newer', createdAt: '2026-08-01T00:00:01Z'),
      ]).insertMessage(_row('oldest', createdAt: '2026-08-01T00:00:00Z'));

      expect(state.messages.map((r) => r['id']).toList(), [
        'oldest',
        'newer',
        'newest',
      ]);
    });

    test('drops a pending row of the same sender when the server row arrives',
        () {
      final state = _state([
        _row('m-1'),
        _row('pending-1', pending: true, sender: 'me'),
      ]).insertMessage(_row('m-2', sender: 'me'));

      expect(state.messages.map((r) => r['id']).toList(), ['m-1', 'm-2']);
      expect(state.messages.any((r) => r['pending'] == true), isFalse);
    });

    test('keeps a pending row when a PEER row arrives', () {
      final state = _state([
        _row('pending-1', pending: true, sender: 'me'),
      ]).insertMessage(_row('peer-msg'));

      expect(state.messages.map((r) => r['id']).toList(), [
        // equal timestamps → deterministic id tie-break ('peer-msg' < 'pending-1')
        'peer-msg',
        'pending-1',
      ]);
    });
  });

  group('ChatMessagesState read receipts', () {
    test('markRead stamps read_at on the matching message only', () {
      final state = _state([
        _row('m-1'),
        _row('m-2'),
      ]).markRead('m-1', DateTime.utc(2026, 8, 1, 0, 5));

      final m1 = state.messages.firstWhere((r) => r['id'] == 'm-1');
      final m2 = state.messages.firstWhere((r) => r['id'] == 'm-2');
      expect(m1['read_at'], '2026-08-01T00:05:00.000Z');
      expect(m2['read_at'], isNull);
    });

    test('markRead is a no-op for an unknown id', () {
      final state = _state([_row('m-1')]).markRead('ghost', DateTime.utc(2026));
      expect(state.messages.single['read_at'], isNull);
    });
  });

  group('ChatMessagesState pending lifecycle', () {
    test('removeMessage deletes only the pending id', () {
      final state = _state([
        _row('m-1'),
        _row('pending-1', pending: true, sender: 'me'),
      ]).removeMessage('pending-1');

      expect(state.messages.map((r) => r['id']).toList(), ['m-1']);
    });
  });
}
