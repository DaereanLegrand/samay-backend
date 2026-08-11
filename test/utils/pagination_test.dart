import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/pagination.dart';

/// Immutable test item: a record with a stable `id` key plus payload.
typedef _Entry = ({String id, int n});

_Entry _e(String id, [int n = 0]) => (id: id, n: n);

String? _idOf(_Entry e) => e.id;

/// Returns no id for entries with the given [skip] id — exercises the
/// "rows without a dedupe key are always kept" contract.
String? Function(_Entry) _idOfSkipping(String skip) =>
    (e) => e.id == skip ? null : e.id;

/// [pages] keyed by the offset the loader requests; rows arrive in the
/// caller's order (the fetch is the feature's seam — chat already reverses
/// DESC server order before the loader sees it).
PageLoader<_Entry> _loader(
  Map<int, List<_Entry>> pages,
  List<int> requested, {
  int pageSize = 3,
  int maxItems = 9,
}) {
  return PageLoader<_Entry>(
    fetch: (offset, limit) async {
      requested.add(offset);
      return pages[offset] ?? const [];
    },
    idOf: _idOf,
    pageSize: pageSize,
    maxItems: maxItems,
  );
}

void main() {
  group('PagedState', () {
    test('holds the immutable fields with the constructor defaults', () {
      final state = const PagedState<int>(items: [1, 2], hasMore: true, pageSize: 50);

      expect(state.items, [1, 2]);
      expect(state.hasMore, isTrue);
      expect(state.loadingMore, isFalse);
      expect(state.pageSize, 50);
      expect(state.nextOffset, 0);
    });

    test('copyWith replaces only the provided fields', () {
      final state = PagedState<_Entry>(
        items: [_e('a')],
        hasMore: true,
        loadingMore: true,
        pageSize: 10,
        nextOffset: 5,
        idOf: _idOf,
      );

      final copied = state.copyWith(items: [_e('b')]);

      expect(copied.items, [_e('b')]);
      expect(copied.hasMore, isTrue);
      expect(copied.loadingMore, isTrue);
      expect(copied.pageSize, 10);
      expect(copied.nextOffset, 5);

      final toggled = state.copyWith(hasMore: false, loadingMore: false);
      expect(toggled.items, [_e('a')]);
      expect(toggled.hasMore, isFalse);
      expect(toggled.loadingMore, isFalse);
    });

    test('append dedupes by id (existing rows win) and preserves order', () {
      final state = PagedState<_Entry>(
        items: [_e('a', 1), _e('b', 2)],
        hasMore: true,
        pageSize: 10,
        idOf: _idOf,
      );

      final out = state.append([_e('c', 3), _e('a', 99), _e('d', 4)]);

      expect(out.items, [_e('a', 1), _e('b', 2), _e('c', 3), _e('d', 4)]);
      // A new list is produced — the state stays immutable.
      expect(out.items, isNot(same(state.items)));
    });

    test('append keeps rows whose id extractor returns null', () {
      final state = PagedState<_Entry>(
        items: [_e('a')],
        hasMore: true,
        pageSize: 10,
        idOf: _idOfSkipping('x'),
      );

      final out = state.append([_e('x', 1), _e('a', 99), _e('x', 2)]);

      // Rows without a key are never deduped; the keyed duplicate is dropped.
      expect(out.items, [_e('a'), _e('x', 1), _e('x', 2)]);
    });

    test('append without an id extractor concatenates raw', () {
      final state = PagedState<_Entry>(
        items: [_e('a')],
        hasMore: true,
        pageSize: 10,
      );

      final out = state.append([_e('a', 99), _e('b')]);

      expect(out.items, [_e('a'), _e('a', 99), _e('b')]);
    });

    test('prepend dedupes against existing rows (existing wins), older first',
        () {
      final state = PagedState<_Entry>(
        items: [_e('m-1'), _e('m-0')],
        hasMore: true,
        pageSize: 10,
        idOf: _idOf,
      );

      final out = state.prepend([_e('m-4'), _e('m-2'), _e('m-1', 99)]);

      expect(out.items, [_e('m-4'), _e('m-2'), _e('m-1'), _e('m-0')]);
      // The page-boundary duplicate resolves to the existing instance.
      expect(out.items.where((e) => e.id == 'm-1'), [_e('m-1')]);
    });

    test('prepend keeps rows whose id extractor returns null', () {
      final state = PagedState<_Entry>(
        items: [_e('a')],
        hasMore: true,
        pageSize: 10,
        idOf: _idOfSkipping('x'),
      );

      final out = state.prepend([_e('x', 7), _e('a', 99)]);

      expect(out.items, [_e('x', 7), _e('a')]);
    });

    test('reset clears items and paging flags, keeping pageSize and the '
        'id extractor', () {
      final state = PagedState<_Entry>(
        items: [_e('a'), _e('b')],
        hasMore: false,
        loadingMore: true,
        pageSize: 25,
        nextOffset: 50,
        idOf: _idOf,
      );

      final reset = state.reset();

      expect(reset.items, isEmpty);
      expect(reset.hasMore, isTrue);
      expect(reset.loadingMore, isFalse);
      expect(reset.nextOffset, 0);
      expect(reset.pageSize, 25);
      // The id extractor survives the reset (dedupe still works against
      // accumulated rows — it never dedupes within one batch).
      final seeded = reset.append([_e('a')]);
      expect(seeded.append([_e('a', 1), _e('b')]).items, [_e('a'), _e('b')]);
    });
  });

  group('PageLoader', () {
    test('loadFirst fetches (0, pageSize) and reports hasMore for a full page',
        () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-2'), _e('m-1'), _e('m-0')],
      }, requested);

      final state = await loader.loadFirst();

      expect(requested, [0]);
      expect(state.items, [_e('m-2'), _e('m-1'), _e('m-0')]);
      expect(state.hasMore, isTrue);
      expect(state.nextOffset, 3);
      expect(state.pageSize, 3);
      expect(state.loadingMore, isFalse);
    });

    test('loadFirst reports hasMore false for a short page', () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-1'), _e('m-0')],
      }, requested);

      final state = await loader.loadFirst();

      expect(state.hasMore, isFalse);
      expect(state.nextOffset, 2);
      expect(requested, [0]);
    });

    test('loadFirst reports hasMore false for an empty page', () async {
      final loader = _loader({}, <int>[]);

      final state = await loader.loadFirst();

      expect(state.items, isEmpty);
      expect(state.hasMore, isFalse);
      expect(state.nextOffset, 0);
    });

    test('loadMore fetches at nextOffset, prepends and advances', () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-2'), _e('m-1'), _e('m-0')],
        3: [_e('m-5'), _e('m-4'), _e('m-3')],
      }, requested);

      final first = await loader.loadFirst();
      final state = await loader.loadMore(first);

      expect(requested, [0, 3]);
      expect(state.items, [
        _e('m-5'),
        _e('m-4'),
        _e('m-3'),
        _e('m-2'),
        _e('m-1'),
        _e('m-0'),
      ]);
      expect(state.hasMore, isTrue);
      expect(state.nextOffset, 6);
      expect(state.loadingMore, isFalse);
    });

    test('loadMore dedupes page-boundary overlaps (existing rows win)',
        () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-2'), _e('m-1'), _e('m-0')],
        3: [_e('m-5'), _e('m-4'), _e('m-2', 99)],
      }, requested);

      final first = await loader.loadFirst();
      final state = await loader.loadMore(first);

      expect(state.items, [
        _e('m-5'),
        _e('m-4'),
        _e('m-2'),
        _e('m-1'),
        _e('m-0'),
      ]);
      expect(state.items.where((e) => e.id == 'm-2'), [_e('m-2')]);
    });

    test('a short page flips hasMore and a later loadMore is a no-op',
        () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-2'), _e('m-1'), _e('m-0')],
        3: [_e('m-3')],
      }, requested);

      final first = await loader.loadFirst();
      final state = await loader.loadMore(first);

      expect(state.items, hasLength(4));
      expect(state.hasMore, isFalse);
      expect(state.nextOffset, 4);

      final again = await loader.loadMore(state);
      expect(again, same(state)); // unchanged instance, no fetch
      expect(requested, [0, 3]);
    });

    test('never fetches at or past the cap (maxItems) and flips hasMore there',
        () async {
      final requested = <int>[];
      final loader = _loader({
        0: [_e('m-2'), _e('m-1'), _e('m-0')],
        3: [_e('m-5'), _e('m-4'), _e('m-3')],
        6: [_e('m-8'), _e('m-7'), _e('m-6')], // must never be requested
      }, requested, maxItems: 6);

      final first = await loader.loadFirst();
      final state = await loader.loadMore(first);

      expect(state.items, hasLength(6));
      expect(state.hasMore, isFalse); // nextOffset 6 == maxItems

      final again = await loader.loadMore(state);
      expect(again, same(state));
      expect(requested, [0, 3]);
    });

    test('loadMore refuses to fetch past the cap even with a stale hasMore',
        () async {
      final requested = <int>[];
      final loader = _loader({}, requested, maxItems: 6);
      final capped = PagedState<_Entry>(
        items: [_e('a'), _e('b'), _e('c'), _e('d'), _e('e'), _e('f')],
        hasMore: true,
        pageSize: 3,
        nextOffset: 6,
        idOf: _idOf,
      );

      final state = await loader.loadMore(capped);

      expect(state.hasMore, isFalse);
      expect(state.items, capped.items);
      expect(requested, isEmpty);
    });

    test('loadMore is a no-op while a page is already in flight', () async {
      final requested = <int>[];
      final loader = _loader({}, requested);
      final loading = PagedState<_Entry>(
        items: [_e('a')],
        hasMore: true,
        loadingMore: true,
        pageSize: 3,
        idOf: _idOf,
      );

      final state = await loader.loadMore(loading);

      expect(state, same(loading));
      expect(requested, isEmpty);
    });

    test('a fetch failure propagates from loadFirst and loadMore', () async {
      var calls = 0;
      final failing = PageLoader<_Entry>(
        fetch: (offset, limit) async {
          calls++;
          throw StateError('fetch failed');
        },
        idOf: _idOf,
        pageSize: 3,
        maxItems: 9,
      );

      await expectLater(failing.loadFirst(), throwsA(isA<StateError>()));
      expect(calls, 1);
    });

    test('a loadMore fetch failure propagates unchanged', () async {
      final loader = PageLoader<_Entry>(
        fetch: (offset, limit) async {
          if (offset == 0) {
            return [_e('m-2'), _e('m-1'), _e('m-0')];
          }
          throw StateError('second page failed');
        },
        idOf: _idOf,
        pageSize: 3,
        maxItems: 9,
      );

      final first = await loader.loadFirst();
      await expectLater(loader.loadMore(first), throwsA(isA<StateError>()));
    });
  });
}
