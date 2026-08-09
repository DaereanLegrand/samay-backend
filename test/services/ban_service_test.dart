
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/ban_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// BanService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18).
///
/// The I-35 provider/router ban scenarios live in
/// `test/features/auth/banned_test.dart` with a mocked [BanService]; this file
/// covers the service itself against a mocked Supabase client: the banned-row
/// detection, the fail-open contract, the 30 s cache and `invalidate()`.
const _userId = '11111111-1111-1111-1111-111111111111';

User _currentUser() => User.fromJson({'id': _userId, 'email': 'a@b.com'})!;

void main() {
  late MockSupabaseClient client;
  late MockGoTrueClient auth;

  setUp(() {
    client = MockSupabaseClient();
    auth = MockGoTrueClient();
    when(() => client.auth).thenReturn(auth);
  });

  BanService service() => BanService(client: client);

  MockQueryBuilder usersTable() {
    final users = MockQueryBuilder();
    when(() => client.from('users')).thenAnswer((_) => users);
    return users;
  }

  group('BanService.checkBanStatus', () {
    test('returns notBanned without a session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await service().checkBanStatus(), BanStatus.notBanned);
      verifyNever(() => client.from('users'));
    });

    test('reports a banned row with its reason', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'banned_at': '2026-08-01T00:00:00Z',
          'ban_reason': 'Spam',
        }),
      );

      final status = await service().checkBanStatus();

      expect(status.isBanned, isTrue);
      expect(status.reason, 'Spam');
    });

    test('treats a missing users row as not banned', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      expect(await service().checkBanStatus(), BanStatus.notBanned);
    });

    test('treats a null banned_at as not banned', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({'banned_at': null}),
      );

      expect(await service().checkBanStatus(), BanStatus.notBanned);
    });

    test('fails open when the check cannot run (network error)', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any())).thenThrow(
        const PostgrestException(
          message: 'connection refused',
          code: '28000',
        ),
      );

      final status = await service().checkBanStatus();

      expect(status, BanStatus.notBanned,
          reason: 'a failed ban check must never lock the user out');
    });

    test('caches the result for the cache window', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'banned_at': '2026-08-01T00:00:00Z',
          'ban_reason': 'Spam',
        }),
      );

      final svc = service();
      await svc.checkBanStatus();
      await svc.checkBanStatus();

      verify(() => users.select(any())).called(1);
    });

    test('force re-queries and invalidate() drops the cache', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any())).thenAnswer(
        (_) => ResolvingBuilder<PostgrestList>({
          'banned_at': '2026-08-01T00:00:00Z',
          'ban_reason': 'Spam',
        }),
      );

      final s = service();
      await s.checkBanStatus();
      await s.checkBanStatus(force: true);
      s.invalidate();
      await s.checkBanStatus();

      verify(() => users.select(any())).called(3);
    });

    test('deduplicates concurrent checks into a single query', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final users = usersTable();
      when(() => users.select(any()))
          .thenAnswer((_) => ResolvingBuilder<PostgrestList>(null));

      // Both calls start before the first completes — the in-flight future
      // must be shared, so only one query runs.
      final svc = service();
      final results = await Future.wait([
        svc.checkBanStatus(),
        svc.checkBanStatus(),
      ]);

      expect(results, [BanStatus.notBanned, BanStatus.notBanned]);
      verify(() => users.select(any())).called(1);
    });
  });
}
