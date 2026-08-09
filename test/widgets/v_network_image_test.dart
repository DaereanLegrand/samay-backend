import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' show File;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

/// 1x1 transparent PNG (standard test payload).
const _kTransparentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const _kSuccessUrl = 'https://img.test/success.png';
const _kBrokenUrl = 'https://img.test/broken.png';
const _kHangingUrl = 'https://img.test/hanging.png';

/// Test HttpClient that answers per-URL:
/// * `/success.png` — 200 with a 1x1 PNG body
/// * `/broken.png`  — 404 (empty body)
/// * `/hanging.png` — 200 with a body that never completes (stays loading)
class _TestHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _TestHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _TestHttpRequest(url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async =>
      _TestHttpRequest(Uri.parse('http://$host:$port$path'));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) async =>
      _TestHttpRequest(Uri.parse('http://$host:$port$path'));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestHttpRequest implements HttpClientRequest {
  final Uri _url;
  final HttpHeaders _headers = _TestHttpHeaders();

  _TestHttpRequest(this._url);

  @override
  HttpHeaders get headers => _headers;

  @override
  String get method => 'GET';

  @override
  Uri get uri => _url;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> close() async {
    if (_url.path.contains('broken')) {
      return _TestHttpResponse.notFound();
    }
    if (_url.path.contains('hanging')) {
      return _TestHttpResponse.hanging();
    }
    return _TestHttpResponse.png(base64Decode(_kTransparentPng));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TestHttpResponse implements HttpClientResponse {
  final int _statusCode;
  final Stream<Uint8List> _body;
  final _TestHttpHeaders _headers = _TestHttpHeaders()
    ..contentType = ContentType('image', 'png');

  _TestHttpResponse._(this._statusCode, this._body);

  factory _TestHttpResponse.png(List<int> bytes) {
    return _TestHttpResponse._(
      HttpStatus.ok,
      Stream<Uint8List>.fromIterable([Uint8List.fromList(bytes)]),
    );
  }

  factory _TestHttpResponse.notFound() {
    return _TestHttpResponse._(
      HttpStatus.notFound,
      const Stream<Uint8List>.empty(),
    );
  }

  factory _TestHttpResponse.hanging() {
    final controller = StreamController<Uint8List>();
    return _TestHttpResponse._(HttpStatus.ok, controller.stream);
  }

  @override
  HttpHeaders get headers => _headers;

  @override
  int get statusCode => _statusCode;

  @override
  int get contentLength => -1;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => '';

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [HttpHeaders] (dart:io's is abstract in this SDK) — enough for
/// package:http's IOClient (`set`/`forEach`) and the cache manager's mime
/// handling (`contentType`).
class _TestHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  ContentType? contentType;

  @override
  int contentLength = -1;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// In-memory file system (mirrors flutter_cache_manager's own TestFileSystem)
/// so the real cache pipeline runs without path_provider or disk IO.
class _TestFileSystem implements FileSystem {
  final _root = MemoryFileSystem()
      .systemTempDirectory
      .createTempSync('v_network_image_test');

  @override
  Future<File> createFile(String name) async {
    final directory = _root.childDirectory(name.split('.').first);
    await directory.create(recursive: true);
    return directory.childFile(name);
  }
}

void main() {
  /// Builds a real [CacheManager] inside the [HttpOverrides] zone so the
  /// [http.Client] it creates deterministically uses the test HttpClient.
  CacheManager newCacheManager(String key) {
    return CacheManager(
      Config(
        key,
        repo: NonStoringObjectProvider(),
        fileSystem: _TestFileSystem(),
      ),
    );
  }

  /// Pumps a [VNetworkImage] under the test [HttpOverrides] zone so the real
  /// HTTP + disk-cache pipeline runs deterministically.
  Future<void> pumpWithNetwork(
    WidgetTester tester, {
    required String url,
    required String cacheKey,
    Widget Function(CacheManager cacheManager)? builder,
  }) async {
    await tester.runAsync(() {
      return HttpOverrides.runZoned(
        () async {
          final cacheManager = newCacheManager(cacheKey);
          await tester.pumpWidget(
            MaterialApp(
              home: builder != null
                  ? builder(cacheManager)
                  : VNetworkImage(imageUrl: url, cacheManager: cacheManager),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        createHttpClient: (_) => _TestHttpClient(),
      );
    });
    await tester.pumpAndSettle();
  }

  group('VNetworkImage', () {
    testWidgets('renders the branded placeholder while the image is loading',
        (tester) async {
      await pumpWithNetwork(tester, url: _kHangingUrl, cacheKey: 'k1');

      expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('placeholder uses the grey[900] surface', (tester) async {
      await pumpWithNetwork(tester, url: _kHangingUrl, cacheKey: 'k2');

      final placeholder = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.grey[900],
        ),
      );
      expect(placeholder.color, Colors.grey[900]);
    });

    testWidgets('renders the error widget on HTTP failure without crashing',
        (tester) async {
      await pumpWithNetwork(tester, url: _kBrokenUrl, cacheKey: 'k3');

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.photo_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('error widget uses the grey[800] surface', (tester) async {
      await pumpWithNetwork(tester, url: _kBrokenUrl, cacheKey: 'k4');

      final errorSurface = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.grey[800],
        ),
      );
      expect(errorSurface.color, Colors.grey[800]);
    });

    testWidgets('renders the decoded image on success (disk-cached flow)',
        (tester) async {
      await tester.runAsync(() {
        return HttpOverrides.runZoned(
          () async {
            final cacheManager = newCacheManager('k5');
            await tester.pumpWidget(
              MaterialApp(
                home: VNetworkImage(
                  imageUrl: _kSuccessUrl,
                  cacheManager: cacheManager,
                ),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 400));
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 400));
          },
          createHttpClient: (_) => _TestHttpClient(),
        );
      });
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.photo_outlined), findsNothing);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('passes fit through to CachedNetworkImage', (tester) async {
      await pumpWithNetwork(
        tester,
        url: _kBrokenUrl,
        cacheKey: 'k6',
        builder: (cache) => VNetworkImage(
          imageUrl: _kBrokenUrl,
          fit: BoxFit.contain,
          cacheManager: cache,
        ),
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.fit, BoxFit.contain);
    });

    testWidgets('passes width and height through to CachedNetworkImage',
        (tester) async {
      await pumpWithNetwork(
        tester,
        url: _kBrokenUrl,
        cacheKey: 'k7',
        builder: (cache) => VNetworkImage(
          imageUrl: _kBrokenUrl,
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

    testWidgets('passes the imageUrl and cacheManager through',
        (tester) async {
      late CacheManager usedCache;
      await pumpWithNetwork(
        tester,
        url: _kBrokenUrl,
        cacheKey: 'k8',
        builder: (cache) {
          usedCache = cache;
          return VNetworkImage(
            imageUrl: _kBrokenUrl,
            cacheManager: cache,
          );
        },
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.imageUrl, _kBrokenUrl);
      expect(cached.cacheManager, same(usedCache));
    });

    testWidgets('is sharp by default (no borderRadius → no ClipRRect)',
        (tester) async {
      await pumpWithNetwork(tester, url: _kBrokenUrl, cacheKey: 'k9');

      expect(find.byType(ClipRRect), findsNothing);
    });

    testWidgets('applies borderRadius via ClipRRect', (tester) async {
      const radius = BorderRadius.all(Radius.circular(12));
      await pumpWithNetwork(
        tester,
        url: _kBrokenUrl,
        cacheKey: 'k10',
        builder: (cache) => VNetworkImage(
          imageUrl: _kBrokenUrl,
          borderRadius: radius,
          cacheManager: cache,
        ),
      );

      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius, radius);
    });

    testWidgets('fades in on load using the standard duration', (tester) async {
      await pumpWithNetwork(tester, url: _kBrokenUrl, cacheKey: 'k11');

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
  });
}
