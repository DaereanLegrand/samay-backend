import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/user_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// UserService tests for the PRFL avatar flow (I-36): the
/// [UserService.updateAvatarUrl] persistence contract.
///
/// Mirrors `test/services/supabase_service_test.dart`: the Supabase client is
/// mocked, and the Postgrest chain is a `_ResolvingUpdate` subclass that
/// resolves without network IO and records the `eq` filter.
class _MockSupabaseClient extends Mock implements SupabaseClient {}

class _MockQueryBuilder extends Mock implements SupabaseQueryBuilder {}

/// Real Postgrest filter that resolves to `null` when awaited (no network)
/// and records the equality filter [UserService.updateAvatarUrl] chains.
class _ResolvingUpdate extends PostgrestFilterBuilder<dynamic> {
  _ResolvingUpdate()
      : super(PostgrestBuilder(
          url: Uri.parse('http://localhost/fake'),
          headers: const {},
        ));

  /// `eq` filters applied by the real chain ([eq] is overridden, not stubbed,
  /// so mocktail cannot observe them — this list is the observable).
  final List<MapEntry<String, Object?>> eqFilters = [];

  @override
  _ResolvingUpdate eq(String column, Object value) {
    eqFilters.add(MapEntry<String, Object?>(column, value));
    return this;
  }

  @override
  Future<U> then<U>(
    FutureOr<U> Function(dynamic value) onValue, {
    Function? onError,
  }) {
    return Future<U>.value(onValue(null));
  }
}

void main() {
  group('UserService.updateAvatarUrl (PRFL avatar flow — I-36)', () {
    late _MockSupabaseClient client;
    late _MockQueryBuilder table;

    setUp(() {
      client = _MockSupabaseClient();
      table = _MockQueryBuilder();
      when(() => client.from('users')).thenAnswer((_) => table);
    });

    test('updates users.avatar_url for the given user id', () async {
      final update = _ResolvingUpdate();
      when(() => table.update(any())).thenAnswer((_) => update);

      await UserService(client: client)
          .updateAvatarUrl(_userId, _avatarUrl);

      verify(() => table.update({'avatar_url': _avatarUrl})).called(1);
      expect(update.eqFilters.single.key, 'id');
      expect(update.eqFilters.single.value, _userId);
    });

    test('surfaces update failures to the caller', () async {
      when(() => table.update(any()))
          .thenThrow(StateError('update rejected'));

      expect(
        () => UserService(client: client).updateAvatarUrl(_userId, _avatarUrl),
        throwsStateError,
      );
    });
  });
}

const _userId = '11111111-1111-1111-1111-111111111111';
const _avatarUrl = 'https://cdn.example/avatars/$_userId/123.png';
