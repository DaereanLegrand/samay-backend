import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/qr/screens/qr_scanner_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// QR scanner screen (QRSC foundation, I-57):
/// permission flow (denied rationale / permanently-denied settings dialog /
/// granted camera), scan callback → `validateQrToken`, confirmation +
/// auto-return, QRSC exact error copy per RPC status, retryable network
/// error when the RPC is missing (EEDG blocked). The camera widget is
/// injected via [QrScannerScreen.scannerBuilder]; permissions via
/// [PermissionService] with a fake requester (I-28 seam).
const _eventId = '22222222-2222-2222-2222-222222222222';

class MockEventService extends Mock implements EventService {}

class _FakeEventDetailNotifier extends EventDetailNotifier {
  @override
  Future<Map<String, dynamic>> build(String arg) async => {
        'id': _eventId,
        'name': 'Rave en el garaje',
        'status': 'live',
        'starts_at': DateTime.now().toIso8601String(),
        'ends_at': DateTime.now().add(const Duration(hours: 3)).toIso8601String(),
      };
}

/// Fake camera widget: renders a button that fires the on-detect callback
/// with [token] (mobile_scanner cannot run in widget tests — same
/// thin-wrapper seam as PermissionService).
Widget _fakeScanner(String token, {required ValueChanged<String> onDetect}) {
  return Material(
    color: Colors.black,
    child: Center(
      child: TextButton(
        onPressed: () => onDetect(token),
        child: const Text('FAKE-CAM'),
      ),
    ),
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required MockEventService service,
  PermissionService? permissions,
  QrScannerViewBuilder? scannerBuilder,
}) async {
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(service),
      eventDetailProvider.overrideWith(_FakeEventDetailNotifier.new),
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
        home: QrScannerScreen(
          eventId: _eventId,
          permissions: permissions,
          scannerBuilder: scannerBuilder,
        ),
      ),
    ),
  );
  // Bounded settle: while the permission dialog is open the 'checking'
  // spinner behind it animates forever, so pumpAndSettle would time out.
  // Two pumps flush the permission future + the first frames of the dialog.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

