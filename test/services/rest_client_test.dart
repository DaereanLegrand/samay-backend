import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/models/notification_item.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/rest_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// RestClient behavioral tests (I-51, TST-08/refactorability):
/// filter/order/limit chain building (parameterized — no string
/// interpolation), fromJson mapping, single/maybeSingle semantics,
/// write scoping and error propagation.
///
/// The network-free [ResolvingBuilder] chain records every filter it receives
/// ([RecordedFilter]), so these tests assert the exact filter shape the
/// wrapper builds — the C-04 doctrine applied to the envelope itself.

/// [ResolvingBuilder] that also records the transform stage (`order`/`limit`)
/// the shared builder silently absorbs, so the wrapper's ordering is
/// assertable.
// ignore: must_be_immutable — mutable record fields are the point.
class _OrderAwareBuilder extends ResolvingBuilder<PostgrestList> {
  _OrderAwareBuilder(super.value);

  String? recordedOrder;
  bool? recordedAscending;
  int? recordedLimit;

  @override
  _OrderAwareBuilder order(
    String column, {
    bool ascending = true,
    bool? nullsFirst,
    String? referencedTable,
  }) {
    recordedOrder = column;
    recordedAscending = ascending;
    return this;
  }

  @override
  _OrderAwareBuilder limit(int count, {String? referencedTable}) {
    recordedLimit = count;
    return this;
  }
}

