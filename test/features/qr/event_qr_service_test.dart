import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/resolving_builder.dart';

/// EventService QR contract tests (I-57, QRAT/QRSC foundation):
///
/// * `getMyQrToken` — own-row query on `event_qr_tokens` (RLS `eqt_read_own`:
///   `user_id = auth.uid()`), latest row per user+event, null when the server
///   has not issued a token yet (pre-activation / EEDG not deployed).
/// * `validateQrToken` — invokes the `validate_qr_token` RPC (migration
///   20260809000005), the SQL stand-in for the blocked `validate-attendance`
///   Edge Function; failure propagation incl. the not-deployed PGRST202.
const _userId = '11111111-1111-1111-1111-111111111111';
const _eventId = '22222222-2222-2222-2222-222222222222';

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

  group('EventService.getMyQrToken', () {
    late MockQueryBuilder table;

    setUp(() {
      table = MockQueryBuilder();
      when(() => client.from('event_qr_tokens')).thenAnswer((_) => table);
    });

    test('queries the own-row token by event + user (RLS eqt_read_own)',
        () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final rows = ResolvingBuilder<PostgrestList>({
        'id': 'tok-1',
        'event_id': _eventId,
        'user_id': _userId,
        'token': 'abc-123',
        'expires_at': '2026-08-09T23:00:00Z',
        'scanned_at': null,
        'attendance_confirmed': false,
      });
      when(() => table.select()).thenAnswer((_) => rows);

      final token = await service().getMyQrToken(_eventId);

      expect(token, isNotNull);
      expect(token!['token'], 'abc-123');
      expect(token['expires_at'], '2026-08-09T23:00:00Z');
      // Own-row contract: event_id + auth.uid() filters, latest row first
      // (ordered by created_at DESC — the rotation rows accumulate over time).
      expect(rows.filters, containsAllInOrder([
        const RecordedFilter('event_id', _eventId),
        const RecordedFilter('user_id', _userId),
      ]));
    });

    test('returns null when the server has not issued a token yet', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select())
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      final token = await service().getMyQrToken(_eventId);

      expect(token, isNull);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(() => service().getMyQrToken(_eventId), throwsA(isA<Exception>()));
      verifyNever(() => client.from('event_qr_tokens'));
    });

    test('propagates a PostgrestException (e.g. FORCE-RLS denial)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      when(() => table.select()).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      final err = await captureError(() => service().getMyQrToken(_eventId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });

  group('EventService.validateQrToken', () {
    test('invokes the validate_qr_token RPC with the scanner contract',
        () async {
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'confirmed',
        'attendeeUserId': _userId,
        'attendeeName': 'ana',
        'confirmedAt': '2026-08-09T23:00:00Z',
      });
      when(() => client.rpc('validate_qr_token', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      final result = await service().validateQrToken(_eventId, 'abc-123');

      expect(result['status'], 'confirmed');
      expect(result['attendeeName'], 'ana');
      final params =
          verify(() => client.rpc('validate_qr_token', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params, {
        'p_event_id': _eventId,
        'p_token': 'abc-123',
      });
    });

    test('propagates PGRST202 when the RPC is not deployed (EEDG blocked)',
        () async {
      when(() => client.rpc('validate_qr_token', params: any(named: 'params')))
          .thenThrow(
        const PostgrestException(
          message: 'Could not find the function public.validate_qr_token',
          code: 'PGRST202',
        ),
      );

      final err = await captureError(() => service().validateQrToken(_eventId, 'x'));
      expect(err, isA<PostgrestException>());
      expect((err! as PostgrestException).code, 'PGRST202');
      expectMapped(err, ServerError);
    });

    test('propagates a network-class PostgrestException', () async {
      when(() => client.rpc('validate_qr_token', params: any(named: 'params')))
          .thenThrow(
        const PostgrestException(
          message: 'could not connect to server',
          code: '28000',
        ),
      );

      final err = await captureError(() => service().validateQrToken(_eventId, 'x'));
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });

  group('EventService.rotateQrToken', () {
    test('invokes the rotate_qr_token RPC with the attendee contract',
        () async {
      final rpc = ResolvingBuilder<dynamic>({
        'status': 'ok',
        'token': 'abc-123',
        'expiresAt': '2026-08-14T23:00:00Z',
      });
      when(() => client.rpc('rotate_qr_token', params: any(named: 'params')))
          .thenAnswer((_) => rpc);

      final result = await service().rotateQrToken(_eventId);

      expect(result!['status'], 'ok');
      expect(result['token'], 'abc-123');
      expect(result['expiresAt'], '2026-08-14T23:00:00Z');
      final params =
          verify(() => client.rpc('rotate_qr_token', params: captureAny(named: 'params')))
              .captured
              .single as Map<String, dynamic>;
      expect(params, {'p_event_id': _eventId});
    });

    test('returns null when the RPC yields no payload', () async {
      when(() => client.rpc('rotate_qr_token', params: any(named: 'params')))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      expect(await service().rotateQrToken(_eventId), isNull);
    });

    test('propagates a network-class PostgrestException', () async {
      when(() => client.rpc('rotate_qr_token', params: any(named: 'params')))
          .thenThrow(
        const PostgrestException(
          message: 'could not connect to server',
          code: '28000',
        ),
      );

      final err = await captureError(() => service().rotateQrToken(_eventId));
      expect(err, isA<PostgrestException>());
      expectMapped(err, NetworkError);
    });
  });
}
