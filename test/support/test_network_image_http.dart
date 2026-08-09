import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/file.dart' show File;
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared HTTP + file-system harness for the VNetworkImage widget tests
/// (extracted from the original single file by EF-04 so the disk-cache test
/// can run in its own isolate without duplicating the mock stack).
///
/// A small [HttpClient] answering per-URL:
/// * `success` URL  — 200 with a 1x1 PNG body
/// * `broken` URL   — 404 (empty body)
/// * `hanging` URL  — 200 with a body that never completes (stays loading)
///
/// The real `CacheManager` pipeline (HTTP fetch → file write → read) runs
/// inside the zone, mirroring flutter_cache_manager's own test setup.

/// 1x1 transparent PNG (standard test payload).
final List<int> kTestTransparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const kTestSuccessUrl = 'https://img.test/success.png';
const kTestBrokenUrl = 'https://img.test/broken.png';
const kTestHangingUrl = 'https://img.test/hanging.png';

/// Runs [body] with a zone-scoped [HttpClient] override so every request
/// (including the ones from `CacheManager` instances created inside the
/// zone) deterministically hits the per-URL test client — never the network
/// and never flutter_test's global 400-mock.
Future<T> inTestNetworkZone<T>(Future<T> Function() body) {
  return HttpOverrides.runZoned(
    body,
    createHttpClient: (_) => TestNetworkHttpClient(),
  );
}

/// In-memory file system (mirrors flutter_cache_manager's own TestFileSystem)
/// so the real cache pipeline runs without path_provider or disk IO.
///
/// Implements flutter_cache_manager's minimal [FileSystem] contract (single
/// `createFile`), NOT package:file's full interface.
/// Each instance gets a fresh temp root — no shared state between tests or
/// cache managers.
class TestNetworkFileSystem implements FileSystem {
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

class TestNetworkHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => TestNetworkHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      TestNetworkHttpRequest(url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async =>
      TestNetworkHttpRequest(Uri.parse('http://$host:$port$path'));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) async =>
      TestNetworkHttpRequest(Uri.parse('http://$host:$port$path'));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestNetworkHttpRequest implements HttpClientRequest {
  final Uri _url;
  final HttpHeaders _headers = TestNetworkHttpHeaders();

  TestNetworkHttpRequest(this._url);

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
      return TestNetworkHttpResponse.notFound();
    }
    if (_url.path.contains('hanging')) {
      return TestNetworkHttpResponse.hanging();
    }
    return TestNetworkHttpResponse.png(kTestTransparentPng);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestNetworkHttpResponse implements HttpClientResponse {
  final int _statusCode;
  final Stream<Uint8List> _body;
  final TestNetworkHttpHeaders _headers = TestNetworkHttpHeaders()
    ..contentType = ContentType('image', 'png');

  TestNetworkHttpResponse._(this._statusCode, this._body);

  factory TestNetworkHttpResponse.png(List<int> bytes) {
    return TestNetworkHttpResponse._(
      HttpStatus.ok,
      Stream<Uint8List>.fromIterable([Uint8List.fromList(bytes)]),
    );
  }

  factory TestNetworkHttpResponse.notFound() {
    return TestNetworkHttpResponse._(
      HttpStatus.notFound,
      const Stream<Uint8List>.empty(),
    );
  }

  factory TestNetworkHttpResponse.hanging() {
    final controller = StreamController<Uint8List>();
    return TestNetworkHttpResponse._(HttpStatus.ok, controller.stream);
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
class TestNetworkHttpHeaders implements HttpHeaders {
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
