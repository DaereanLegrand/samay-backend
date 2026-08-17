import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/services/group_service.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/features/events/screens/create_event_screen.dart';
import 'package:samay/features/events/logic/event_form_data.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_button.dart';

const _groupId = '33333333-3333-3333-3333-333333333333';
const _eventId = '66666666-6666-6666-6666-666666666666';

class _MockEventService extends Mock implements EventService {}

class _MockMediaService extends Mock implements MediaService {}

class _MockGroupService extends Mock implements GroupService {}

/// Solid-color PNG via Canvas → `toByteData` — a real, decodable image for the
/// cover-picker preview (`Image.file` renders it in the test).
Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF4B8BBE),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Pumps [widget] (standalone `/create`) or the group route under a GoRouter
/// so `context.push` after a successful submit can be asserted against the
/// real router stack (same harness shape as `groups_screens_test.dart`).
Future<(ProviderContainer, GoRouter)> _pumpScreen(
  WidgetTester tester,
  Widget widget,
  String initialLocation,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  // The form is a single long scroll; a tall viewport keeps every section
  // built so below-fold finders and taps work without scrolling.
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold()),
      GoRoute(path: '/create', builder: (_, _) => widget),
      GoRoute(
        path: '/group/:groupId/create-event',
        builder: (_, state) =>
            CreateEventScreen(groupId: state.pathParameters['groupId']),
      ),
      GoRoute(
        path: '/event/:eventId',
        builder: (_, state) => Scaffold(
          body: Text('event-detail-${state.pathParameters['eventId']}'),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container, router);
}

/// The default mock set: myGroups served, cover upload + event create stubbed.
List<Override> _defaultOverrides(
  _MockEventService event,
  _MockMediaService media,
  _MockGroupService group,
) {
  when(() => group.getMyGroups()).thenAnswer(
    (_) async => [
      {'id': _groupId, 'name': 'Disco Crew', 'my_role': 'promotor'},
    ],
  );
  return [
    eventServiceProvider.overrideWithValue(event),
    mediaServiceProvider.overrideWithValue(media),
    groupServiceProvider.overrideWithValue(group),
  ];
}

