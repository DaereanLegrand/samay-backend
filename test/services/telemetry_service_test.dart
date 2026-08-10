import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/telemetry_service.dart';

/// Recording fake for the [TelemetrySink] seam (I-68): asserts the exact
/// events, sanitized properties, and identify/reset calls the service
/// forwards to the (future) posthog_flutter driver.
class _RecordingSink implements TelemetrySink {
  final List<String> trackedEvents = [];
  final List<Map<String, dynamic>> trackedProperties = [];
  final List<String> identifiedUsers = [];
  int resetCalls = 0;

  @override
  void track(String event, Map<String, dynamic> properties) {
    trackedEvents.add(event);
    trackedProperties.add(properties);
  }

  @override
  void identify(String userId) => identifiedUsers.add(userId);

  @override
  void reset() => resetCalls++;
}

void main() {
  group('TelemetryService — disabled stub mode (no POSTHOG_API_KEY)', () {
    late _RecordingSink sink;
    late TelemetryService service;

    setUp(() {
      sink = _RecordingSink();
      service = TelemetryService(sink: sink);
    });

    test('isEnabled is false when no API key define is present', () {
      expect(service.isEnabled, isFalse);
    });

    test('track is a no-op that never touches the sink', () {
      service.track('screen_view', properties: const {'screen': '/welcome'});
      service.track('auth_sign_in');
      expect(sink.trackedEvents, isEmpty);
      expect(sink.trackedProperties, isEmpty);
    });

    test('track with PII-shaped properties does not crash (and is dropped)', () {
      service.track('auth_sign_in', properties: const {
        'email': 'a@b.com',
        'password': 'secret',
      });
      expect(sink.trackedEvents, isEmpty);
    });

    test('identify is a no-op when disabled (null and non-null)', () {
      service.identify('user-1');
      service.identify(null);
      expect(sink.identifiedUsers, isEmpty);
    });

    test('reset is a no-op when disabled', () {
      service.reset();
      expect(sink.resetCalls, 0);
    });
  });

  group('TelemetryService — enabled path (apiKey present)', () {
    late _RecordingSink sink;
    late TelemetryService service;

    setUp(() {
      sink = _RecordingSink();
      service = TelemetryService(
        apiKey: 'phc_test_key',
        host: 'https://posthog.samay.example.com',
        sink: sink,
      );
    });

    test('isEnabled is true when an API key is present', () {
      expect(service.isEnabled, isTrue);
    });

    test('track forwards the event and sanitized properties to the sink',
        () {
      service.track('screen_view', properties: const {'screen': '/feed'});
      expect(sink.trackedEvents, ['screen_view']);
      expect(sink.trackedProperties, [
        {'screen': '/feed'},
      ]);
    });

    test('track with no properties forwards an empty map', () {
      service.track('auth_sign_in');
      expect(sink.trackedEvents, ['auth_sign_in']);
      expect(sink.trackedProperties, [<String, dynamic>{}]);
    });

    test('track strips blocklisted PII keys before forwarding', () {
      service.track('auth_sign_in', properties: const {
        'email': 'a@b.com',
        'password': 'secret1',
        'access_token': 'jwt-abc',
        'phone_number': '+51999000111',
        'screen': '/login',
      });
      final forwarded = sink.trackedProperties.single;
      expect(forwarded, {
        'email': '[redacted]',
        'password': '[redacted]',
        'access_token': '[redacted]',
        'phone_number': '[redacted]',
        'screen': '/login',
      });
    });

    test('identify forwards a non-empty user id to the sink', () {
      service.identify('11111111-1111-1111-1111-111111111111');
      expect(sink.identifiedUsers, ['11111111-1111-1111-1111-111111111111']);
    });

    test('identify with a null or empty user id is a no-op', () {
      service.identify(null);
      service.identify('');
      expect(sink.identifiedUsers, isEmpty);
    });

    test('reset forwards to the sink', () {
      service.reset();
      expect(sink.resetCalls, 1);
    });
  });

  group('TelemetryService — enabled but no sink (SDK wiring pending)', () {
    test('track logs and does not crash', () {
      final service = TelemetryService(apiKey: 'phc_test_key');
      expect(service.isEnabled, isTrue);
      expect(() => service.track('screen_view'), returnsNormally);
    });

    test('identify and reset are silent no-ops without a sink', () {
      final service = TelemetryService(apiKey: 'phc_test_key');
      expect(() => service.identify('user-1'), returnsNormally);
      expect(() => service.reset(), returnsNormally);
    });
  });

  group('sanitizeProperties (pure function)', () {
    test('redacts blocklisted keys case-insensitively', () {
      final result = sanitizeProperties(const {
        'EMAIL': 'a@b.com',
        'Password': 'secret1',
        'Phone': '123',
        'Token': 'abc',
        'safe': 'value',
      });
      expect(result, {
        'EMAIL': '[redacted]',
        'Password': '[redacted]',
        'Phone': '[redacted]',
        'Token': '[redacted]',
        'safe': 'value',
      });
    });

    test('redacts keys that merely contain a blocklisted term', () {
      final result = sanitizeProperties(const {
        'user_email': 'a@b.com',
        'reset_token': 'tok-123',
        'contact_phone': '123',
        'auth_password_hash': 'h',
      });
      expect(result.values.toSet(), {'[redacted]'});
    });

    test('truncates string values longer than 500 characters', () {
      final long = 'x' * 1000;
      final result = sanitizeProperties({'bio': long});
      final value = result['bio']! as String;
      expect(value.length, 501);
      expect(value.startsWith('x' * 500), isTrue);
    });

    test('keeps short strings and non-string values unchanged', () {
      final result = sanitizeProperties(const {
        'screen': '/feed',
        'count': 3,
        'enabled': true,
        'ratio': 1.5,
      });
      expect(result, {
        'screen': '/feed',
        'count': 3,
        'enabled': true,
        'ratio': 1.5,
      });
    });

    test('empty map stays empty', () {
      expect(sanitizeProperties(const {}), isEmpty);
    });

    test('exactly 500 chars is not truncated', () {
      final value = 'a' * 500;
      final result = sanitizeProperties({'note': value});
      expect(result['note'], value);
    });
  });

  test('telemetryServiceProvider resolves to a disabled stub-mode service '
      'in tests (no dart-define)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(telemetryServiceProvider);
    expect(service, isA<TelemetryService>());
    expect(service.isEnabled, isFalse);
  });

  test('AppLogger fallback does not break stub-mode logging', () {
    // The stub path logs through AppLogger.instance (debugPrint fallback in
    // tests) — exercising it here proves the disabled path is crash-safe
    // even when the logger has no storage dir.
    final service = TelemetryService();
    expect(() => service.track('screen_view'), returnsNormally);
  });
}
