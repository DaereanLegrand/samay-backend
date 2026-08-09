import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/features/groups/create_group_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// PermissionService tests (SEC-07 / DEP-11, agent I-28).
///
/// `permission_handler` is a platform plugin (MethodChannel) that cannot run
/// in the widget-test environment, so `PermissionService` is designed with an
/// injectable `request` function and an injectable `openSettings` function.
/// Every test fakes those seams — no plugin channel is ever touched, exactly
/// like the services in `test/services/supabase_service_test.dart` mock the
/// Supabase client.
const _rationale = 'Necesitamos tus fotos para elegir la portada';
const _settingsTitle = 'Permiso bloqueado';
const _settingsBody = 'Activa el permiso en los ajustes del sistema';
const _settingsAction = 'Abrir ajustes';
const _cancelAction = 'Cancelar';

/// Harness screen exposing one button that runs
/// `PermissionService.ensureWithPrompt` and reports the returned bool.
class _PromptHarness extends StatefulWidget {
  const _PromptHarness({required this.service});

  final PermissionService service;

  @override
  State<_PromptHarness> createState() => _PromptHarnessState();
}

class _PromptHarnessState extends State<_PromptHarness> {
  bool? _result;

  Future<void> _run() async {
    final ok = await widget.service.ensureWithPrompt(
      context,
      permission: ph.Permission.photos,
      rationale: _rationale,
      settingsTitle: _settingsTitle,
      settingsBody: _settingsBody,
      settingsAction: _settingsAction,
      cancelAction: _cancelAction,
    );
    if (mounted) setState(() => _result = ok);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: _run, child: const Text('pedir permiso')),
            if (_result != null) Text('resultado: $_result'),
          ],
        ),
      ),
    );
  }
}

Future<void> _pumpPrompt(WidgetTester tester, PermissionService service) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _PromptHarness(service: service),
    ),
  );
}

Future<void> _pumpGroupScreen(
  WidgetTester tester,
  PermissionService service,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CreateGroupScreen(permissions: service),
    ),
  );
}

void main() {
  group('PermissionService.ensure maps PermissionStatus to PermissionOutcome',
      () {
    test('granted -> granted', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.granted,
      );
      expect(await service.ensure(ph.Permission.photos),
          PermissionOutcome.granted);
    });

    test('limited (iOS partial photo access) -> granted', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.limited,
      );
      expect(await service.ensure(ph.Permission.photos),
          PermissionOutcome.granted);
    });

    test('provisional -> granted', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.provisional,
      );
      expect(await service.ensure(ph.Permission.photos),
          PermissionOutcome.granted);
    });

    test('denied -> denied', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.denied,
      );
      expect(await service.ensure(ph.Permission.photos),
          PermissionOutcome.denied);
    });

    test('permanentlyDenied -> permanentlyDenied', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.permanentlyDenied,
      );
      expect(
          await service.ensure(ph.Permission.photos),
          PermissionOutcome.permanentlyDenied);
    });

    test('restricted -> denied (OS restriction is not usable)', () async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.restricted,
      );
      expect(await service.ensure(ph.Permission.photos),
          PermissionOutcome.denied);
    });

    test('requests exactly the permission passed in', () async {
      ph.Permission? requested;
      final service = PermissionService(
        request: (p) async {
          requested = p;
          return ph.PermissionStatus.granted;
        },
      );
      await service.ensure(ph.Permission.camera);
      expect(requested, ph.Permission.camera);
    });
  });

  group('PermissionService.openSettings', () {
    test('delegates to the injected open-settings function', () async {
      var opened = false;
      final service = PermissionService(
        openSettings: () async {
          opened = true;
          return true;
        },
      );
      expect(await service.openSettings(), isTrue);
      expect(opened, isTrue);
    });
  });

  group('PermissionService.ensureWithPrompt', () {
    testWidgets('granted: returns true, shows no SnackBar and no dialog',
        (tester) async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.granted,
      );
      await _pumpPrompt(tester, service);

      await tester.tap(find.text('pedir permiso'));
      await tester.pumpAndSettle();

      expect(find.text('resultado: true'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('denied: shows the rationale SnackBar and returns false',
        (tester) async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.denied,
      );
      await _pumpPrompt(tester, service);

      await tester.tap(find.text('pedir permiso'));
      await tester.pumpAndSettle();

      expect(find.text('resultado: false'), findsOneWidget);
      expect(find.text(_rationale), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'permanentlyDenied: cancel closes the dialog, settings not opened',
        (tester) async {
      var settingsOpened = false;
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.permanentlyDenied,
        openSettings: () async {
          settingsOpened = true;
          return true;
        },
      );
      await _pumpPrompt(tester, service);

      await tester.tap(find.text('pedir permiso'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(_settingsTitle), findsOneWidget);
      expect(find.text(_settingsBody), findsOneWidget);

      await tester.tap(find.text(_cancelAction));
      await tester.pumpAndSettle();

      expect(find.text('resultado: false'), findsOneWidget);
      expect(settingsOpened, isFalse,
          reason: 'cancelling must not open the app settings');
    });

    testWidgets('permanentlyDenied: "Abrir ajustes" opens app settings',
        (tester) async {
      var settingsOpened = false;
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.permanentlyDenied,
        openSettings: () async {
          settingsOpened = true;
          return true;
        },
      );
      await _pumpPrompt(tester, service);

      await tester.tap(find.text('pedir permiso'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(_settingsAction));
      await tester.pumpAndSettle();

      expect(settingsOpened, isTrue,
          reason: 'confirming the dialog must open the app settings');
      expect(find.text('resultado: false'), findsOneWidget);
    });
  });

  group('CreateGroupScreen permission wiring (SEC-07)', () {
    testWidgets(
        'denied photo permission: requests Permission.photos and shows the '
        'localized rationale SnackBar', (tester) async {
      ph.Permission? requested;
      final service = PermissionService(
        request: (p) async {
          requested = p;
          return ph.PermissionStatus.denied;
        },
      );
      await _pumpGroupScreen(tester, service);

      await tester.tap(find.text('Agregar foto de portada'));
      await tester.pumpAndSettle();

      expect(requested, ph.Permission.photos,
          reason: 'the gallery picker must request photo-library access first');
      final l10n =
          await AppLocalizations.delegate.load(const Locale('es'));
      expect(find.text(l10n.permissionsPhotoRationale), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('permanently denied: shows the settings dialog with the '
        'localized action', (tester) async {
      final service = PermissionService(
        request: (_) async => ph.PermissionStatus.permanentlyDenied,
        openSettings: () async => true,
      );
      await _pumpGroupScreen(tester, service);

      await tester.tap(find.text('Agregar foto de portada'));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('es'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.permissionsSettingsTitle), findsOneWidget);
      expect(find.text(l10n.permissionsOpenSettings), findsOneWidget);
      expect(find.text(l10n.commonCancel), findsOneWidget);
    });
  });
}
