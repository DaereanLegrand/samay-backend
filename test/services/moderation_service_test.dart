
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/errors/app_error.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/services/moderation_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../support/resolving_builder.dart';

/// ModerationService behavioral tests (I-44, TST-04/H-17 + TST-05/H-18):
/// the reports insert shape and error propagation.
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

  ModerationService service() => ModerationService(client: client);

  group('ModerationService.reportContent', () {
    test('inserts a pending report row', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final reports = MockQueryBuilder();
      when(() => client.from('reports')).thenAnswer((_) => reports);
      when(() => reports.insert(any()))
          .thenAnswer((_) => ResolvingBuilder<dynamic>(null));

      await service().reportContent('event', 'e-1', 'Spam');

      final payload =
          verify(() => reports.insert(captureAny())).captured.single as Map;
      expect(payload['reporter_id'], _userId);
      expect(payload['target_type'], 'event');
      expect(payload['target_id'], 'e-1');
      expect(payload['reason'], 'Spam');
      expect(payload['status'], 'pending');
      expect(payload['created_at'], isNotEmpty);
    });

    test('throws without an authenticated session', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(
        () => service().reportContent('event', 'e-1', 'Spam'),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => client.from('reports'));
    });

    test('propagates a permission-denied PostgrestException', () async {
      when(() => auth.currentUser).thenReturn(_currentUser());
      final reports = MockQueryBuilder();
      when(() => client.from('reports')).thenAnswer((_) => reports);
      when(() => reports.insert(any())).thenThrow(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );

      final err =
          await captureError(() => service().reportContent('user', 'u-1', 'x'));
      expect(err, isA<PostgrestException>());
      expectMapped(err, PermissionError);
    });
  });
}
