import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/extensions/error_mapper.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared mocktail fakes + network-free Postgrest builders for the
/// behavioral service/provider tests (I-44, TST-02..TST-05).
///
/// The patterns here are the ones proven in
/// `test/services/supabase_service_test.dart` and
/// `test/services/event_service_test.dart` (I-11/EF-03): mocktail cannot stub
/// `then` on classes implementing `Future`, so Postgrest chains are resolved
/// by *real* builder subclasses that override `then` (and every chain method
/// the services call) to resolve locally — zero network I/O.

class MockSupabaseClient extends Mock implements SupabaseClient {}

class MockGoTrueClient extends Mock implements GoTrueClient {}

class MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

class MockRealtimeChannel extends Mock implements RealtimeChannel {}

class MockConfigService extends Mock implements ConfigService {}

class MockStorageClient extends Mock implements SupabaseStorageClient {}

class MockStorageFileApi extends Mock implements StorageFileApi {}

/// Records the `eq`/`neq`/`ilike`/… filters a service chains onto a builder,
/// so tests can assert the exact filter shape without mocktail observing the
/// chain (the chain methods are overridden, not stubbed). Value equality is
/// implemented so `containsAllInOrder` / `contains` assertions work.
class RecordedFilter {
  const RecordedFilter(this.column, this.value);

  final String column;
  final Object? value;

  @override
  bool operator ==(Object other) =>
      other is RecordedFilter &&
      other.column == column &&
      other.value == value;

  @override
  int get hashCode => Object.hash(column, value);

  @override
  String toString() => 'RecordedFilter($column, $value)';
}

/// Real Postgrest filter builder that resolves to [value] when awaited,
/// without any network I/O. Every chain method the services use returns `this`
/// (recording filters), so a multi-hop chain never escapes into a real
/// `copyWithUrl` builder (which would perform an HTTP request when awaited).
class ResolvingBuilder<T> extends PostgrestFilterBuilder<T> {
  ResolvingBuilder(Object? value)
      : _value = value,
        super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;
  final List<RecordedFilter> filters = [];
  final List<(int, int)> ranges = [];

  /// Normalizes raw JSON-ish values into the PostgREST shapes the services
  /// await: bare `[]`/`[{...}]` literals infer as `List<dynamic>` without a
  /// contextual type, which would fail the `as T` cast in [then].
  static Object? coerce(Object? value) {
    if (value is List) {
      return [
        for (final e in value) Map<String, dynamic>.from(e as Map),
      ];
    }
    return value;
  }

  ResolvingBuilder<T> _record(String column, Object? value) {
    filters.add(RecordedFilter(column, value));
    return this;
  }

  @override
  ResolvingBuilder<T> eq(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> neq(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> gt(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> gte(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> lt(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> lte(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> like(String column, String pattern) =>
      _record(column, pattern);

  @override
  ResolvingBuilder<T> ilike(String column, String pattern) =>
      _record(column, pattern);

  @override
  ResolvingBuilder<T> inFilter(String column, List values) =>
      _record(column, values);

  @override
  ResolvingBuilder<T> overlaps(String column, Object value) =>
      _record(column, value);

  @override
  ResolvingBuilder<T> order(
    String column, {
    bool ascending = true,
    bool? nullsFirst,
    String? referencedTable,
  }) =>
      this;

  @override
  ResolvingBuilder<T> limit(int count, {String? referencedTable}) =>
      this;

  @override
  ResolvingBuilder<T> range(int from, int to, {String? referencedTable}) {
    ranges.add((from, to));
    return this;
  }

  @override
  ResolvingTransform<PostgrestMap?> maybeSingle() =>
      ResolvingTransform<PostgrestMap?>(_value);

  @override
  ResolvingTransform<PostgrestMap> single() =>
      ResolvingTransform<PostgrestMap>(_value);

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    // Defer through `Future(() => ...)` — never call [onValue] synchronously:
    // a real Future invokes its callback in a microtask, and a synchronous
    // invocation lets a throwing continuation escape to the test zone as an
    // uncaught error (I-44 MISTAKE — see the daily log).
    return Future<U>(() => onValue(coerce(_value) as T));
  }
}

/// Real Postgrest transform builder that resolves to [value] when awaited.
class ResolvingTransform<T> extends PostgrestTransformBuilder<T> {
  ResolvingTransform(Object? value)
      : _value = value,
        super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>(() => onValue(ResolvingBuilder.coerce(_value) as T));
  }
}

/// Runs [fn], capturing any thrown error (or failing the test if nothing
/// throws). Failure-path tests then assert both the raw exception type and its
/// mapping through the real [ObjectX.toAppError] mapper:
///
/// ```dart
/// final err = await captureError(() => service.getNotifications());
/// expect(err, isA<PostgrestException>());
/// expect(err!.toAppError(), isA<PermissionError>());
/// ```
Future<Object?> captureError(Future<void> Function() fn) async {
  try {
    await fn();
  } on Object catch (e) {
    return e;
  }
  fail('expected the call to fail, but it succeeded');
}

/// Convenience: asserts [error] propagated and maps through the real
/// error_mapper ([ObjectX.toAppError]) to the AppError subclass [expected].
void expectMapped(Object? error, Type expected, [String? reason]) {
  expect(error, isNotNull, reason: reason);
  final mapped = error!.toAppError();
  expect(mapped, isA<AppError>(), reason: reason);
  expect(mapped.runtimeType, expected, reason: reason);
}