/// Taps the submit button (the AppBar is title-less since the LUXE restyle
/// de-duplicated 'Crear evento' — the VButton's own text is the only match).
Future<void> _tapSubmit(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(VButton, 'Crear evento'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
  });

  EventFormData base() => EventFormData(
    name: 'Noche de techno',
    startsAt: DateTime.utc(2026, 9, 1, 20),
    endsAt: DateTime.utc(2026, 9, 1, 23),
  );

  group('EventFormData validation (ECRT steps 1-5)', () {
    test('empty name fails with nameRequired', () {
      expect(
        base().copyWith(name: '  ').validate(),
        contains(EventFormError.nameRequired),
      );
    });

    test('endsAt at or before startsAt fails with invalidTimeRange', () {
      expect(
        base().copyWith(endsAt: base().startsAt).validate(),
        contains(EventFormError.invalidTimeRange),
      );
      expect(
        base()
            .copyWith(
              endsAt: base().startsAt.subtract(const Duration(hours: 1)),
            )
            .validate(),
        contains(EventFormError.invalidTimeRange),
      );
    });

    test('casual with a positive pool fails with casualPoolMustBeZero', () {
      expect(
        base().copyWith(type: EventType.casual, preshardsPool: 500).validate(),
        contains(EventFormError.casualPoolMustBeZero),
      );
    });

    test('juerga without the location confirmation fails', () {
      expect(
        base().copyWith(type: EventType.juerga).validate(),
        contains(EventFormError.juergaLocationUnconfirmed),
      );
      expect(
        base()
            .copyWith(type: EventType.juerga, juergaLocationConfirmed: true)
            .validate(),
        isNot(contains(EventFormError.juergaLocationUnconfirmed)),
      );
    });

    test('group visibility without a group fails with groupRequired', () {
      expect(
        base().copyWith(visibility: EventVisibility.group).validate(),
        contains(EventFormError.groupRequired),
      );
    });

    test(
      'public visibility without a join mode fails with joinModeRequired',
      () {
        expect(
          base().copyWith(joinMode: null).validate(),
          contains(EventFormError.joinModeRequired),
        );
      },
    );

    test('a complete form validates clean', () {
      expect(
        base().copyWith(type: EventType.tono, preshardsPool: 1000).validate(),
        isEmpty,
      );
      expect(
        base()
            .copyWith(
              visibility: EventVisibility.group,
              groupId: _groupId,
              joinMode: null,
            )
            .validate(),
        isEmpty,
      );
    });

    test('copyWith can null out optional fields', () {
      final form = base()
          .copyWith(
            visibility: EventVisibility.group,
            groupId: _groupId,
            joinMode: null,
            preshardsCapPerUser: 100,
          )
          .copyWith(groupId: null, preshardsCapPerUser: null);
      expect(form.groupId, isNull);
      expect(form.preshardsCapPerUser, isNull);
    });
  });

  group('EventFormData payload (createEvent contract)', () {
    test('public casual event: join_mode wired, group null, pool forced 0', () {
      final payload = EventFormData(
        name: ' Películas ',
        description: '  ',
        type: EventType.casual,
        startsAt: DateTime.utc(2026, 9, 1, 20),
        endsAt: DateTime.utc(2026, 9, 1, 23),
        locationName: 'Casa de Ana',
        preshardsPool: 500, // must be neutralized for casual
      ).toPayload();

      expect(payload['name'], 'Películas');
      expect(payload['description'], isNull);
      expect(payload['type'], 'casual');
      expect(payload['starts_at'], '2026-09-01T20:00:00.000Z');
      expect(payload['ends_at'], '2026-09-01T23:00:00.000Z');
      expect(payload['location_name'], 'Casa de Ana');
      expect(payload['group_id'], isNull);
      expect(payload['join_mode'], 'open');
      expect(payload['preshards_pool'], 0);
      expect(payload['preshards_cap_per_user'], isNull);
      expect(payload['preshards_remainder_action'], isNull);
    });

    test(
      'group-scoped event: group_id wired, join_mode null (ECRT step 3)',
      () {
        final payload = EventFormData(
          name: 'Tono en el bar',
          type: EventType.tono,
          startsAt: DateTime.utc(2026, 9, 1, 20),
          endsAt: DateTime.utc(2026, 9, 1, 23),
          visibility: EventVisibility.group,
          groupId: _groupId,
          joinMode: EventJoinMode.open, // must be neutralized for groups
          preshardsPool: 1000,
          preshardsCapPerUser: 100,
          remainderAction: EventRemainderAction.redistribute,
        ).toPayload();

        expect(payload['group_id'], _groupId);
        expect(payload['join_mode'], isNull);
        expect(payload['preshards_pool'], 1000);
        expect(payload['preshards_cap_per_user'], 100);
        expect(payload['preshards_remainder_action'], 'redistribute');
      },
    );

    test('preshardsEnabled is false only for casual', () {
      DateTime now() => DateTime.now();
      expect(
        EventFormData(
          startsAt: now(),
          endsAt: now().add(const Duration(hours: 1)),
        ).preshardsEnabled,
        isFalse,
      );
      expect(
        EventFormData(
          type: EventType.juerga,
          startsAt: now(),
          endsAt: now().add(const Duration(hours: 1)),
        ).preshardsEnabled,
        isTrue,
      );
    });

    test('sanitized applies InputSanitizer caps and strips control chars', () {
      final form = base()
          .copyWith(
            name: '  ' * 100 + 'X', // over the 50-grapheme cap
            description: 'descripción con caracteres de control\u0000',
          )
          .sanitized();
      expect(form.name.length, lessThanOrEqualTo(EventFormData.nameMaxLength));
      expect(form.description, contains('descripción'));
      expect(form.description.contains('\u0000'), isFalse);
    });
  });

  group('CreateEventScreen', () {
    testWidgets('renders the full form skeleton', (tester) async {
      await _pumpScreen(
        tester,
        const CreateEventScreen(),
        '/create',
        _defaultOverrides(
          _MockEventService(),
          _MockMediaService(),
          _MockGroupService(),
        ),
      );
      expect(
        find.text('Crear evento'),
        findsOneWidget,
        reason:
            'LUXE directive #8: the title is de-duplicated — only the '
            'submit CTA carries it (no AppBar duplicate)',
      );
      expect(find.text('Nombre del evento'), findsOneWidget);
      expect(find.text('Descripción (opcional)'), findsOneWidget);
      expect(find.text('Tipo de evento'), findsOneWidget);
      expect(find.text('Casual'), findsOneWidget);
      expect(find.text('Juerga'), findsOneWidget);
      expect(find.text('Tono'), findsOneWidget);
      expect(find.text('Inicio'), findsOneWidget);
      expect(find.text('Fin'), findsOneWidget);
      expect(find.text('Dirección / lugar'), findsOneWidget);
      expect(find.text('Visibilidad'), findsOneWidget);
      expect(find.text('Modo de acceso'), findsOneWidget);
      // Casual is the default type: the preshards section stays hidden.
      expect(find.text('Pool de preshards'), findsNothing);
    });

    testWidgets('cover slot uses the token surfaces — never raw greys '
        '(DISCO §2.1, create_group precedent)', (tester) async {
      await _pumpScreen(
        tester,
        const CreateEventScreen(),
        '/create',
        _defaultOverrides(
          _MockEventService(),
          _MockMediaService(),
          _MockGroupService(),
        ),
      );

      final label = tester.widget<Text>(find.text('Agregar foto de portada'));
      expect(
        label.style?.color,
        AppColors.mutedStrong,
        reason: 'cover-slot label is mutedStrong (§2.4), not Colors.grey',
      );

      final camera = tester.widget<Icon>(find.byIcon(Icons.camera_alt));
      expect(
        camera.color,
        AppColors.muted,
        reason: 'cover-slot camera icon is the muted token, not Colors.grey',
      );

      final slot = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Agregar foto de portada'),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = slot.decoration! as BoxDecoration;
      expect(
        decoration.color,
        AppColors.surfaceAlt,
        reason: 'empty cover slot fill is §5.8 skeleton-base surface',
      );
      expect(
        (decoration.border! as Border).top.color,
        AppColors.border,
        reason: 'cover slot ring is the §2.1 interactive-outline token',
      );
    });

    testWidgets('date-row labels render mutedStrong (§5.2 label rule)', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        const CreateEventScreen(),
        '/create',
        _defaultOverrides(
          _MockEventService(),
          _MockMediaService(),
          _MockGroupService(),
        ),
      );

      for (final label in ['Inicio', 'Fin']) {
        // The InputDecorator applies the label style via an animated default
        // text style, so the Text's own style is null — assert the
        // decoration's labelStyle instead (§5.2/§2.4).
        final decorator = tester.widget<InputDecorator>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(InputDecorator),
          ),
        );
        expect(
          decorator.decoration.labelStyle?.color,
          AppColors.mutedStrong,
          reason:
              'the $label label is mutedStrong (#999999 AA), never '
              'muted #666666 (fails 1.4.3 at normal size)',
        );
      }
    });

    testWidgets(
      'switching to Juerga shows the location warning; cancel keeps the '
      'previous type (ECRT step 4)',
      (tester) async {
        await _pumpScreen(
          tester,
          const CreateEventScreen(),
          '/create',
          _defaultOverrides(
            _MockEventService(),
            _MockMediaService(),
            _MockGroupService(),
          ),
        );

        await tester.tap(find.text('Juerga'));
        await tester.pumpAndSettle();
        expect(find.text('Aviso de ubicación'), findsOneWidget);
        expect(
          find.text(
            'Los invitados verán esta dirección. Solo invita a personas en quienes confíes.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.text('Aviso de ubicación'), findsNothing);
        expect(
          find.text('Pool de preshards'),
          findsNothing,
          reason: 'cancel must not switch the type',
        );

        await tester.tap(find.text('Juerga'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirmar'));
        await tester.pumpAndSettle();
        expect(find.text('Aviso de ubicación'), findsNothing);
        expect(find.text('Pool de preshards'), findsOneWidget);
        expect(find.text('Tope por asistente (opcional)'), findsOneWidget);
        expect(find.text('Devolver proporcionalmente'), findsOneWidget);
        expect(find.text('Redistribuir entre asistentes'), findsOneWidget);
      },
    );

    testWidgets('Tono enables the preshards section without a warning', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        const CreateEventScreen(),
        '/create',
        _defaultOverrides(
          _MockEventService(),
          _MockMediaService(),
          _MockGroupService(),
        ),
      );
      expect(find.text('Pool de preshards'), findsNothing);

      await tester.tap(find.text('Tono'));
      await tester.pumpAndSettle();
      expect(find.text('Aviso de ubicación'), findsNothing);
      expect(find.text('Pool de preshards'), findsOneWidget);
    });

    testWidgets(
      'group visibility reveals the myGroups dropdown and hides join mode '
      '(group-scoped = invitation-only)',
      (tester) async {
        final group = _MockGroupService();
        when(() => group.getMyGroups()).thenAnswer(
          (_) async => [
            {'id': _groupId, 'name': 'Disco Crew', 'my_role': 'promotor'},
            {
              'id': '44444444-4444-4444-4444-444444444444',
              'name': 'Vinyl Lovers',
              'my_role': 'co_promotor',
            },
          ],
        );
        await _pumpScreen(tester, const CreateEventScreen(), '/create', [
          eventServiceProvider.overrideWithValue(_MockEventService()),
          mediaServiceProvider.overrideWithValue(_MockMediaService()),
          groupServiceProvider.overrideWithValue(group),
        ]);

        expect(find.text('Modo de acceso'), findsOneWidget);
        expect(find.text('Selecciona un grupo'), findsNothing);

        await tester.tap(find.text('Grupo'));
        await tester.pumpAndSettle();
        expect(find.text('Modo de acceso'), findsNothing);
        expect(find.text('Selecciona un grupo'), findsOneWidget);

        await tester.tap(find.text('Selecciona un grupo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disco Crew').last);
        await tester.pumpAndSettle();
        expect(find.text('Disco Crew'), findsOneWidget);
      },
    );

    testWidgets(
      'route prefill: group-scoped by default with the group selected',
      (tester) async {
        await _pumpScreen(
          tester,
          const CreateEventScreen(groupId: _groupId),
          '/group/$_groupId/create-event',
          _defaultOverrides(
            _MockEventService(),
            _MockMediaService(),
            _MockGroupService(),
          ),
        );
        expect(find.text('Modo de acceso'), findsNothing);
        expect(find.text('Disco Crew'), findsOneWidget);
      },
    );

    testWidgets('casual submit calls createEvent with a forced-zero pool and '
        'navigates to the event detail route', (tester) async {
      final event = _MockEventService();
      when(
        () => event.createEvent(any()),
      ).thenAnswer((_) async => {'id': _eventId, 'invite_token': 'tok-1'});
      final (_, router) = await _pumpScreen(
        tester,
        const CreateEventScreen(),
        '/create',
        _defaultOverrides(event, _MockMediaService(), _MockGroupService()),
      );

      await tester.enterText(find.byType(TextField).first, 'Cine y pizza');
      await tester.enterText(
        find.byType(TextField).at(1),
        'Clásico de los martes',
      );
      await tester.enterText(find.byType(TextField).at(2), 'Casa de Ana');
      await _tapSubmit(tester);

      final captured =
          verify(() => event.createEvent(captureAny())).captured.single as Map;
      expect(captured['name'], 'Cine y pizza');
      expect(captured['description'], 'Clásico de los martes');
      expect(captured['type'], 'casual');
      expect(
        captured['preshards_pool'],
        0,
        reason: 'casual is forced to a zero pool client-side',
      );
      expect(captured['location_name'], 'Casa de Ana');
      expect(captured['cover_url'], isNull);
      expect(DateTime.parse(captured['starts_at'] as String), isA<DateTime>());
      expect(DateTime.parse(captured['ends_at'] as String), isA<DateTime>());

      expect(router.state.matchedLocation, RoutePaths.eventDetail(_eventId));
      expect(find.text('event-detail-$_eventId'), findsOneWidget);
    });

    testWidgets(
      'juerga submit with a pool wires preshards + remainder into the '
      'payload',
      (tester) async {
        final event = _MockEventService();
        when(
          () => event.createEvent(any()),
        ).thenAnswer((_) async => {'id': _eventId, 'invite_token': 'tok-1'});
        await _pumpScreen(
          tester,
          const CreateEventScreen(),
          '/create',
          _defaultOverrides(event, _MockMediaService(), _MockGroupService()),
        );

        await tester.enterText(
          find.byType(TextField).first,
          'Juerga en el sótano',
        );
        await tester.tap(find.text('Juerga'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirmar'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).at(3), '1500');
        await tester.enterText(find.byType(TextField).at(4), '200');
        await tester.tap(find.text('Redistribuir entre asistentes'));
        await tester.pumpAndSettle();
        await _tapSubmit(tester);

        final captured =
            verify(() => event.createEvent(captureAny())).captured.single
                as Map;
        expect(captured['type'], 'juerga');
        expect(captured['preshards_pool'], 1500);
        expect(captured['preshards_cap_per_user'], 200);
        expect(captured['preshards_remainder_action'], 'redistribute');
        // A public (non-group) juerga event keeps its join mode.
        expect(captured['group_id'], isNull);
        expect(captured['join_mode'], 'open');
      },
    );

    testWidgets(
      'with a cover: uploads via MediaService.uploadEventCover first, then '
      'createEvent carries the public URL',
      (tester) async {
        final event = _MockEventService();
        final media = _MockMediaService();
        const coverUrl = 'https://cdn.example/events/event_covers/1.png';
        when(
          () => event.createEvent(any()),
        ).thenAnswer((_) async => {'id': _eventId, 'invite_token': 'tok-1'});
        when(
          () => media.uploadEventCover(any()),
        ).thenAnswer((_) async => coverUrl);

        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('event_cover_test_'),
        ))!;
        addTearDown(() => dir.deleteSync(recursive: true));
        final coverFile = File('${dir.path}/cover.png');
        final coverBytes = (await tester.runAsync(() async {
          final bytes = await _solidPng(8, 8);
          await coverFile.writeAsBytes(bytes);
          return bytes;
        }))!;
        Future<XFile?> pickCover(ImageSource source) async =>
            XFile.fromData(coverBytes, path: coverFile.path);
        final permissions = PermissionService(
          request: (_) async => ph.PermissionStatus.granted,
        );

        await _pumpScreen(
          tester,
          CreateEventScreen(permissions: permissions, coverPicker: pickCover),
          '/create',
          [
            eventServiceProvider.overrideWithValue(event),
            mediaServiceProvider.overrideWithValue(media),
            groupServiceProvider.overrideWithValue(_MockGroupService()),
          ],
        );

        await tester.tap(find.byIcon(Icons.camera_alt));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Con portada');
        await _tapSubmit(tester);

        verify(() => media.uploadEventCover(any())).called(1);
        final captured =
            verify(() => event.createEvent(captureAny())).captured.single
                as Map;
        expect(captured['cover_url'], coverUrl);
      },
    );

    testWidgets(
      'empty name: validation snackbar, no service call, no navigation',
      (tester) async {
        final event = _MockEventService();
        final (_, router) = await _pumpScreen(
          tester,
          const CreateEventScreen(),
          '/create',
          _defaultOverrides(event, _MockMediaService(), _MockGroupService()),
        );

        await tester.tap(find.widgetWithText(VButton, 'Crear evento'));
        // No pumpAndSettle here: pumpAndSettle would advance the fake clock
        // past the snackbar's 4s auto-dismiss timer before the assertion.
        // Explicit short pumps land on the visible snackbar.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.text('El nombre del evento es obligatorio'),
          findsOneWidget,
        );
        verifyNever(() => event.createEvent(any()));
        expect(router.state.matchedLocation, '/create');
      },
    );
  });
}