void main() {
  late MockEventService service;

  setUp(() {
    service = MockEventService();
  });

  group('QrScannerScreen — permission flow (I-28 seam)', () {
    testWidgets('denied shows the rationale snackbar + camera panel',
        (tester) async {
      final permissions = PermissionService(
        request: (_) async => PermissionStatus.denied,
      );
      await _pump(tester, service: service, permissions: permissions);

      expect(
        find.text('Para escanear códigos QR y tomar fotos, Samay necesita acceso a tu cámara.'),
        findsOneWidget,
      );
      expect(find.text('Se necesita acceso a la cámara para escanear.'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('permanently denied offers the settings dialog', (tester) async {
      var settingsOpened = false;
      final permissions = PermissionService(
        request: (_) async => PermissionStatus.permanentlyDenied,
        openSettings: () async {
          settingsOpened = true;
          return true;
        },
      );
      await _pump(tester, service: service, permissions: permissions);

      expect(find.text('Acceso a la cámara'), findsOneWidget);
      expect(find.text('Abrir ajustes'), findsOneWidget);

      await tester.tap(find.text('Abrir ajustes'));
      await tester.pumpAndSettle();
      expect(settingsOpened, isTrue);
      expect(find.text('Se necesita acceso a la cámara para escanear.'), findsOneWidget);
    });

    testWidgets('granted renders the camera view', (tester) async {
      final permissions = PermissionService(
        request: (_) async => PermissionStatus.granted,
      );
      await _pump(
        tester,
        service: service,
        permissions: permissions,
        scannerBuilder: ({required onDetect}) => _fakeScanner('abc', onDetect: onDetect),
      );

      expect(find.text('FAKE-CAM'), findsOneWidget);
      expect(find.text('Evento: Rave en el garaje'), findsOneWidget);
      expect(find.text('Escanea el código QR del asistente'), findsOneWidget);
    });
  });

  group('QrScannerScreen — scan flow', () {
    Future<void> pumpGranted(WidgetTester tester) => _pump(
          tester,
          service: service,
          permissions: PermissionService(request: (_) async => PermissionStatus.granted),
          scannerBuilder: ({required onDetect}) => _fakeScanner('abc-123', onDetect: onDetect),
        );

    testWidgets('scan callback validates the token and confirms',
        (tester) async {
      when(() => service.validateQrToken(_eventId, 'abc-123')).thenAnswer(
        (_) async => {
          'status': 'confirmed',
          'attendeeUserId': '11111111-1111-1111-1111-111111111111',
          'attendeeName': 'ana',
          'confirmedAt': '2026-08-09T23:00:00Z',
        },
      );
      await pumpGranted(tester);

      await tester.tap(find.text('FAKE-CAM'));
      await tester.pump();

      verify(() => service.validateQrToken(_eventId, 'abc-123')).called(1);
      expect(find.text('¡Asistencia confirmada!'), findsOneWidget);
      expect(find.text('Asistente: ana'), findsOneWidget);

      // "Listo" auto-return after ~2s (QRSC success flow).
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('¡Asistencia confirmada!'), findsNothing);
    });

    testWidgets('shows the exact QRSC copy for each business rejection',
        (tester) async {
      const cases = <(Map<String, dynamic>, String)>[
        ({'status': 'expired'},
            'Código QR expirado. Pide al asistente que actualice su QR.'),
        ({'status': 'already_scanned'}, 'Este código QR ya fue escaneado.'),
        ({'status': 'not_invited'},
            'El usuario no está invitado a este evento.'),
        ({'status': 'not_in_window'},
            'El evento no está activo para confirmación de asistencia.'),
        ({'status': 'not_promotor'},
            'No tienes permisos para escanear en este evento.'),
        ({'status': 'invalid_token'}, 'Código QR inválido.'),
      ];
      for (final (payload, copy) in cases) {
        when(() => service.validateQrToken(_eventId, 'abc-123'))
            .thenAnswer((_) async => payload);
        await pumpGranted(tester);

        await tester.tap(find.text('FAKE-CAM'));
        await tester.pump();
        await tester.pump();

        expect(find.text(copy), findsOneWidget, reason: 'status ${payload['status']}');

        // Business rejections auto-clear back to the ready state.
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(find.text(copy), findsNothing);
      }
    });

    testWidgets('network/RPC failure shows the retryable error and retries',
        (tester) async {
      var calls = 0;
      when(() => service.validateQrToken(_eventId, 'abc-123'))
          .thenAnswer((_) async {
        calls++;
        if (calls == 1) {
          throw const PostgrestException(
            message: 'Could not find the function public.validate_qr_token',
            code: 'PGRST202',
          );
        }
        return {'status': 'confirmed', 'attendeeName': 'ana'};
      });
      await pumpGranted(tester);

      await tester.tap(find.text('FAKE-CAM'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Error de conexión. Reintentar...'), findsOneWidget);

      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump();

      verify(() => service.validateQrToken(_eventId, 'abc-123')).called(2);
      expect(find.text('¡Asistencia confirmada!'), findsOneWidget);
    });

    testWidgets('ignores duplicate detections while a scan is in flight',
        (tester) async {
      when(() => service.validateQrToken(_eventId, 'abc-123')).thenAnswer(
        (_) async => {
          'status': 'confirmed',
          'attendeeName': 'ana',
        },
      );
      await pumpGranted(tester);

      await tester.tap(find.text('FAKE-CAM'));
      await tester.pump();
      // A second detection while processing must not re-validate.
      await tester.tap(find.text('FAKE-CAM'));
      await tester.pump();
      await tester.pump();

      verify(() => service.validateQrToken(_eventId, 'abc-123')).called(1);
    });
  });
}
