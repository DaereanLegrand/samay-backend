import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/events/logic/event_formatters.dart';
import 'package:samay/features/events/screens/my_events_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

/// MyEventsScreen tests (R1 events sweep): the events tab renders the
/// session's event list through [eventServiceProvider] with loading / error /
/// empty / list states, pull-to-refresh, a create CTA that routes to the
/// groups tab, and tap-to-event-detail.
class _FakeEventService implements EventService {
  _FakeEventService(this.rows, {this.error, this.gate});

  final List<Map<String, dynamic>> rows;
  Object? error;

  /// When set, [listEvents] awaits it before resolving — tests hold the
  /// provider in the loading state deterministically.
  final Future<void>? gate;
  int listCalls = 0;
  String? lastStatus;
  String? lastType;

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createEvent(Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getEvent(String id) =>
      throw UnimplementedError();

  @override
  Future<Event?> getEventByInviteToken(String token) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyQrToken(String eventId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getEventPromotores(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyEventInvite(String eventId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listEvents([
    String? status,
    String? type,
  ]) async {
    listCalls++;
    lastStatus = status;
    lastType = type;
    final g = gate;
    if (g != null) await g;
    if (error != null) throw error!;
    return List.of(rows);
  }

  @override
  Future<void> likePhoto(String photoId) => throw UnimplementedError();

  @override
  Future<void> unlikePhoto(String photoId) => throw UnimplementedError();

  @override
  Future<List<String>> getMyPhotoLikes(String eventId) =>
      throw UnimplementedError();

  @override
  Future<void> updateEvent(String id, Map<String, dynamic> patch) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> validateQrToken(String eventId, String token) =>
      throw UnimplementedError();
}

Map<String, dynamic> _eventRow(
  String id, {
  String name = 'Rave en el garaje',
  String type = 'juerga',
  String status = 'upcoming',
  String? groupId,
  String? locationName,
  String? coverUrl,
  DateTime? startsAt,
  DateTime? endsAt,
}) {
  final start = startsAt ?? DateTime(2026, 9, 15, 21);
  return {
    'id': id,
    'name': name,
    'type': type,
    'status': status,
    'group_id': groupId,
    'location_name': locationName,
    'cover_url': coverUrl,
    'starts_at': start.toUtc().toIso8601String(),
    'ends_at': (endsAt ?? start.add(const Duration(hours: 4)))
        .toUtc()
        .toIso8601String(),
  };
}

ProviderContainer _container(_FakeEventService service, {GoRouter? router}) {
  final container = ProviderContainer(
    overrides: [eventServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeEventService service, {
  GoRouter? router,
}) async {
  final container = _container(service, router: router);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router == null
          ? const MaterialApp(
              locale: Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MyEventsScreen(),
            )
          : MaterialApp.router(
              routerConfig: router,
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MyEventsScreen', () {
    testWidgets('shows the list skeleton while the provider is pending '
        '(U-22 §5.8)', (tester) async {
      final gate = Completer<void>();
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Fiesta Salvaje'),
      ], gate: gate.future);
      final container = _container(service);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MyEventsScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(VSkeletonList), findsOneWidget);
      expect(find.byType(VLoadingView), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(VSkeletonList), findsNothing);
      expect(find.text('Fiesta Salvaje'), findsOneWidget);
    });

    testWidgets('renders the hero, create CTA and event cards', (tester) async {
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Rave en el garaje', status: 'live'),
        _eventRow(
          'e-2',
          name: 'Tono en Barranco',
          type: 'tono',
          locationName: 'Barranco, Lima',
        ),
      ]);
      await _pumpScreen(tester, service);

      // The hero goes through VDisplayText — the MAYUS rule uppercases it.
      expect(find.text('MIS EVENTOS'), findsOneWidget);
      expect(find.text('Crear evento'), findsOneWidget);
      // The helper explains the groups-tab detour.
      expect(
        find.text(
          'El evento se crea dentro de un grupo — elige uno en la pestaña Grupos.',
        ),
        findsOneWidget,
      );
      expect(find.text('Rave en el garaje'), findsOneWidget);
      expect(find.text('Tono en Barranco'), findsOneWidget);
      expect(find.text('Barranco, Lima'), findsOneWidget);
      // §3.3/§5.5: VBadge labels render uppercase — type + status markers.
      expect(find.text('JUERGA'), findsOneWidget);
      expect(find.text('EN VIVO'), findsOneWidget);
      expect(find.text('TONO'), findsOneWidget);
      // The 'upcoming' STATUS badge (eventStatusUpcoming — the word
      // 'Próximamente' is legitimate here as a status label, not a
      // coming-soon screen).
      expect(find.text('PRÓXIMAMENTE'), findsOneWidget);
    });

    testWidgets('renders the date range through the shared event formatter', (
      tester,
    ) async {
      final start = DateTime(2026, 9, 15, 21);
      final end = DateTime(2026, 9, 16, 2);
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Rave', startsAt: start, endsAt: end),
      ]);
      await _pumpScreen(tester, service);

      expect(find.text(formatEventDateRange(start, end, 'es')), findsOneWidget);
    });

    testWidgets('renders the empty state with real copy', (tester) async {
      final service = _FakeEventService([]);
      await _pumpScreen(tester, service);

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Aún no tienes eventos'), findsOneWidget);
      expect(
        find.text('Cuando te inviten o crees uno, aparecerá aquí.'),
        findsOneWidget,
      );
      // The create CTA is present even on the empty state.
      expect(find.text('Crear evento'), findsOneWidget);
    });

    testWidgets('shows ErrorView and retry reloads the list', (tester) async {
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Fiesta Salvaje'),
      ], error: Exception('boom'));
      await _pumpScreen(tester, service);

      expect(find.byType(ErrorView), findsOneWidget);
      // A generic Exception maps to ServerError('') — the localized fallback.
      expect(
        find.text('Error del servidor. Intenta de nuevo.'),
        findsOneWidget,
      );

      service.error = null;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('Fiesta Salvaje'), findsOneWidget);
    });

    testWidgets('pull-to-refresh reloads the list', (tester) async {
      final service = _FakeEventService([_eventRow('e-1')]);
      await _pumpScreen(tester, service);
      expect(service.listCalls, 1);
      expect(service.lastStatus, isNull);
      expect(service.lastType, isNull);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(service.listCalls, greaterThanOrEqualTo(2));
    });

    testWidgets('tapping an event card navigates to event detail', (
      tester,
    ) async {
      final service = _FakeEventService([_eventRow('e-1', name: 'Rave')]);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const MyEventsScreen()),
          GoRoute(
            path: RoutePaths.eventDetail(':eventId'),
            builder: (_, state) =>
                Text('DETAIL ${state.pathParameters['eventId']}'),
          ),
        ],
      );
      await _pumpScreen(tester, service, router: router);

      await tester.tap(find.text('Rave'));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL e-1'), findsOneWidget);
    });

    testWidgets('the create CTA navigates to the groups tab', (tester) async {
      final service = _FakeEventService([_eventRow('e-1')]);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const MyEventsScreen()),
          GoRoute(
            path: RoutePaths.mainGroups,
            builder: (_, _) => const Scaffold(body: Text('GROUPS TAB')),
          ),
        ],
      );
      await _pumpScreen(tester, service, router: router);

      await tester.tap(find.text('Crear evento'));
      await tester.pumpAndSettle();

      expect(find.text('GROUPS TAB'), findsOneWidget);
    });
  });
}
