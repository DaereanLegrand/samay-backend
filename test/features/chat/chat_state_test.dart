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

  group('ChatMessagesState group read receipts (20260817000006)', () {
    Map<String, dynamic> readRow(
      String messageId,
      List<Map<String, dynamic>> reads,
    ) => {
      ..._row(messageId),
      'message_reads': reads,
    };

    test('readersOf returns the embedded read set (empty when absent)', () {
      expect(ChatMessagesState.readersOf(_row('m-1')), isEmpty);
      expect(
        ChatMessagesState.readersOf(readRow('m-1', [
          {'user_id': 'bob', 'read_at': '2026-08-01T00:05:00Z'},
        ])),
        hasLength(1),
      );
    });

    test('isReadByAll requires EVERY other member — never just the first '
        'reader (the ISSUE fix: one reader must not fake blue checks)', () {
      final row = readRow('m-1', [
        {'user_id': 'bob', 'read_at': '2026-08-01T00:05:00Z'},
      ]);
      expect(ChatMessagesState.isReadByAll(row, {'bob', 'carol'}), isFalse,
          reason: '1 of 2 other members read → grey');
      expect(ChatMessagesState.isReadByAll(row, {'bob'}), isTrue,
          reason: '1 of 1 (only one other member) → blue');
      expect(ChatMessagesState.isReadByAll(row, <String>{}), isFalse,
          reason: 'unknown/empty roster is conservative — never blue');
      expect(ChatMessagesState.isReadByAll(_row('m-1'), {'bob'}), isFalse,
          reason: 'no readers at all → grey');
    });

    test('isReadByAll dedupes readers (a reader is counted once)', () {
      final row = readRow('m-1', [
        {'user_id': 'bob', 'read_at': '2026-08-01T00:05:00Z'},
        {'user_id': 'bob', 'read_at': '2026-08-01T00:06:00Z'},
      ]);
      expect(ChatMessagesState.isReadByAll(row, {'bob', 'carol'}), isFalse,
          reason: 'duplicate receipts for one reader must not count as two');
      expect(ChatMessagesState.isReadByAll(row, {'bob'}), isTrue);
    });

    test('isReadByAll ignores a DEPARTED member\'s stale receipt — the '
        'current roster is the authority (verifier fix 2026-08-17: a leaver '
        'who read before leaving must not fake read-by-everyone)', () {
      // bob read then LEFT; the current other members are carol + dave —
      // neither has read → grey, even though a reader count (1 of 2) or a
      // stale-id count (bob + none) would false-blue.
      final row = readRow('m-1', [
        {'user_id': 'bob', 'read_at': '2026-08-01T00:05:00Z'},
      ]);
      expect(ChatMessagesState.isReadByAll(row, {'carol', 'dave'}), isFalse,
          reason: 'a leaver\'s receipt is not a current member\'s read');
      expect(ChatMessagesState.isReadByAll(row, {'bob', 'carol'}), isFalse,
          reason: 'a leaver\'s id in the roster set must not count either');
    });

    test('markMessageRead merges one reader into the matching row; no-op for '
        'an unknown id; dedupes an existing reader', () {
      final state = _state([
        readRow('m-1', []),
        readRow('m-2', []),
      ]).markMessageRead('m-1', 'bob', DateTime.utc(2026, 8, 1, 0, 5));

      final m1 = state.messages.firstWhere((r) => r['id'] == 'm-1');
      final m2 = state.messages.firstWhere((r) => r['id'] == 'm-2');
      expect(ChatMessagesState.readersOf(m1).single['user_id'], 'bob');
      expect(ChatMessagesState.readersOf(m2), isEmpty);

      final merged = state.markMessageRead(
        'm-1',
        'bob',
        DateTime.utc(2026, 8, 1, 0, 6),
      );
      final m1b = merged.messages.firstWhere((r) => r['id'] == 'm-1');
      expect(ChatMessagesState.readersOf(m1b), hasLength(1),
          reason: 'a second receipt from the same reader is a no-op');

      final ghost = state.markMessageRead(
        'ghost',
        'bob',
        DateTime.utc(2026, 8, 1, 0, 7),
      );
      expect(ghost.messages, hasLength(2));
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
