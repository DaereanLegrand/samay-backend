
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/models/event.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// EventService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18).
///
/// * `likePhoto` coverage (PGRST202 fix — EF-03) is preserved verbatim.
/// * New: `createEvent` 3-table insert shape — verified against the schema
///   (`supabase/migrations/20260510000001_full_schema.sql` §3.10-3.17):
///   `events` row (incl. `dynamic_qr_enabled` = preshards_pool > 0,
///   `status` default 'upcoming'), `event_promotores` row (creator as
///   promotor with the contributed preshards), `chats` row (type 'event').
/// * New: `listEvents` status/type filters + ordering, `getEvent`, `updateEvent`.
/// * Failure paths assert propagation + the real error_mapper mapping.
const _photoId = '99999999-9999-9999-9999-999999999999';
const _userId = '11111111-1111-1111-1111-111111111111';
const _groupId = '33333333-3333-3333-3333-333333333333';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  EventService service() => EventService(client: client);

  group('EventService.likePhoto (PGRST202 fix — EF-03)', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('event_photo_likes')).thenAnswer((_) => table);
    });

    test('inserts the likes row and never calls the missing RPC', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select('id')).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>(null),
      );
      when(() => table.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().likePhoto(_photoId);

      final captured =
          verify(() => table.insert(captureAny())).captured.single as Map;
      expect(captured['photo_id'], _photoId);
      expect(captured['user_id'], _userId);
      expect(captured['created_at'], isNotEmpty);
      // The trigger maintains likes_count — the RPC must never be invoked.
      verifyNever(() =>
          client.rpc('increment_photo_likes', params: any(named: 'params')));
    });

    test('skips the insert (and the RPC) when the like already exists',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select('id'))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>({'id': 'like-1'}));

      await service().likePhoto(_photoId);

      verifyNever(() => table.insert(any()));
      verifyNever(() =>
          client.rpc('increment_photo_likes', params: any(named: 'params')));
    });

    test('throws when there is no authenticated user', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().likePhoto(_photoId), throwsA(isA<Exception>()));
      verifyNever(() => table.select(any()));
      verifyNever(() => table.insert(any()));
      verifyNever(() =>
          client.rpc('increment_photo_likes', params: any(named: 'params')));
    });
  });

  group('EventService.createEvent (3-table insert shape)', () {
    test('inserts events + event_promotores + chats with the derived flags',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final events = MockQueryBuilder();
      final promotores = MockQueryBuilder();
      final chats = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => client.from('event_promotores'))
          .thenAnswer((_) => promotores);
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => events.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => promotores.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => chats.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      final created = await service().createEvent({
        'name': 'Fiesta de prueba',
        'description': 'desc',
        'type': 'party',
        'group_id': _groupId,
        'starts_at': '2026-09-01T20:00:00Z',
        'ends_at': '2026-09-01T23:00:00Z',
        'join_mode': 'open',
        'preshards_pool': 1000,
        'preshards_cap_per_user': 100,
        'preshards_remainder_action': 'distribute',
      });

      final eventPayload =
          verify(() => events.insert(captureAny())).captured.single as Map;
      final promotorPayload = verify(() => promotores.insert(captureAny()))
          .captured
          .single as Map;
      final chatPayload =
          verify(() => chats.insert(captureAny())).captured.single as Map;

      // events row — every column the schema requires (§3.10).
      expect(eventPayload['id'], isNotEmpty);
      expect(eventPayload['name'], 'Fiesta de prueba');
      expect(eventPayload['type'], 'party');
      expect(eventPayload['created_by_user_id'], _userId);
      expect(eventPayload['group_id'], _groupId);
      expect(eventPayload['preshards_pool'], 1000);
      // dynamic QR is derived from the preshards pool (spec contract).
      expect(eventPayload['dynamic_qr_enabled'], isTrue);
      expect(eventPayload['status'], 'upcoming');
      expect(eventPayload['invite_token'], isNotEmpty);
      expect(eventPayload['created_at'], isNotEmpty);
      expect(eventPayload['updated_at'], isNotEmpty);

      // event_promotores row (§3.11): creator is the first promotor and
      // contributes the whole pool.
      expect(promotorPayload['event_id'], eventPayload['id']);
      expect(promotorPayload['user_id'], _userId);
      expect(promotorPayload['role'], 'promotor');
      expect(promotorPayload['preshards_contributed'], 1000);
      expect(promotorPayload['added_at'], isNotEmpty);

      // chats row (§3.17): an event chat attached to the new event.
      expect(chatPayload['type'], 'event');
      expect(chatPayload['reference_id'], eventPayload['id']);

      // The returned handle carries the generated ids for the QR flow.
      expect(created['id'], eventPayload['id']);
    });

    test('a pool-less event disables the dynamic QR flag', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final events = MockQueryBuilder();
      final promotores = MockQueryBuilder();
      final chats = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => client.from('event_promotores'))
          .thenAnswer((_) => promotores);
      when(() => client.from('chats')).thenAnswer((_) => chats);
      when(() => events.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => promotores.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));
      when(() => chats.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().createEvent({
        'name': 'Sin pool',
        'type': 'casual',
        'starts_at': '2026-09-01T20:00:00Z',
        'ends_at': '2026-09-01T23:00:00Z',
      });

      final eventPayload =
          verify(() => events.insert(captureAny())).captured.single as Map;
      expect(eventPayload['dynamic_qr_enabled'], isFalse);
      expect(eventPayload['preshards_pool'], 0);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().createEvent({'name': 'X'}),
          throwsA(isA<Exception>()));
      verifyNever(() => client.from('events'));
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => events.insert(any())).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      final err =
          await captureError(() => service().createEvent({'name': 'X'}));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('EventService.listEvents', () {
    test('returns all events ordered by starts_at when no filters are given',
        () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      final rows = ResolvingBuilder<PostgrestList>([
        {'id': 'e-1', 'name': 'A', 'type': 'juerga', 'status': 'upcoming', 'starts_at': '2026-08-01T00:00:00Z', 'ends_at': '2026-08-01T03:00:00Z'},
        {'id': 'e-2', 'name': 'B', 'type': 'juerga', 'status': 'upcoming', 'starts_at': '2026-09-01T00:00:00Z', 'ends_at': '2026-09-01T03:00:00Z'},
      ]);
      when(() => events.select()).thenAnswer((_) => rows);

      final result = await service().listEvents();

      expect(result, hasLength(2));
      expect(rows.filters, isEmpty);
    });

    test('applies the status and type filters when given', () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      final rows = ResolvingBuilder<PostgrestList>([]);
      when(() => events.select()).thenAnswer((_) => rows);

      await service().listEvents('upcoming', 'party');

      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('status', 'upcoming'),
        const RecordedFilter('type', 'party'),
      ]));
    });

    test('propagates a network-class PostgrestException', () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => events.select()).thenThrow(
        const PostgrestException(
          message: 'could not connect to server',
          code: '28000',
        ),
      );

      final err = await captureError(() => service().listEvents());
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });

  group('EventService.getEvent', () {
    test('returns the mapped event row', () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => events.select()).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'id': 'e-1',
          'name': 'Fiesta',
          'type': 'juerga',
          'status': 'upcoming',
          'starts_at': '2026-09-01T20:00:00Z',
          'ends_at': '2026-09-01T23:00:00Z',
        }),
      );

      final event = await service().getEvent('e-1');

      expect(event.name, 'Fiesta');
    });

    test('propagates a not-found PostgrestException', () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      when(() => events.select()).thenThrow(
        const PostgrestException(
          message: 'JSON object requested, multiple (or no) rows returned',
          code: 'PGRST116',
        ),
      );

      final err = await captureError(() => service().getEvent('missing'));
      expect(err, isA<PostgrestException>());
      expectMapped(err, ServerError);
    });
  });

  group('EventService.updateEvent', () {
    test('stamps updated_at and derives dynamic_qr_enabled from the pool',
        () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => events.update(any())).thenAnswer((_) => update);

      await service().updateEvent('e-1', {'preshards_pool': 500});

      final payload = verify(() => events.update(captureAny()))
          .captured
          .single as Map;
      expect(payload['preshards_pool'], 500);
      expect(payload['dynamic_qr_enabled'], isTrue);
      expect(payload['updated_at'], isNotEmpty);
      expect(update.filters.single.value, 'e-1');
    });

    test('does not touch dynamic_qr_enabled when the pool is unchanged',
        () async {
      final events = MockQueryBuilder();
      when(() => client.from('events')).thenAnswer((_) => events);
      final update = ResolvingBuilder<dynamic>(null);
      when(() => events.update(any())).thenAnswer((_) => update);

      await service().updateEvent('e-1', {'name': 'Renombrada'});

      final payload = verify(() => events.update(captureAny()))
          .captured
          .single as Map;
      expect(payload.containsKey('dynamic_qr_enabled'), isFalse);
      expect(payload['name'], 'Renombrada');
    });
  });

  group('EventService.unlikePhoto (PHUP like toggle — I-59)', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('event_photo_likes')).thenAnswer((_) => table);
    });

    test('deletes the current user row filtered by photo + user', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final deleted = ResolvingBuilder<dynamic>(null);
      when(() => table.delete()).thenAnswer((_) => deleted);

      await service().unlikePhoto(_photoId);

      expect(deleted.filters, containsAllInOrder([
        const RecordedFilter('photo_id', _photoId),
        const RecordedFilter('user_id', _userId),
      ]));
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().unlikePhoto(_photoId),
          throwsA(isA<Exception>()));
      verifyNever(() => table.delete());
    });
  });

  group('EventService.getMyPhotoLikes (PHUP — I-59)', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('event_photo_likes')).thenAnswer((_) => table);
    });

    test('returns the liked photo ids for the event via the inner join',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rows = ResolvingBuilder<PostgrestList>([
        {
          'photo_id': 'p-1',
          'event_photos': {'event_id': 'e-1'},
        },
        {
          'photo_id': 'p-2',
          'event_photos': {'event_id': 'e-1'},
        },
      ]);
      when(() => table.select(any())).thenAnswer((_) => rows);

      final liked = await service().getMyPhotoLikes('e-1');

      expect(liked, ['p-1', 'p-2']);
      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('user_id', _userId),
        const RecordedFilter('event_photos.event_id', 'e-1'),
      ]));
    });

    test('returns an empty list without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().getMyPhotoLikes('e-1'), isEmpty);
      verifyNever(() => table.select(any()));
    });
  });
}
