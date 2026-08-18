import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

import '../support/test_network_image_http.dart';

/// Builds a real [CacheManager] inside the [HttpOverrides] zone so the
/// [http.Client] it creates deterministically uses the test HttpClient.
///
/// A FRESH manager with a UNIQUE key per test: flutter_cache_manager keeps a
/// per-instance in-memory cache, so reusing keys across tests would leak
/// cached objects between them (the disk-cache decode case lives in
/// `v_network_image_disk_cache_test.dart` and runs in its own isolate).
CacheManager newCacheManager(String key) {
  return CacheManager(
    Config(
      key,
      repo: NonStoringObjectProvider(),
      fileSystem: TestNetworkFileSystem(),
    ),
  );
}

/// Pumps a [VNetworkImage] under the test [HttpOverrides] zone so the real
/// HTTP + cache pipeline runs deterministically.
Future<void> pumpWithNetwork(
  WidgetTester tester, {
  required String url,
  required String cacheKey,
  Widget Function(CacheManager cacheManager)? builder,
}) async {
  await tester.runAsync(() {
    return inTestNetworkZone(() async {
      final cacheManager = newCacheManager(cacheKey);
      await tester.pumpWidget(
        MaterialApp(
          home: builder != null
              ? builder(cacheManager)
              : VNetworkImage(imageUrl: url, cacheManager: cacheManager),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });
  await tester.pumpAndSettle();
}

/// Recording wrapper around the shared [TestNetworkHttpClient] harness: every
/// request is surfaced with the headers the http layer actually SET on it, so
/// a widget test can assert that the `apikey` key-auth header was (or was not)
/// sent for a storage URL. Everything else (per-URL success/broken/hanging
/// responses) is delegated to the real test client.
class RecordingNetworkHttpClient implements HttpClient {
  final _inner = TestNetworkHttpClient();
  RecordingNetworkHttpRequest? _lastRequest;

  Map<String, List<String>>? get lastCapturedHeaders =>
      _lastRequest?.capturedHeaders;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _record(await _inner.getUrl(url));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _record(await _inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async =>
      _record(await _inner.get(host, port, path));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) async =>
      _record(await _inner.open(method, host, port, path));

  RecordingNetworkHttpRequest _record(HttpClientRequest request) {
    final wrapped = RecordingNetworkHttpRequest(request as TestNetworkHttpRequest);
    _lastRequest = wrapped;
    return wrapped;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class RecordingNetworkHttpRequest implements HttpClientRequest {
  final TestNetworkHttpRequest _inner;
  final RecordingNetworkHttpHeaders _headers;

  RecordingNetworkHttpRequest(this._inner)
      : _headers = RecordingNetworkHttpHeaders(_inner.headers);

  Map<String, List<String>> get capturedHeaders => _headers.captured;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => _inner.uri;

  @override
  String get method => _inner.method;

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<HttpClientResponse> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class RecordingNetworkHttpHeaders implements HttpHeaders {
  final HttpHeaders _inner;
  final Map<String, List<String>> captured = {};

  RecordingNetworkHttpHeaders(this._inner);

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _inner.add(name, value, preserveHeaderCase: preserveHeaderCase);
    captured.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _inner.set(name, value, preserveHeaderCase: preserveHeaderCase);
    captured[name.toLowerCase()] = [value.toString()];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _inner.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Pumps until [condition] holds, giving the real async HTTP/file/decode work
/// inside the [HttpOverrides] zone real time to complete (same approach as the
/// disk-cache test — immune to CI load, never a fixed-sleep race).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('Timed out after $timeout waiting for the image to settle');
}

void main() {
  setUp(() {
    // Hygiene: a previous test's decoded frames must never leak into the
    // next test through the (per-isolate) global ImageCache.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('VNetworkImage', () {
    testWidgets('renders the branded placeholder while the image is loading', (
      tester,
    ) async {
      await pumpWithNetwork(tester, url: kTestHangingUrl, cacheKey: 'k1');

      expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('placeholder uses the surfaceAlt token surface (§5.8)', (
      tester,
    ) async {
      await pumpWithNetwork(tester, url: kTestHangingUrl, cacheKey: 'k2');

      final placeholder = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == AppColors.surfaceAlt,
        ),
      );
      expect(placeholder.color, AppColors.surfaceAlt);
    });

    testWidgets('renders the error widget on HTTP failure without crashing', (
      tester,
    ) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k3');

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.photo_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('error widget uses the border token surface (§5.8)', (
      tester,
    ) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k4');

      final errorSurface = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == AppColors.border,
        ),
      );
      expect(errorSurface.color, AppColors.border);
    });

    testWidgets('passes fit through to CachedNetworkImage', (tester) async {
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k6',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          fit: BoxFit.contain,
          cacheManager: cache,
        ),
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.fit, BoxFit.contain);
    });

    testWidgets('passes width and height through to CachedNetworkImage', (
      tester,
    ) async {
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k7',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          width: 40,
          height: 40,
          cacheManager: cache,
        ),
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.width, 40);
      expect(cached.height, 40);
    });

    testWidgets('passes the imageUrl and cacheManager through', (tester) async {
      late CacheManager usedCache;
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k8',
        builder: (cache) {
          usedCache = cache;
          return VNetworkImage(imageUrl: kTestBrokenUrl, cacheManager: cache);
        },
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.imageUrl, kTestBrokenUrl);
      expect(cached.cacheManager, same(usedCache));
    });

    testWidgets('is sharp by default (no borderRadius → no ClipRRect)', (
      tester,
    ) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k9');

      expect(find.byType(ClipRRect), findsNothing);
    });

    testWidgets('applies borderRadius via ClipRRect', (tester) async {
      const radius = BorderRadius.all(Radius.circular(12));
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k10',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          borderRadius: radius,
          cacheManager: cache,
        ),
      );

      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius, radius);
    });

    testWidgets('fades in on load using the standard duration', (tester) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k11');

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.fadeInDuration, SamayDurations.standard);
    });

    test('is const-constructible with sane defaults', () {
      const widget = VNetworkImage(imageUrl: 'https://img.test/x.png');
      expect(widget.imageUrl, 'https://img.test/x.png');
      expect(widget.fit, BoxFit.cover);
      expect(widget.borderRadius, isNull);
      expect(widget.fadeInDuration, SamayDurations.standard);
    });

    testWidgets(
      'sends the apikey header and renders the image when httpHeaders is provided',
      (tester) async {
        late RecordingNetworkHttpClient recordingClient;
        await tester.runAsync(() {
          return HttpOverrides.runZoned(
            () async {
              final cacheManager = newCacheManager('k12');
              await tester.pumpWidget(
                MaterialApp(
                  home: VNetworkImage(
                    imageUrl: kTestSuccessUrl,
                    cacheManager: cacheManager,
                    httpHeaders: const {'apikey': 'anon-123'},
                  ),
                ),
              );
            },
            createHttpClient: (_) =>
                recordingClient = RecordingNetworkHttpClient(),
          );
        });

        await pumpUntil(tester, () {
          return find.byType(RawImage).evaluate().isNotEmpty;
        });

        expect(recordingClient.lastCapturedHeaders?['apikey'], ['anon-123']);
        expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      },
    );

    testWidgets(
      'adds no apikey header by default for non-storage URLs (empty test key)',
      (tester) async {
        late RecordingNetworkHttpClient recordingClient;
        await tester.runAsync(() {
          return HttpOverrides.runZoned(
            () async {
              final cacheManager = newCacheManager('k13');
              await tester.pumpWidget(
                MaterialApp(
                  home: VNetworkImage(
                    imageUrl: kTestSuccessUrl,
                    cacheManager: cacheManager,
                  ),
                ),
              );
            },
            createHttpClient: (_) =>
                recordingClient = RecordingNetworkHttpClient(),
          );
        });

        await pumpUntil(tester, () {
          return find.byType(RawImage).evaluate().isNotEmpty;
        });

        expect(recordingClient.lastCapturedHeaders?['apikey'], isNull);
        expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      },
    );
  });

  group('storageHeadersFor', () {
    test('adds the apikey header for storage URLs with a non-empty key', () {
      expect(
        VNetworkImage.storageHeadersFor(
          'https://x.example/storage/v1/object/public/groups/a.png',
          'anon-123',
        ),
        {'apikey': 'anon-123'},
      );
    });

    test('returns null for non-storage URLs', () {
      expect(
        VNetworkImage.storageHeadersFor(
          'https://x.example/other/a.png',
          'anon-123',
        ),
        isNull,
      );
    });

    test('returns null when the apiKey is empty', () {
      expect(
        VNetworkImage.storageHeadersFor(
          'https://x.example/storage/v1/object/public/groups/a.png',
          '',
        ),
        isNull,
      );
    });
  });
}
