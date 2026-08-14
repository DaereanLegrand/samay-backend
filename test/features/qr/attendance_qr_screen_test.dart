import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/qr/screens/attendance_qr_screen.dart';
import 'package:samay/features/qr/providers/qr_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// Attendance QR screen states (QRAT foundation, I-57):
/// inactive (pre-activation countdown) / serverPending (window open, no
/// server token) / active (QR + countdown ring, rotation refetch at 0) /
/// expired (auto-refetch once, then retryable) / ended. The event service is
/// a mocktail fake injected via [eventServiceProvider]; the countdown window
/// is pinned to 15s via [qrDisplayWindowProvider].
const _eventId = '22222222-2222-2222-2222-222222222222';

class MockEventService extends Mock implements EventService {}

/// Event starting in ~2h3m (activation at now + 93 min — one full minute of
/// drift headroom: the countdown renders 92 deterministically even if a few
/// seconds elapse between the fake's `starts_at` and the first frame).
class _FakeUpcomingEventNotifier extends EventDetailNotifier {
  @override
  Future<Map<String, dynamic>> build(String arg) async => {
        'id': _eventId,
        'name': 'Rave en el garaje',
        'status': 'upcoming',
        'starts_at': DateTime.now()
            .add(const Duration(hours: 2, minutes: 3))
            .toIso8601String(),
        'ends_at': DateTime.now()
            .add(const Duration(hours: 5))
            .toIso8601String(),
      };
}

class _FakeEndedEventNotifier extends EventDetailNotifier {
  @override
  Future<Map<String, dynamic>> build(String arg) async => {
        'id': _eventId,
        'name': 'Rave en el garaje',
        'status': 'ended',
        'starts_at': DateTime.now()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
        'ends_at': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      };
}

/// Event already inside the activation window (starts in 10 min → activation
/// 20 min ago) — a null token here means "server pending", not pre-activation.
class _FakeWindowOpenEventNotifier extends EventDetailNotifier {
  @override
  Future<Map<String, dynamic>> build(String arg) async => {
        'id': _eventId,
        'name': 'Rave en el garaje',
        'status': 'upcoming',
        'starts_at': DateTime.now()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
        'ends_at': DateTime.now()
            .add(const Duration(hours: 3))
            .toIso8601String(),
      };
}