void main() {
  late MockSupabaseClient client;
  late MockQueryBuilder table;
  late RestClient rest;

  setUp(() {
    client = MockSupabaseClient();
    table = MockQueryBuilder();
    rest = RestClient(client: client);
  });

  group('RestClient.list', () {
    test('selects the table and applies eq/ilike/gt/in filters in order',
        () async {
      final rows = ResolvingBuilder<PostgrestList>([
        {'id': '1', 'username': 'ada'},
      ]);
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select('id, username')).thenAnswer((_) => rows);

      await rest.list<Map<String, dynamic>>(
        'users',
        fromJson: (row) => row,
        select: 'id, username',
        filters: [
          (column: 'status', op: 'eq', value: 'active'),
          (column: 'username', op: 'ilike', value: 'ada%'),
          (column: 'personal_shards', op: 'gt', value: 100),
          (column: 'id', op: 'in', value: ['u1', 'u2']),
        ],
      );

      // RecordedFilter equality is value-based; list values are compared
      // element-wise via matchers (Dart list identity would always fail).
      expect(rows.filters, hasLength(4));
      expect(rows.filters[0], const RecordedFilter('status', 'active'));
      expect(rows.filters[1], const RecordedFilter('username', 'ada%'));
      expect(rows.filters[2], const RecordedFilter('personal_shards', 100));
      expect(rows.filters[3].column, 'id');
      expect(rows.filters[3].value, ['u1', 'u2']);
      verify(() => client.from('users')).called(1);
      verify(() => table.select('id, username')).called(1);
    });

    test('applies order (with the ascending flag) and limit to the chain',
        () async {
      final rows = _OrderAwareBuilder([
        {'id': 'm-1'},
      ]);
      when(() => client.from('messages')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer((_) => rows);

      await rest.list<Map<String, dynamic>>(
        'messages',
        fromJson: (row) => row,
        order: 'created_at',
        ascending: false,
        limit: 50,
      );

      expect(rows.recordedOrder, 'created_at');
      expect(rows.recordedAscending, isFalse);
      expect(rows.recordedLimit, 50);
    });

    test('maps every row through the fromJson factory (freezed model)',
        () async {
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'id': 'n-1',
          'type': 'event',
          'title': 'Tu evento empieza',
          'body': 'Fiesta de prueba',
          'data': null,
          'read': false,
          'created_at': '2026-08-01T00:00:00Z',
        },
        {
          'id': 'n-2',
          'type': 'friend',
          'title': 'Nueva solicitud',
          'body': 'Ana te agregó',
          'data': null,
          'read': true,
          'created_at': '2026-08-02T00:00:00Z',
        },
      ]);
      when(() => client.from('notifications')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final items = await rest.list<NotificationItem>(
        'notifications',
        fromJson: NotificationItem.fromJson,
      );

      expect(items, hasLength(2));
      expect(items.first.id, 'n-1');
      expect(items.first.title, 'Tu evento empieza');
      expect(items.first.read, isFalse);
      expect(items.first.createdAt, DateTime.utc(2026, 8, 1));
      expect(items.last.read, isTrue);
    });

    test('returns an empty list for an empty result set', () async {
      when(() => client.from('app_config')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      final rows = await rest.list<Map<String, dynamic>>(
        'app_config',
        fromJson: (row) => row,
      );

      expect(rows, isEmpty);
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenThrow(
        const PostgrestException(
          message: 'permission denied for table users',
          code: '42501',
        ),
      );

      final err = await captureError(() => rest.list<Map<String, dynamic>>(
        'users',
        fromJson: (row) => row,
      ));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });

    test('rejects an unknown filter operator', () async {
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>([]));

      expect(
        () => rest.list<Map<String, dynamic>>(
          'users',
          fromJson: (row) => row,
          filters: [(column: 'id', op: 'nope', value: 'x')],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('RestClient.maybeSingle / single', () {
    test('maybeSingle returns null when no row matches', () async {
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      final profile = await rest.maybeSingle<Map<String, dynamic>>(
        'users',
        fromJson: (row) => row,
        filters: [(column: 'id', op: 'eq', value: 'u-1')],
      );

      expect(profile, isNull);
    });

    test('maybeSingle maps the matched row and applies the filters', () async {
      final rows = ResolvingBuilder<PostgrestList>({
        'id': 'u-1',
        'username': 'ada',
      });
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final profile = await rest.maybeSingle<Map<String, dynamic>>(
        'users',
        fromJson: (row) => row,
        filters: [(column: 'id', op: 'eq', value: 'u-1')],
      );

      expect(profile?['username'], 'ada');
      expect(rows.filters, equals([const RecordedFilter('id', 'u-1')]));
    });

    test('single maps the matched row', () async {
      when(() => client.from('cosmetics')).thenAnswer((_) => table);
      when(() => table.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'id': 'c-1',
          'shard_cost': 50,
        }),
      );

      final cosmetic = await rest.single<Map<String, dynamic>>(
        'cosmetics',
        fromJson: (row) => row,
      );

      expect(cosmetic['shard_cost'], 50);
    });

    test('single propagates a server PostgrestException', () async {
      when(() => client.from('cosmetics')).thenAnswer((_) => table);
      when(() => table.select(any())).thenThrow(
        const PostgrestException(
          message: 'database error',
          code: 'P0001',
        ),
      );

      final err = await captureError(() => rest.single<Map<String, dynamic>>(
        'cosmetics',
        fromJson: (row) => row,
      ));
      expect(err, isA<PostgrestException>());
      expectMapped(err, ServerError);
    });
  });

  group('RestClient.insert / update / delete', () {
    test('insert passes the row to the table', () async {
      when(() => client.from('signup_tracker')).thenAnswer((_) => table);
      when(() => table.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await rest.insert('signup_tracker', {
        'email': 'a@b.com',
        'profile_created': false,
      });

      verify(() => client.from('signup_tracker')).called(1);
      verify(() => table.insert({
            'email': 'a@b.com',
            'profile_created': false,
          })).called(1);
    });

    test('update patches the row scoped by the id column filter', () async {
      when(() => client.from('users')).thenAnswer((_) => table);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => table.update(any())).thenAnswer((_) => update);

      await rest.update('users', 'id', 'u-1', {'bio': 'Hola'});

      verify(() => table.update({'bio': 'Hola'})).called(1);
      expect(update.filters, equals([const RecordedFilter('id', 'u-1')]));
    });

    test('delete filters by the id column', () async {
      when(() => client.from('friendships')).thenAnswer((_) => table);
      final delete = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => delete);

      await rest.delete('friendships', 'id', 'f-1');

      verify(() => table.delete()).called(1);
      expect(delete.filters, equals([const RecordedFilter('id', 'f-1')]));
    });

    test('propagates a PostgrestException from update', () async {
      when(() => client.from('users')).thenAnswer((_) => table);
      when(() => table.update(any())).thenThrow(
        const PostgrestException(
          message: 'database error',
          code: 'P0001',
        ),
      );

      final err = await captureError(
        () => rest.update('users', 'id', 'u-1', {'bio': 'Hola'}),
      );
      expect(err, isA<PostgrestException>());
      expectMapped(err, ServerError);
    });
  });

  group('restClientProvider', () {
    test('resolves a RestClient over the overridden SupabaseClient', () {
      final container = ProviderContainer(overrides: [
        supabaseClientProvider.overrideWithValue(client),
      ]);
      addTearDown(container.dispose);

      final provided = container.read(restClientProvider);

      expect(provided, isA<RestClient>());
    });
  });
}
