
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/config_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// ConfigService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// row→map mapping, the signup-grant default fallback, and error behavior.
///
/// The facade-level ConfigService tests in `supabase_service_test.dart`
/// (I-11) remain; this file adds the dedicated mapping + fallback + error
/// coverage.
void main() {
  late MockSupabaseClient client;

  setUp(() {
    client = MockSupabaseClient();
  });

  ConfigService service() => ConfigService(client: client);

  group('ConfigService.fetchAppConfig', () {
    test('maps every row into a flat key -> value map', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'key': 'economy.user_signup_shards', 'value': '512'},
          {'key': 'economy.group_shard_boost_days', 'value': '21'},
          {'key': 'limits.member_cap', 'value': '14'},
        ]),
      );

      final map = await service().fetchAppConfig();

      expect(map, {
        'economy.user_signup_shards': '512',
        'economy.group_shard_boost_days': '21',
        'limits.member_cap': '14',
      });
      verify(() => table.select(any())).called(1);
    });

    test('returns an empty map when the table has no rows', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      expect(await service().fetchAppConfig(), isEmpty);
    });

    test('propagates a permission-denied PostgrestException', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenThrow(
        const PostgrestException(
          message: 'permission denied for table app_config',
          code: '42501',
        ),
      );

      final err = await captureError(() => service().fetchAppConfig());
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('ConfigService.getSignupShardGrant', () {
    test('reads the configured grant when present', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'key': 'economy.user_signup_shards', 'value': '128'},
        ]),
      );

      expect(await service().getSignupShardGrant(), 128);
    });

    test('falls back to 256 when the key is missing', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      expect(await service().getSignupShardGrant(), 256);
    });

    test('falls back to 256 when the fetch fails (never throws)', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      expect(await service().getSignupShardGrant(), 256);
    });

    test('falls back to 256 when the stored value is not an int', () async {
      final table = MockQueryBuilder();
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>([
          {'key': 'economy.user_signup_shards', 'value': 'muchos'},
        ]),
      );

      expect(await service().getSignupShardGrant(), 256);
    });
  });
}