Map<String, dynamic> _token(String value, {Duration expiresIn = const Duration(seconds: 15)}) =>
    {
      'id': 'tok-$value',
      'event_id': _eventId,
      'user_id': '11111111-1111-1111-1111-111111111111',
      'token': value,
      'expires_at': DateTime.now().add(expiresIn).toIso8601String(),
      'scanned_at': null,
      'attendance_confirmed': false,
    };

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required MockEventService service,
  required EventDetailNotifier Function() eventNotifier,
}) async {
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(service),
      eventDetailProvider.overrideWith(eventNotifier),
      qrDisplayWindowProvider.overrideWith((ref) async => 15),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AttendanceQrScreen(eventId: _eventId),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// The token the screen is displaying, read from the provider state (the
/// `QrImageView` widget itself exposes no public data getter in qr_flutter
/// 4.x, so the provider row is the observable contract — the screen renders
/// exactly the latest token row the provider holds).
String? _displayedToken(ProviderContainer container) =>
    container.read(myQrTokenProvider(_eventId)).valueOrNull?['token'] as String?;

void main() {
  late MockEventService service;

  setUp(() {
    service = MockEventService();
  });

  group('AttendanceQrScreen — inactive (pre-activation)', () {
    testWidgets('shows the activation countdown message when no token exists',
        (tester) async {
      when(() => service.getMyQrToken(_eventId)).thenAnswer((_) async => null);
      // The self-issuing probe answers `not_in_window` (pre-activation).
      when(() => service.rotateQrToken(_eventId)).thenAnswer((_) async => null);
      await _pump(tester, service: service, eventNotifier: _FakeUpcomingEventNotifier.new);
      // The self-issuing probe (rotate_qr_token RPC) resolves one frame
      // after the initial fetch.
      await tester.pump();

      expect(find.textContaining('El código QR se activará 92 minutos antes'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
    });
  });

  group('AttendanceQrScreen — server pending (EEDG not deployed)', () {
    testWidgets(
        'inside the activation window with no server token shows the '
        'server-pending state with retry', (tester) async {
      when(() => service.getMyQrToken(_eventId)).thenAnswer((_) async => null);
      // The self-issuing probe yields no token (RPC unavailable in this
      // scenario) — the state stays server-pending and retryable.
      when(() => service.rotateQrToken(_eventId)).thenAnswer((_) async => null);
      await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);
      // The self-issuing probe (rotate_qr_token RPC, mocked to no payload)
      // resolves one frame after the initial fetch.
      await tester.pump();

      expect(find.text('No se pudo generar el código QR todavía. El servidor aún no está rotando tokens.'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('server-pending retry re-fetches the token', (tester) async {
      final answers = <Map<String, dynamic>?>[null, _token('t1')];
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => answers.removeAt(0));
      final container =
          await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);

      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(_displayedToken(container), 't1');
      verify(() => service.getMyQrToken(_eventId)).called(2);
    });
  });

  group('AttendanceQrScreen — self-issuing token (rotate_qr_token RPC)', () {
    testWidgets('issues the first token via the RPC when the server has none',
        (tester) async {
      when(() => service.getMyQrToken(_eventId)).thenAnswer((_) async => null);
      when(() => service.rotateQrToken(_eventId)).thenAnswer((_) async => {
            'status': 'ok',
            'token': 't1',
            'expiresAt': DateTime.now()
                .add(const Duration(seconds: 15))
                .toIso8601String(),
          });
      final container = await _pump(
          tester,
          service: service,
          eventNotifier: _FakeWindowOpenEventNotifier.new);

      // The QR loop is now alive: inside the window, a missing server token
      // is issued instead of the eternal server-pending state.
      expect(find.byType(QrImageView), findsOneWidget);
      expect(_displayedToken(container), 't1');
      verify(() => service.rotateQrToken(_eventId)).called(1);
    });

    testWidgets('rotation at countdown 0 calls the RPC before refetching',
        (tester) async {
      final answers = <Map<String, dynamic>?>[_token('t1'), _token('t2')];
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => answers.removeAt(0));
      final container = await _pump(
          tester,
          service: service,
          eventNotifier: _FakeWindowOpenEventNotifier.new);
      expect(find.text('Nuevo código en: 15'), findsOneWidget);

      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      await tester.pump();

      verify(() => service.rotateQrToken(_eventId)).called(1);
      expect(_displayedToken(container), 't2');
      expect(find.text('Nuevo código en: 15'), findsOneWidget);
    });
  });

  group('AttendanceQrScreen — active (countdown + rotation)', () {
    testWidgets('renders the white-on-black QR with the countdown label',
        (tester) async {
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => _token('t1'));
      final container =
          await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);

      expect(find.byType(QrImageView), findsOneWidget);
      expect(_displayedToken(container), 't1');
      expect(find.text('Nuevo código en: 15'), findsOneWidget);
      expect(find.text('SAMAY'), findsOneWidget);
    });

    testWidgets('countdown ticks down and refetches at 0 (rotation contract)',
        (tester) async {
      final answers = <Map<String, dynamic>?>[_token('t1'), _token('t2')];
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => answers.removeAt(0));
      final container =
          await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);
      expect(find.text('Nuevo código en: 15'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Nuevo código en: 8'), findsOneWidget);

      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      await tester.pump();

      verify(() => service.getMyQrToken(_eventId)).called(2);
      expect(_displayedToken(container), 't2');
      // The display window restarts for the rotated token.
      expect(find.text('Nuevo código en: 15'), findsOneWidget);
    });
  });

  group('AttendanceQrScreen — expired', () {
    testWidgets('auto-refetches once and renders the new token', (tester) async {
      final answers = <Map<String, dynamic>?>[
        _token('t-old', expiresIn: const Duration(seconds: -5)),
        _token('t-new'),
      ];
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => answers.removeAt(0));
      final container =
          await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);

      // Expired state renders while the periodic tick hasn't fired yet…
      expect(find.text('El código QR expiró. Generando uno nuevo…'), findsOneWidget);

      // …then the 1s tick detects the server expiry and refetches.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();

      verify(() => service.getMyQrToken(_eventId)).called(2);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(_displayedToken(container), 't-new');
    });

    testWidgets('stays retryable when the refetch still yields an expired token',
        (tester) async {
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => _token('t-old', expiresIn: const Duration(seconds: -5)));
      await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();

      expect(find.text('El código QR expiró. Generando uno nuevo…'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
    });
  });

  group('AttendanceQrScreen — ended', () {
    testWidgets('shows the post-event message (no QR needed)', (tester) async {
      when(() => service.getMyQrToken(_eventId))
          .thenAnswer((_) async => _token('t1'));
      await _pump(tester, service: service, eventNotifier: _FakeEndedEventNotifier.new);

      expect(
        find.text('El evento ha finalizado. Ya no es necesario el código QR.'),
        findsOneWidget,
      );
      expect(find.byType(QrImageView), findsNothing);
    });
  });

  group('AttendanceQrScreen — load errors', () {
    testWidgets('token fetch failure shows the retryable ErrorView',
        (tester) async {
      when(() => service.getMyQrToken(_eventId)).thenThrow(
        const PostgrestException(
          message: 'could not connect to server',
          code: '28000',
        ),
      );
      await _pump(tester, service: service, eventNotifier: _FakeWindowOpenEventNotifier.new);

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('No se pudo cargar el código QR.'), findsOneWidget);
    });
  });
}
