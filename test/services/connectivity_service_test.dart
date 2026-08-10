import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/connectivity_service.dart';

/// In-memory [ConnectivityPlatform] stand-in (I-67): the REAL default
/// implementation of [ConnectivityService] reaches `connectivity_plus`'s
/// plugin through this platform seam, so the default mapping
/// (`none` → false, everything else → true) is exercised end-to-end without
/// a device or a MethodChannel.
class _FakeConnectivityPlatform extends ConnectivityPlatform {
  _FakeConnectivityPlatform(List<ConnectivityResult> initial)
      : _status = initial;

  final _controller = StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> _status;

  void emit(List<ConnectivityResult> status) {
    _status = status;
    _controller.add(status);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => _status;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;
}

void main() {
  group('default implementation (wraps connectivity_plus)', () {
    late _FakeConnectivityPlatform platform;

    setUp(() {
      platform = _FakeConnectivityPlatform([ConnectivityResult.wifi]);
      ConnectivityPlatform.instance = platform;
    });

    tearDown(() => platform._controller.close());

    test('isConnected() maps [none] to false', () async {
      platform = _FakeConnectivityPlatform([ConnectivityResult.none]);
      ConnectivityPlatform.instance = platform;
      expect(await ConnectivityService().isConnected(), isFalse);
    });

    test('isConnected() maps every non-none interface to true', () async {
      for (final status in [
        [ConnectivityResult.wifi],
        [ConnectivityResult.mobile],
        [ConnectivityResult.ethernet],
        [ConnectivityResult.vpn],
        [ConnectivityResult.bluetooth],
        [ConnectivityResult.satellite],
        [ConnectivityResult.other],
        [ConnectivityResult.wifi, ConnectivityResult.mobile],
      ]) {
        platform = _FakeConnectivityPlatform(status);
        ConnectivityPlatform.instance = platform;
        expect(
          await ConnectivityService().isConnected(),
          isTrue,
          reason: '$status must map to connected',
        );
      }
    });

    test('onConnectivityChanged emits false when the platform reports none',
        () async {
      final service = ConnectivityService();
      final first = service.onConnectivityChanged.first;
      platform.emit([ConnectivityResult.none]);
      expect(await first, isFalse);
    });

    test('onConnectivityChanged emits true when the platform reports wifi',
        () async {
      final service = ConnectivityService();
      final first = service.onConnectivityChanged.first;
      platform.emit([ConnectivityResult.wifi]);
      expect(await first, isTrue);
    });

    test('onConnectivityChanged follows status transitions', () async {
      final service = ConnectivityService();
      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);

      platform.emit([ConnectivityResult.wifi]);
      await pumpEventQueue();
      platform.emit([ConnectivityResult.none]);
      await pumpEventQueue();
      platform.emit([ConnectivityResult.mobile]);
      await pumpEventQueue();

      await sub.cancel();
      expect(events, [true, false, true]);
    });
  });

  group('injectable seam', () {
    test('the stream getter delegates to the injected function', () {
      var calls = 0;
      final service = ConnectivityService(
        onConnectivityChanged: () {
          calls++;
          return const Stream<bool>.empty();
        },
      );
      service.onConnectivityChanged;
      service.onConnectivityChanged;
      expect(calls, 2);
    });

    test('isConnected() delegates to the injected check', () async {
      var called = false;
      final service = ConnectivityService(isConnected: () async {
        called = true;
        return false;
      });
      expect(await service.isConnected(), isFalse);
      expect(called, isTrue);
    });

    test('an injected stream is passed through unmapped', () async {
      final service = ConnectivityService(
        onConnectivityChanged: () => Stream.fromIterable([false, true, true]),
      );
      expect(await service.onConnectivityChanged.toList(), [false, true, true]);
    });
  });
}
