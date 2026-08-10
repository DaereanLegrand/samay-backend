import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/telemetry_service.dart';
import 'package:samay/core/telemetry/route_observer.dart';

/// Recording fake for the [TelemetrySink] seam — asserts exactly what the
/// [RouterObserver] forwards to the telemetry service (I-68).
class _RecordingSink implements TelemetrySink {
  final List<String> events = [];
  final List<Map<String, dynamic>> properties = [];

  @override
  void track(String event, Map<String, dynamic> properties) {
    events.add(event);
    this.properties.add(properties);
  }

  @override
  void identify(String userId) {}

  @override
  void reset() {}
}

/// Enabled telemetry service backed by [sink] (apiKey present) so the
/// observer's reporting path is exercised end-to-end.
TelemetryService _enabledService(_RecordingSink sink) => TelemetryService(
      apiKey: 'phc_test_key',
      host: 'https://posthog.samay.example.com',
      sink: sink,
    );

MaterialPageRoute<void> _route(String? name) => MaterialPageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
      settings: name == null ? const RouteSettings() : RouteSettings(name: name),
    );

void main() {
  group('RouterObserver', () {
    late _RecordingSink sink;
    late RouterObserver observer;

    setUp(() {
      sink = _RecordingSink();
      observer = RouterObserver(_enabledService(sink));
    });

    test('reports screen_view with the route name on didPush', () {
      observer.didPush(_route('/main/feed'), null);
      expect(sink.events, ['screen_view']);
      expect(sink.properties, [
        {'screen': '/main/feed'},
      ]);
    });

    test('reports screen_view on didReplace', () {
      observer.didReplace(newRoute: _route('/main/groups'));
      expect(sink.events, ['screen_view']);
      expect(sink.properties, [
        {'screen': '/main/groups'},
      ]);
    });

    test('ignores didPop — the popped route was already tracked on push', () {
      observer.didPush(_route('/main/feed'), null);
      observer.didPop(_route('/main/feed'), null);
      expect(sink.events, ['screen_view']);
      expect(sink.events.length, 1);
    });

    test('ignores didRemove', () {
      observer.didRemove(_route('/main/feed'), null);
      expect(sink.events, isEmpty);
    });

    test('ignores routes without a name (non-navigation / error pages)', () {
      observer.didPush(_route(null), null);
      observer.didReplace(newRoute: _route(null));
      expect(sink.events, isEmpty);
    });

    test('ignores routes with an empty name', () {
      observer.didPush(_route(''), null);
      expect(sink.events, isEmpty);
    });

    test('does not re-report the same screen twice in a row (go_router '
        'shell + tab pushes the same path on both navigators)', () {
      observer.didPush(_route('/main/profile'), null);
      observer.didPush(_route('/main/profile'), null);
      expect(sink.events, ['screen_view']);
      expect(sink.events.length, 1);
    });

    test('reports a screen again after a different screen in between', () {
      observer.didPush(_route('/main/feed'), null);
      observer.didPush(_route('/main/groups'), null);
      observer.didPush(_route('/main/feed'), null);
      expect(sink.events.length, 3);
      expect(sink.properties.map((p) => p['screen']),
          ['/main/feed', '/main/groups', '/main/feed']);
    });

    test('reports nothing when the telemetry service is disabled '
        '(stub mode — no crash)', () {
      final stubObserver = RouterObserver(TelemetryService());
      stubObserver.didPush(_route('/main/feed'), null);
      stubObserver.didReplace(newRoute: _route('/main/groups'));
      expect(sink.events, isEmpty);
    });
  });
}
