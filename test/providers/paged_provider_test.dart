import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/paged_provider.dart';
import 'package:samay/core/utils/pagination.dart';

/// Pages keyed by the requested offset (3-item pages) — mirrors the chat
/// service contract (offset windows, oldest-first page order).
Map<int, List<String>> _pages = {};

/// Every offset the fake fetch was asked for, in call order.
final List<int> _requestedOffsets = [];

/// Offsets whose fetch must fail with a [StateError].
Set<int> _failOffsets = {};

/// When set, non-first-page fetches wait for it (in-flight tests).
Completer<void>? _gate;

int _pageSize = 3;
int _maxItems = 9;

Future<List<String>> _fakeFetch(int offset, int limit) async {
  _requestedOffsets.add(offset);
  if (offset != 0) {
    final gate = _gate;
    if (gate != null) await gate.future;
  }
  if (_failOffsets.contains(offset)) {
    throw StateError('fetch failed at offset $offset');
  }
  return _pages[offset] ?? const [];
}

class _FakePagedNotifier extends PagedProvider<String> {
  @override
  PageLoader<String> createLoader() => PageLoader<String>(
        fetch: _fakeFetch,
        idOf: (id) => id,
        pageSize: _pageSize,
        maxItems: _maxItems,
      );
}

final _pagedProvider = AsyncNotifierProvider<_FakePagedNotifier,
    PagedState<String>>(_FakePagedNotifier.new);

void main() {
  setUp(() {
    _pages = {};
    _requestedOffsets.clear();
    _failOffsets = <int>{};
    _gate = null;
    _pageSize = 3;
    _maxItems = 9;
  });

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('PagedProvider — build (loadFirst)', () {
    test('loads the first page with hasMore when it is full', () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
      };
      final c = container();

      final state = await c.read(_pagedProvider.future);

      expect(state.items, ['a', 'b', 'c']);
      expect(state.hasMore, isTrue);
      expect(state.loadingMore, isFalse);
      expect(_requestedOffsets, [0]);
    });

    test('a short first page flips hasMore to false', () async {
      _pages = {
        0: ['a', 'b'],
      };
      final c = container();

      final state = await c.read(_pagedProvider.future);

      expect(state.items, ['a', 'b']);
      expect(state.hasMore, isFalse);
    });

    test('a fetch failure during build surfaces as AsyncError', () async {
      _failOffsets = {0};
      final c = container();

      await expectLater(c.read(_pagedProvider.future), throwsA(isA<StateError>()));
      expect(c.read(_pagedProvider).hasError, isTrue);
    });
  });

  group('PagedProvider — loadOlder', () {
    test('prepends the next page and advances the offset', () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
        6: ['g', 'h', 'i'],
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      await notifier.loadOlder();
      var state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, ['d', 'e', 'f', 'a', 'b', 'c']);
      expect(state.nextOffset, 6);
      expect(state.hasMore, isTrue);

      await notifier.loadOlder();
      state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, ['g', 'h', 'i', 'd', 'e', 'f', 'a', 'b', 'c']);
      expect(state.hasMore, isFalse); // nextOffset 9 == maxItems 9
      expect(_requestedOffsets, [0, 3, 6]);
    });

    test('a short page flips hasMore and further calls are no-ops', () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d'],
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      await notifier.loadOlder();
      var state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, hasLength(4));
      expect(state.hasMore, isFalse);

      await notifier.loadOlder(); // must be a no-op
      state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, hasLength(4));
      expect(_requestedOffsets, [0, 3]);
    });

    test('never paginates past the cap (maxItems)', () async {
      _maxItems = 6;
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
        6: ['x', 'y', 'z'], // must never be requested
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      await notifier.loadOlder();
      var state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, hasLength(6));
      expect(state.hasMore, isFalse);

      await notifier.loadOlder();
      state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, hasLength(6));
      expect(_requestedOffsets, [0, 3]);
    });

    test('exposes loadingMore while a page is in flight', () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      _gate = Completer<void>();
      final pending = notifier.loadOlder();
      final during = c.read(_pagedProvider).valueOrNull!;
      expect(during.loadingMore, isTrue);

      _gate!.complete();
      await pending;
      final after = c.read(_pagedProvider).valueOrNull!;
      expect(after.loadingMore, isFalse);
      expect(after.items, hasLength(6));
    });

    test('concurrent loadOlder calls are serialized (no duplicate fetches)',
        () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      await Future.wait([notifier.loadOlder(), notifier.loadOlder()]);

      expect(_requestedOffsets, [0, 3]); // the second call was a no-op
      final state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, hasLength(6));
    });

    test('a loadOlder failure keeps the previous state and rethrows',
        () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
      };
      _failOffsets = {3};
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);

      await expectLater(notifier.loadOlder(), throwsA(isA<StateError>()));

      final state = c.read(_pagedProvider).valueOrNull!;
      expect(state.items, ['a', 'b', 'c']); // untouched
      expect(state.loadingMore, isFalse); // flag cleared
      expect(_requestedOffsets, [0, 3]);
    });
  });

  group('PagedProvider — refresh', () {
    test('re-runs build from the first page (SM-09 contract)', () async {
      _pages = {
        0: ['a', 'b', 'c'],
        3: ['d', 'e', 'f'],
      };
      final c = container();
      await c.read(_pagedProvider.future);
      final notifier = c.read(_pagedProvider.notifier);
      await notifier.loadOlder();
      expect(_requestedOffsets, [0, 3]);

      await notifier.refresh();

      final state = await c.read(_pagedProvider.future);
      expect(state.items, ['a', 'b', 'c']); // back to the first page
      expect(state.nextOffset, 3);
      expect(_requestedOffsets, [0, 3, 0]);
    });
  });
}
