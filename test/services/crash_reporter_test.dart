import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/crash_reporter.dart';
import 'package:samay/main.dart' as main_lib;

/// Recording fake for the [CrashSink] seam (I-70): asserts the exact
/// error/stack/context triples, the scrubbed user ids, and the breadcrumbs
/// the service forwards to the (future) sentry_flutter driver.
class _RecordingSink implements CrashSink {
  final List<Object> errors = [];
  final List<StackTrace> stacks = [];
  final List<Map<String, String>?> contexts = [];
  final List<String> users = [];
  final List<String> breadcrumbs = [];

  @override
  Future<void> reportError(
    Object error,
    StackTrace stack, {
    Map<String, String>? context,
  }) async {
    errors.add(error);
    stacks.add(stack);
    contexts.add(context);
  }

  @override
  void setUser(String userId) => users.add(userId);

  @override
  void addBreadcrumb(String message) => breadcrumbs.add(message);
}

const _testDsn = 'https://public@sentry.example.com/1';

void main() {
  group('CrashReporter — stub mode (no SENTRY_DSN define)', () {
    late _RecordingSink sink;
    late CrashReporter reporter;

    setUp(() {
      sink = _RecordingSink();
      reporter = CrashReporter(sink: sink);
    });

    test('isEnabled is false when no DSN define is present', () {
      expect(reporter.isEnabled, isFalse);
    });

    test('reportError is a no-op that never touches the sink', () async {
      await reporter.reportError(Exception('boom'), StackTrace.current);
      expect(sink.errors, isEmpty);
      expect(sink.stacks, isEmpty);
      expect(sink.contexts, isEmpty);
    });

    test('reportError with a context map still drops everything', () async {
      await reporter.reportError(
        Exception('boom'),
        StackTrace.current,
        context: const {'screen': '/feed'},
      );
      expect(sink.errors, isEmpty);
    });

    test('setUser is a no-op when disabled (null and non-null)', () async {
      await reporter.setUser('11111111-1111-1111-1111-111111111111');
      await reporter.setUser(null);
      expect(sink.users, isEmpty);
    });

    test('addBreadcrumb is a no-op when disabled', () {
      reporter.addBreadcrumb('screen_view');
      expect(sink.breadcrumbs, isEmpty);
    });
  });

  group('CrashReporter — enabled path (dsn present + injected sink)', () {
    late _RecordingSink sink;
    late CrashReporter reporter;

    setUp(() {
      sink = _RecordingSink();
      reporter = CrashReporter(dsn: _testDsn, sink: sink);
    });

    test('isEnabled is true when a DSN is present', () {
      expect(reporter.isEnabled, isTrue);
    });

    test('reportError forwards the error, stack and context to the sink',
        () async {
      final error = StateError('boom');
      final stack = StackTrace.current;
      await reporter.reportError(
        error,
        stack,
        context: const {'screen': '/feed'},
      );
      expect(sink.errors, [error]);
      expect(sink.stacks, [stack]);
      expect(sink.contexts, [
        {'screen': '/feed'},
      ]);
    });

    test('reportError with no context forwards a null context', () async {
      await reporter.reportError(Exception('boom'), StackTrace.current);
      expect(sink.contexts, [null]);
    });

    test('reportError never throws when the sink throws', () async {
      final throwing = CrashReporter(
        dsn: _testDsn,
        sink: _ThrowingSink(),
      );
      await expectLater(
        throwing.reportError(Exception('boom'), StackTrace.current),
        completes,
      );
    });

    test('setUser scrubs the id — the sink receives a SHA-256 hex hash, '
        'never the raw value', () async {
      const userId = '11111111-1111-1111-1111-111111111111';
      await reporter.setUser(userId);
      expect(sink.users, hasLength(1));
      final scrubbed = sink.users.single;
      expect(scrubbed, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(scrubbed, isNot(userId));
    });

    test('setUser is deterministic for the same user id', () async {
      const userId = '11111111-1111-1111-1111-111111111111';
      await reporter.setUser(userId);
      await reporter.setUser(userId);
      expect(sink.users[0], sink.users[1]);
    });

    test('setUser with a null or empty user id is a no-op', () async {
      await reporter.setUser(null);
      await reporter.setUser('');
      expect(sink.users, isEmpty);
    });

    test('addBreadcrumb appends to the sink', () {
      reporter.addBreadcrumb('screen_view');
      reporter.addBreadcrumb('auth_sign_in');
      expect(sink.breadcrumbs, ['screen_view', 'auth_sign_in']);
    });
  });

  group('CrashReporter — enabled but no sink (SDK wiring pending)', () {
    test('reportError logs and completes without crashing', () async {
      final reporter = CrashReporter(dsn: _testDsn);
      expect(reporter.isEnabled, isTrue);
      await expectLater(
        reporter.reportError(Exception('boom'), StackTrace.current),
        completes,
      );
    });

    test('setUser and addBreadcrumb are silent no-ops without a sink',
        () async {
      final reporter = CrashReporter(dsn: _testDsn);
      await expectLater(
        reporter.setUser('11111111-1111-1111-1111-111111111111'),
        completes,
      );
      expect(() => reporter.addBreadcrumb('screen_view'), returnsNormally);
    });
  });

  group('hashUserId (pure scrub)', () {
    test('produces 64 lowercase hex characters', () async {
      final hash =
          await hashUserId('11111111-1111-1111-1111-111111111111');
      expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('is deterministic', () async {
      const id = '22222222-2222-2222-2222-222222222222';
      expect(await hashUserId(id), await hashUserId(id));
    });

    test('differs across different user ids', () async {
      final a = await hashUserId('11111111-1111-1111-1111-111111111111');
      final b = await hashUserId('22222222-2222-2222-2222-222222222222');
      expect(a, isNot(b));
    });

    test('never equals the input — an email-shaped id stays unrecoverable',
        () async {
      const email = 'user@example.com';
      final hash = await hashUserId(email);
      expect(hash, isNot(email));
      expect(hash.contains('user@example'), isFalse);
    });
  });

  test('crashReporterProvider resolves to a disabled stub-mode reporter in '
      'tests (no dart-define)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final reporter = container.read(crashReporterProvider);
    expect(reporter, isA<CrashReporter>());
    expect(reporter.isEnabled, isFalse);
  });

  group('main.dart global-handler wiring (via the extracted handlers)', () {
    test('handleFlutterError reports a real error after the benign filter',
        () async {
      final sink = _RecordingSink();
      final reporter = CrashReporter(dsn: _testDsn, sink: sink);
      final details = FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      );

      // The handler ends with FlutterError.presentError(details), which
      // re-invokes whatever FlutterError.onError is currently installed
      // (the test framework's recorder). Stub it out for the call.
      final previous = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        main_lib.handleFlutterError(details, reporter);
      } finally {
        FlutterError.onError = previous;
      }
      await pumpEventQueue();

      expect(sink.errors, hasLength(1));
      expect(sink.errors.single, isA<StateError>());
      expect(sink.stacks.single, isNotNull);
    });

    test('benign Flutter errors are downgraded and never reach the reporter',
        () async {
      final sink = _RecordingSink();
      final reporter = CrashReporter(dsn: _testDsn, sink: sink);
      final details = FlutterErrorDetails(
        exception: StateError('Operation was Cancelled'),
      );

      final previous = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        main_lib.handleFlutterError(details, reporter);
      } finally {
        FlutterError.onError = previous;
      }
      await pumpEventQueue();

      expect(sink.errors, isEmpty);
    });

    test('handlePlatformError reports the error and returns true', () async {
      final sink = _RecordingSink();
      final reporter = CrashReporter(dsn: _testDsn, sink: sink);
      final error = const FormatException('bad');
      final stack = StackTrace.current;

      final handled =
          main_lib.handlePlatformError(error, stack, reporter);
      await pumpEventQueue();

      expect(handled, isTrue);
      expect(sink.errors.single, isA<FormatException>());
      expect(sink.stacks.single, stack);
    });

    test('benign platform errors return true without reporting', () async {
      final sink = _RecordingSink();
      final reporter = CrashReporter(dsn: _testDsn, sink: sink);

      final handled = main_lib.handlePlatformError(
        StateError('Bad state: Future already completed'),
        StackTrace.current,
        reporter,
      );
      await pumpEventQueue();

      expect(handled, isTrue);
      expect(sink.errors, isEmpty);
    });
  });
}

/// A [CrashSink] whose every method throws — proves the reporter's
/// fire-and-forget contract (a failing sink must never escape `reportError`).
class _ThrowingSink implements CrashSink {
  @override
  Future<void> reportError(
    Object error,
    StackTrace stack, {
    Map<String, String>? context,
  }) async {
    throw StateError('sink down');
  }

  @override
  void setUser(String userId) => throw StateError('sink down');

  @override
  void addBreadcrumb(String message) => throw StateError('sink down');
}
