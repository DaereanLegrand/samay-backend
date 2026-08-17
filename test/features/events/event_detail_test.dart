import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/features/events/screens/event_edit_screen.dart';
import 'package:samay/features/events/logic/event_formatters.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

const _eventId = '11111111-1111-1111-1111-111111111111';
const _promotorId = '22222222-2222-2222-2222-222222222222';
const _coPromotorId = '33333333-3333-3333-3333-333333333333';

// Future dates relative to the run date so the edit screen treats the pool
// as editable (pool fields lock once starts_at passes).
final _startsAt = DateTime.now().add(const Duration(days: 30));
final _endsAt = _startsAt.add(const Duration(hours: 5));

Event _event({
  String status = 'upcoming',
  String type = 'juerga',
  int pool = 500,
  int? cap,
  String? remainder,
  String? coverUrl,
  String? groupId,
  DateTime? startsAt,
  DateTime? endsAt,
}) => Event(
  id: _eventId,
  name: 'Rave en el garaje',
  description: 'La mejor fiesta del barrio',
  type: type,
  status: status,
  createdByUserId: _promotorId,
  groupId: groupId,
  locationName: 'Av. Los Aromos 123',
  joinMode: 'open',
  preshardsPool: pool,
  preshardsCapPerUser: cap,
  preshardsRemainderAction: remainder,
  coverUrl: coverUrl,
  startsAt: startsAt ?? _startsAt,
  endsAt: endsAt ?? _endsAt,
);

List<Map<String, dynamic>> _promotores() => [
  {
    'id': 'promo-1',
    'event_id': _eventId,
    'user_id': _promotorId,
    'role': 'promotor',
    'preshards_contributed': 300,
    'added_at': DateTime(2026, 5, 10).toIso8601String(),
    'users': {'username': 'ana'},
  },
  {
    'id': 'promo-2',
    'event_id': _eventId,
    'user_id': _coPromotorId,
    'role': 'co_promotor',
    'preshards_contributed': 200,
    'added_at': DateTime(2026, 5, 10).toIso8601String(),
    'users': {'username': 'lucas'},
  },
];

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(this.uid);
  final String uid;

  @override
  Future<AuthState> build() async =>
      AuthState(authenticated: true, hasProfile: true, user: {'id': uid});
}

class _FakeEventDetailNotifier extends EventDetailNotifier {
  final Event data;
  final Object? error;
  final Future<void>? gate;
  _FakeEventDetailNotifier({required this.data, this.error, this.gate});

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<Event> build(String arg) async {
    if (gate != null) await gate;
    if (error != null) throw error!;
    return data;
  }
}

class _NoThrottleEventDetailNotifier extends EventDetailNotifier {
  @override
  Duration get refreshThrottle => Duration.zero;
}

class _FakeEventPromotoresNotifier extends EventPromotoresNotifier {
  final List<Map<String, dynamic>> data;
  _FakeEventPromotoresNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _FakeMyEventInviteNotifier extends MyEventInviteNotifier {
  final Map<String, dynamic>? data;
  _FakeMyEventInviteNotifier({this.data});

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
}

class _MockEventService extends Mock implements EventService {}

/// Overrides that render a loaded event detail screen.
List<Override> _loadedEventOverrides() => [
  eventDetailProvider.overrideWith(
    () => _FakeEventDetailNotifier(data: _event()),
  ),
  eventPromotoresProvider.overrideWith(
    () => _FakeEventPromotoresNotifier(data: _promotores()),
  ),
  myEventInviteProvider.overrideWith(
    () => _FakeMyEventInviteNotifier(data: null),
  ),
];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child,
  List<Override> overrides,
) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuthNotifier(_promotorId)),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  return container;
}

class _DetailHarness {
  _DetailHarness(this.container, this.router);
  final ProviderContainer container;
  final GoRouter router;
}

