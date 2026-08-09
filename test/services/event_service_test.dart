import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// EventService.likePhoto behavioral tests (PGRST202 fix — EF-03).
///
/// The DB maintains `event_photos.likes_count` via the
/// `photo_likes_count_trigger` (AFTER INSERT OR DELETE ON event_photo_likes,
/// full_schema.sql §5.5), so `likePhoto` must only insert the likes row and
/// must NEVER call the (nonexistent) `increment_photo_likes` RPC that a
/// previous build invoked at runtime.
///
/// Mirrors `test/services/supabase_service_test.dart`: the Supabase client is
/// mocked, and the Postgrest chain is resolved without network by real
/// builder subclasses (mocktail cannot stub `then` on Future-implementing
/// classes — I-11 MISTAKE block).
class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockGoTrueClient extends Mock implements GoTrueClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

/// Real Postgrest filter that resolves to [value] when awaited, without any
/// network I/O. [eq] and [maybeSingle] are overridden because the base class
/// rebuilds the chain with plain `PostgrestBuilder` instances (`copyWithUrl`),
/// which would perform a real HTTP request when awaited.
class _ResolvingFilter<T> extends PostgrestFilterBuilder<T> {
  _ResolvingFilter(Object? value)
      : _value = value,
        super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  final Object? _value;

  @override
  _ResolvingFilter<T> eq(String column, Object value) => this;

  @override
  PostgrestTransformBuilder<PostgrestMap?> maybeSingle() =>
      _ResolvingTransform<PostgrestMap?>(_value);

  @override
  Future<U> then<U>(
    FutureOr<U> Function(T value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(_value as T));
  }
}

/// Real Postgrest transform that resolves to [value] when awaited.
class _ResolvingTransform<T> extends PostgrestTransformBuilder<T> {
  _ResolvingTransform(Object? value)
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
    return Future<U>.value(onValue(_value as T));
  }
}

const _photoId = '99999999-9999-9999-9999-999999999999';
const _userId = '11111111-1111-1111-1111-111111111111';

void main() {
  late _MockSupabaseClient client;
  late _MockGoTrueClient auth;
  late _MockQueryBuilder table;

  setUp(() {
    client = _MockSupabaseClient();
    auth = _MockGoTrueClient();
    table = _MockQueryBuilder();
    when(() => client.auth).thenReturn(auth);
    when(() => client.from('event_photo_likes')).thenAnswer((_) => table);
  });

  EventService service() => EventService(client: client);

  group('EventService.likePhoto (PGRST202 fix — EF-03)', () {
    test('inserts the likes row and never calls the missing RPC', () async {
      when(() => auth.currentUser).thenReturn(
        User.fromJson({'id': _userId, 'email': 'a@b.com'}),
      );
      when(() => table.select('id')).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>(null),
      );
      when(() => table.insert(any())).thenAnswer(
        (_) => _ResolvingFilter<dynamic>(null),
      );

      await service().likePhoto(_photoId);

      final captured = verify(() => table.insert(captureAny()))
          .captured
          .single as Map;
      expect(captured['photo_id'], _photoId);
      expect(captured['user_id'], _userId);
      expect(captured['created_at'], isNotEmpty);
      // The trigger maintains likes_count — the RPC must never be invoked.
      verifyNever(() => client.rpc('increment_photo_likes', params: any(named: 'params')));
    });

    test('skips the insert (and the RPC) when the like already exists',
        () async {
      when(() => auth.currentUser).thenReturn(
        User.fromJson({'id': _userId}),
      );
      when(() => table.select('id')).thenAnswer(
        (_) => _ResolvingFilter<PostgrestList>({'id': 'like-1'}),
      );

      await service().likePhoto(_photoId);

      verifyNever(() => table.insert(any()));
      verifyNever(() => client.rpc('increment_photo_likes', params: any(named: 'params')));
    });

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().likePhoto(_photoId),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => table.select(any()));
      verifyNever(() => table.insert(any()));
      verifyNever(() => client.rpc('increment_photo_likes', params: any(named: 'params')));
    });
  });
}