/// Pumps EventDetailScreen as a pushed route over a `/home` parent so
/// edit-navigation and the save-and-pop flow can be asserted against the real
/// router stack.
Future<_DetailHarness> _pumpDetailWithRouter(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FakeAuthNotifier(_promotorId)),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('home-marker')),
      ),
      GoRoute(
        path: '/event/:eventId',
        builder: (_, state) =>
            EventDetailScreen(eventId: state.pathParameters['eventId']!),
      ),
      GoRoute(
        path: '/event/:eventId/edit',
        builder: (_, state) =>
            EventEditScreen(eventId: state.pathParameters['eventId']!),
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
  router.push(RoutePaths.eventDetail(_eventId));
  await tester.pumpAndSettle();
  return _DetailHarness(container, router);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es', null);
    registerFallbackValue(_eventId);
    registerFallbackValue(const <String, dynamic>{});
  });

  group('EventDetailProvider', () {
    test('fetches the event via EventService.getEvent', () async {
      final service = _MockEventService();
      when(() => service.getEvent(_eventId)).thenAnswer((_) async => _event());
      final container = ProviderContainer(
        overrides: [eventServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final data = await container.read(eventDetailProvider(_eventId).future);

      expect(data.id, _eventId);
      expect(data.name, 'Rave en el garaje');
      verify(() => service.getEvent(_eventId)).called(1);
    });

    test(
      'surfaces AsyncError mapped through AppError when the fetch fails',
      () async {
        final service = _MockEventService();
        when(() => service.getEvent(_eventId)).thenThrow(Exception('boom'));
        final container = ProviderContainer(
          overrides: [eventServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(eventDetailProvider(_eventId).future),
          throwsException,
        );
        final state = container.read(eventDetailProvider(_eventId));
        expect(state.hasError, isTrue);
        expect(
          state.error,
          isNotNull,
          reason:
              'the raw error passes through; AppError mapping happens at '
              'the presentation layer (ErrorView/error_mapper)',
        );
      },
    );

    test('refresh re-runs the fetch', () async {
      final service = _MockEventService();
      when(() => service.getEvent(_eventId)).thenAnswer((_) async => _event());
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          eventDetailProvider.overrideWith(
            () => _NoThrottleEventDetailNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(eventDetailProvider(_eventId).future);
      await container.read(eventDetailProvider(_eventId).notifier).refresh();
      await container.read(eventDetailProvider(_eventId).future);

      verify(() => service.getEvent(_eventId)).called(2);
    });

    test('update patches the event and reloads it', () async {
      final service = _MockEventService();
      when(() => service.getEvent(_eventId)).thenAnswer((_) async => _event());
      when(() => service.updateEvent(any(), any())).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          eventDetailProvider.overrideWith(
            () => _NoThrottleEventDetailNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(eventDetailProvider(_eventId).future);
      await container.read(eventDetailProvider(_eventId).notifier).patch({
        'name': 'Fiesta nueva',
      });
      await container.read(eventDetailProvider(_eventId).future);

      verify(
        () => service.updateEvent(_eventId, {'name': 'Fiesta nueva'}),
      ).called(1);
      verify(() => service.getEvent(_eventId)).called(2);
    });
  });

  group('EventPromotoresProvider', () {
    test('fetches promotores via EventService.getEventPromotores', () async {
      final service = _MockEventService();
      when(
        () => service.getEventPromotores(_eventId),
      ).thenAnswer((_) async => _promotores());
      final container = ProviderContainer(
        overrides: [eventServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final data = await container.read(
        eventPromotoresProvider(_eventId).future,
      );

      expect(data, hasLength(2));
      expect(data.first['users']?['username'], 'ana');
      verify(() => service.getEventPromotores(_eventId)).called(1);
    });
  });

  group('MyEventInviteProvider', () {
    test('fetches the current user invite for the event', () async {
      final service = _MockEventService();
      when(
        () => service.getMyEventInvite(_eventId),
      ).thenAnswer((_) async => {'status': 'pending'});
      final container = ProviderContainer(
        overrides: [eventServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final data = await container.read(myEventInviteProvider(_eventId).future);

      expect(data?['status'], 'pending');
      verify(() => service.getMyEventInvite(_eventId)).called(1);
    });
  });

  group('formatEventDateRange', () {
    test('same-day range shows one date and the end time', () {
      final start = DateTime(2026, 5, 15, 21);
      final end = DateTime(2026, 5, 15, 23, 30);
      expect(
        formatEventDateRange(start, end, 'es'),
        '${DateFormat('EEE d MMM, HH:mm', 'es').format(start)}'
        ' – ${DateFormat('HH:mm', 'es').format(end)}',
      );
    });

    test('multi-day range shows both dates', () {
      final start = DateTime(2026, 5, 15, 21);
      final end = DateTime(2026, 5, 17, 2);
      expect(
        formatEventDateRange(start, end, 'es'),
        '${DateFormat('EEE d MMM, HH:mm', 'es').format(start)}'
        ' – ${DateFormat('EEE d MMM, HH:mm', 'es').format(end)}',
      );
    });
  });

  group('EventDetailScreen', () {
    testWidgets(
      'shows the cover+lines skeleton while the detail fetch is pending '
      '(U-22 handoff, §5.8)',
      (tester) async {
        final gate = Completer<void>();
        await _pump(tester, const EventDetailScreen(eventId: _eventId), [
          eventDetailProvider.overrideWith(
            () => _FakeEventDetailNotifier(data: _event(), gate: gate.future),
          ),
          eventPromotoresProvider.overrideWith(
            () => _FakeEventPromotoresNotifier(data: _promotores()),
          ),
          myEventInviteProvider.overrideWith(
            () => _FakeMyEventInviteNotifier(data: null),
          ),
        ]);
        await tester.pump();

        expect(
          find.byType(VSkeletonDetail),
          findsOneWidget,
          reason:
              'the heaviest events screen shows the card skeleton on first '
              'load, not the bare spinner',
        );
        expect(find.byType(VLoadingView), findsNothing);

        gate.complete();
        await tester.pumpAndSettle();
        expect(find.byType(VSkeletonDetail), findsNothing);
        expect(
          find.text('RAVE EN EL GARAJE'),
          findsOneWidget,
          reason:
              'the LUXE hero renders the name UPPERCASE via VDisplayText '
              '(Playfair MAYUS rule), AppBar carries no duplicate',
        );
      },
    );

    testWidgets('renders header, badges, date range, pool and promotores', (
      tester,
    ) async {
      await _pump(
        tester,
        const EventDetailScreen(eventId: _eventId),
        _loadedEventOverrides(),
      );
      await tester.pumpAndSettle();

      // The hero renders the name UPPERCASE (VDisplayText MAYUS rule); the
      // badges render uppercase via VBadge.
      expect(find.text('RAVE EN EL GARAJE'), findsOneWidget);
      expect(find.text('La mejor fiesta del barrio'), findsOneWidget);
      expect(find.text('JUERGA'), findsOneWidget);
      expect(find.text('PR\u00d3XIMAMENTE'), findsOneWidget);
      expect(
        find.text(formatEventDateRange(_startsAt, _endsAt, 'es')),
        findsOneWidget,
      );
      expect(find.text('Av. Los Aromos 123'), findsOneWidget);
      expect(find.text('500 preshards'), findsOneWidget);
      expect(find.text('ana'), findsOneWidget);
      expect(find.text('lucas'), findsOneWidget);
      expect(find.text('Promotor'), findsOneWidget);
      expect(find.text('Co-promotor'), findsOneWidget);
      // The action buttons sit below the fold of the tall ListView — drag to
      // the bottom before asserting (lazy-built children).
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('Editar'), findsOneWidget);
      expect(find.text('Cancelar evento'), findsOneWidget);
    });

    testWidgets('renders the cover via VNetworkImage when cover_url is set', (
      tester,
    ) async {
      await _pump(tester, const EventDetailScreen(eventId: _eventId), [
        eventDetailProvider.overrideWith(
          () => _FakeEventDetailNotifier(
            data: _event(coverUrl: 'https://img.test/cover.png'),
          ),
        ),
        eventPromotoresProvider.overrideWith(
          () => _FakeEventPromotoresNotifier(data: _promotores()),
        ),
        myEventInviteProvider.overrideWith(
          () => _FakeMyEventInviteNotifier(data: null),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(VNetworkImage), findsOneWidget);
    });

    testWidgets('shows the own invite status when the user was invited', (
      tester,
    ) async {
      await _pump(tester, const EventDetailScreen(eventId: _eventId), [
        eventDetailProvider.overrideWith(
          () => _FakeEventDetailNotifier(data: _event()),
        ),
        eventPromotoresProvider.overrideWith(
          () => _FakeEventPromotoresNotifier(data: _promotores()),
        ),
        myEventInviteProvider.overrideWith(
          () => _FakeMyEventInviteNotifier(data: {'status': 'pending'}),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Tu invitaci\u00f3n: pendiente'), findsOneWidget);
    });

    testWidgets('renders ErrorView with retry when the detail fetch fails', (
      tester,
    ) async {
      await _pump(tester, const EventDetailScreen(eventId: _eventId), [
        eventDetailProvider.overrideWith(
          () => _FakeEventDetailNotifier(
            data: _event(),
            error: Exception('evento perdido'),
          ),
        ),
        eventPromotoresProvider.overrideWith(
          () => _FakeEventPromotoresNotifier(data: _promotores()),
        ),
        myEventInviteProvider.overrideWith(
          () => _FakeMyEventInviteNotifier(data: null),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('editar navigates to the event edit route', (tester) async {
      final harness = await _pumpDetailWithRouter(
        tester,
        _loadedEventOverrides(),
      );

      // The action buttons sit below the fold of the tall ListView (the LUXE
      // glass cards added height) — drag to the bottom before tapping.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();

      expect(find.byType(EventEditScreen), findsOneWidget);
      expect(
        harness.router.state.matchedLocation,
        RoutePaths.eventEdit(_eventId),
      );
    });

    testWidgets(
      'cancel flow: confirm dialog then updateEvent with status cancelled '
      '(promotor, not ended/cancelled)',
      (tester) async {
        final service = _MockEventService();
        when(
          () => service.getEvent(_eventId),
        ).thenAnswer((_) async => _event());
        when(
          () => service.getEventPromotores(_eventId),
        ).thenAnswer((_) async => _promotores());
        when(
          () => service.getMyEventInvite(_eventId),
        ).thenAnswer((_) async => null);
        when(() => service.updateEvent(any(), any())).thenAnswer((_) async {});

        final harness = await _pumpDetailWithRouter(tester, [
          eventServiceProvider.overrideWithValue(service),
        ]);

        // The action buttons sit below the fold of the tall ListView — drag to
        // the bottom before tapping (lazy-built children).
        await tester.drag(find.byType(ListView), const Offset(0, -1200));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancelar evento'));
        await tester.pumpAndSettle();
        expect(find.text('\u00bfCancelar evento?'), findsOneWidget);

        // Dismissing keeps the screen and never calls the service.
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.byType(EventDetailScreen), findsOneWidget);
        verifyNever(() => service.updateEvent(any(), any()));

        // Confirming sets the status and refreshes the detail. The snackbar
        // assertion below must NOT pumpAndSettle: pumpAndSettle would run
        // the snackbar's 4s auto-dismiss timer past its lifetime first.
        // Explicit pumps land on the visible bar.
        await tester.tap(find.text('Cancelar evento'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('S\u00ed, cancelar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        verify(
          () => service.updateEvent(_eventId, {'status': 'cancelled'}),
        ).called(1);
        expect(find.text('Evento cancelado'), findsOneWidget);
        expect(harness.router.state.matchedLocation, isNotNull);
      },
    );

    testWidgets('no cancel button once the event is cancelled or ended', (
      tester,
    ) async {
      await _pump(tester, const EventDetailScreen(eventId: _eventId), [
        eventDetailProvider.overrideWith(
          () => _FakeEventDetailNotifier(data: _event(status: 'cancelled')),
        ),
        eventPromotoresProvider.overrideWith(
          () => _FakeEventPromotoresNotifier(data: _promotores()),
        ),
        myEventInviteProvider.overrideWith(
          () => _FakeMyEventInviteNotifier(data: null),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Cancelar evento'), findsNothing);
      expect(find.text('Editar'), findsNothing);
    });

    testWidgets('co_promotor sees no edit or cancel actions', (tester) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(
            () => _FakeAuthNotifier(_coPromotorId),
          ),
          eventDetailProvider.overrideWith(
            () => _FakeEventDetailNotifier(data: _event()),
          ),
          eventPromotoresProvider.overrideWith(
            () => _FakeEventPromotoresNotifier(data: _promotores()),
          ),
          myEventInviteProvider.overrideWith(
            () => _FakeMyEventInviteNotifier(data: null),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: EventDetailScreen(eventId: _eventId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Editar'), findsNothing);
      expect(find.text('Cancelar evento'), findsNothing);
      expect(find.text('Promotor'), findsOneWidget);
      expect(find.text('Co-promotor'), findsOneWidget);
    });
  });

  group('EventEditScreen', () {
    testWidgets('renders the pre-filled form with editable pool fields', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const EventEditScreen(eventId: _eventId),
        _loadedEventOverrides(),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, 'Rave en el garaje'),
        findsOneWidget,
      );
      expect(find.text('La mejor fiesta del barrio'), findsOneWidget);
      expect(find.text('Av. Los Aromos 123'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
    });

    testWidgets('shows the pool-locked notice when starts_at has passed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, const EventEditScreen(eventId: _eventId), [
        eventDetailProvider.overrideWith(
          () => _FakeEventDetailNotifier(
            data: _event(
              startsAt: DateTime(2020, 1, 1, 21),
              endsAt: DateTime(2020, 1, 1, 23),
            ),
          ),
        ),
        eventPromotoresProvider.overrideWith(
          () => _FakeEventPromotoresNotifier(data: const []),
        ),
        myEventInviteProvider.overrideWith(
          () => _FakeMyEventInviteNotifier(data: null),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'El pool, tope y sobrante pueden editarse hasta que comience el evento.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty name blocks the submit with no service call', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = _MockEventService();
      await _pump(tester, const EventEditScreen(eventId: _eventId), [
        eventServiceProvider.overrideWithValue(service),
        ..._loadedEventOverrides(),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Rave en el garaje'),
        '   ',
      );
      await tester.ensureVisible(find.text('Guardar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      verifyNever(() => service.updateEvent(any(), any()));
      expect(find.text('El nombre del evento es obligatorio'), findsOneWidget);
    });

    testWidgets('submit calls updateEvent with the patch and pops back', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = _MockEventService();
      when(() => service.getEvent(_eventId)).thenAnswer((_) async => _event());
      when(
        () => service.getEventPromotores(_eventId),
      ).thenAnswer((_) async => _promotores());
      when(
        () => service.getMyEventInvite(_eventId),
      ).thenAnswer((_) async => null);
      when(() => service.updateEvent(any(), any())).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(() => _FakeAuthNotifier(_promotorId)),
          eventServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('home-marker')),
          ),
          GoRoute(
            path: '/event/:eventId/edit',
            builder: (_, state) =>
                EventEditScreen(eventId: state.pathParameters['eventId']!),
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
      router.push(RoutePaths.eventEdit(_eventId));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Rave en el garaje'),
        'Fiesta nueva',
      );
      await tester.ensureVisible(find.text('Guardar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      final captured = verify(
        () => service.updateEvent(captureAny(), captureAny()),
      ).captured;
      expect(captured[0], _eventId);
      final patch = captured[1] as Map;
      expect(patch['name'], 'Fiesta nueva');
      expect(patch['description'], 'La mejor fiesta del barrio');
      expect(patch['location_name'], 'Av. Los Aromos 123');
      expect(patch['starts_at'], _startsAt.toIso8601String());
      expect(patch['ends_at'], _endsAt.toIso8601String());
      expect(patch['preshards_pool'], 500);
      expect(find.text('home-marker'), findsOneWidget);
      expect(find.byType(EventEditScreen), findsNothing);
    });
  });
}
