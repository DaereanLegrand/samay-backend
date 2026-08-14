import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/events/logic/event_formatters.dart';
import 'package:samay/features/feed/providers/feed_providers.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/fake_config_provider.dart';

/// Feed tests (I-58, FEED): feedProvider ordering contract (public events
/// only, featured pinned, starts_at ASC), radius providers reading app_config
/// (options + default, 'anywhere' default selection while no device location
/// exists), and the feed screen's render / chips / empty / error+retry /
/// pull-to-refresh / tap-to-event-detail behaviors against an in-memory fake
/// [EventService].
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
  Future<Map<String, dynamic>?> rotateQrToken(String eventId) async => null;

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
  String name = 'Fiesta',
  String type = 'juerga',
  DateTime? startsAt,
  DateTime? endsAt,
  String? groupId,
  String? locationName,
  String? coverUrl,
  bool featured = false,
}) {
  final start = startsAt ?? DateTime(2026, 9, 15, 22);
  return {
    'id': id,
    'name': name,
    'type': type,
    'status': 'upcoming',
    'group_id': groupId,
    'location_name': locationName,
    'cover_url': coverUrl,
    'featured': featured,
    'starts_at': start.toUtc().toIso8601String(),
    'ends_at': (endsAt ?? start.add(const Duration(hours: 4)))
        .toUtc()
        .toIso8601String(),
  };
}

ProviderContainer _container(
  _FakeEventService service, {
  Map<String, String>? config,
}) {
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(service),
      if (config != null)
        appConfigProvider.overrideWith(() => FakeAppConfigNotifier(config)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester,
  _FakeEventService service, {
  Map<String, String>? config,
  GoRouter? router,
}) async {
  final container = _container(service, config: config);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router == null
          ? const MaterialApp(
              locale: Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: FeedScreen(),
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
  return container;
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es', null);
  });

  group('feedProvider', () {
    test('maps upcoming public rows to typed Event models', () async {
      final service = _FakeEventService([
        _eventRow('e-1', coverUrl: 'https://img.test/c1.png', featured: true),
      ]);
      final container = _container(service);

      final events = await container.read(feedProvider.future);

      expect(service.lastStatus, 'upcoming');
      expect(service.listCalls, 1);
      expect(events, hasLength(1));
      expect(events.first, isA<Event>());
      expect(events.first.id, 'e-1');
      expect(events.first.featured, isTrue);
      expect(events.first.coverUrl, 'https://img.test/c1.png');
    });

    test('filters group-scoped events out of the public feed', () async {
      final service = _FakeEventService([
        _eventRow('e-public'),
        _eventRow('e-group', groupId: 'g-1'),
        _eventRow('e-draft', name: 'Borrador'),
      ]);
      final container = _container(service);

      final events = await container.read(feedProvider.future);

      expect(events.map((e) => e.id), ['e-public', 'e-draft']);
    });

    test(
      'pins featured events first, then sorts by starts_at ascending',
      () async {
        final service = _FakeEventService([
          _eventRow('a', startsAt: DateTime(2026, 9, 17, 21)),
          _eventRow('b', featured: true, startsAt: DateTime(2026, 9, 10, 21)),
          _eventRow('c', startsAt: DateTime(2026, 9, 15, 21)),
          _eventRow('d', featured: true, startsAt: DateTime(2026, 9, 12, 21)),
        ]);
        final container = _container(service);

        final events = await container.read(feedProvider.future);

        expect(events.map((e) => e.id), ['b', 'd', 'c', 'a']);
        expect(events[0].featured, isTrue);
        expect(events[1].featured, isTrue);
        expect(events[2].featured, isFalse);
      },
    );

    test('refresh reloads from the service', () async {
      final service = _FakeEventService([_eventRow('e-1')]);
      final container = _container(service);
      await container.read(feedProvider.future);

      service.rows.add(_eventRow('e-2'));
      await container.read(feedProvider.notifier).refresh();

      final events = await container.read(feedProvider.future);
      expect(events, hasLength(2));
      expect(service.listCalls, 2);
    });

    test('surfaces AsyncError when the service fails', () async {
      final service = _FakeEventService([
        _eventRow('e-1'),
      ], error: Exception('boom'));
      final container = _container(service);

      await expectLater(container.read(feedProvider.future), throwsException);
      expect(container.read(feedProvider), isA<AsyncError>());
    });
  });

  group('radius providers', () {
    test('parseFeedRadiusOptions parses the seeded option list', () {
      expect(parseFeedRadiusOptions('5,20,50,999'), [5, 20, 50, 999]);
      expect(parseFeedRadiusOptions('10, 25'), [10, 25]);
    });

    test('parseFeedRadiusOptions falls back to the seeded options', () {
      expect(parseFeedRadiusOptions(null), [5, 20, 50, 999]);
      expect(parseFeedRadiusOptions(''), [5, 20, 50, 999]);
      expect(parseFeedRadiusOptions('abc'), [5, 20, 50, 999]);
    });

    test('parseFeedRadiusDefault falls back to 50 km', () {
      expect(parseFeedRadiusDefault(null), 50);
      expect(parseFeedRadiusDefault('abc'), 50);
      expect(parseFeedRadiusDefault('20'), 20);
    });

    test('option and default providers read app_config', () async {
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWith(
            () => FakeAppConfigNotifier(const {
              'feed.nearby_radius_km_options': '10,30,999',
              'feed.nearby_radius_km_default': '30',
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appConfigProvider.future);

      expect(container.read(feedRadiusOptionsProvider), [10, 30, 999]);
      expect(container.read(feedRadiusDefaultProvider), 30);
    });

    test(
      'radiusFilterProvider defaults to anywhere (999) without a location',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(container.read(radiusFilterProvider), kFeedRadiusAnywhereKm);
      },
    );

    test('select updates the selected radius', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(radiusFilterProvider.notifier).select(20);
      expect(container.read(radiusFilterProvider), 20);

      container.read(radiusFilterProvider.notifier).select(999);
      expect(container.read(radiusFilterProvider), 999);
    });
  });

  group('FeedScreen', () {
    testWidgets('shows the cover+lines skeleton while the provider is '
        'pending (U-22 §5.8)', (tester) async {
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
            home: FeedScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(VSkeletonDetail),
        findsOneWidget,
        reason: 'first load shows the event-card skeleton, not a spinner',
      );
      expect(find.byType(VLoadingView), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(VSkeletonDetail), findsNothing);
      expect(find.text('Fiesta Salvaje'), findsOneWidget);
    });

    testWidgets('renders the brand header, featured section and event cards', (
      tester,
    ) async {
      final service = _FakeEventService([
        _eventRow(
          'e-feat',
          name: 'Tono Destacado',
          type: 'tono',
          featured: true,
          locationName: 'Barranco, Lima',
        ),
        _eventRow('e-plain', name: 'Juerga en casa', type: 'juerga'),
      ]);
      await _pumpScreen(tester, service);

      // LUXE v2 (XL-07): the brand hero renders through VDisplayText, which
      // enforces the MAYUS rule (ORCHESTRATION directive #6).
      expect(find.text('SAMAY'), findsOneWidget);
      expect(find.text('Destacados'), findsOneWidget);
      // §3.3/§5.5: VBadge labels render uppercase (U-05 restyle).
      expect(find.text('DESTACADO'), findsOneWidget);
      expect(find.text('Tono Destacado'), findsOneWidget);
      expect(find.text('Juerga en casa'), findsOneWidget);
      expect(find.text('Barranco, Lima'), findsOneWidget);
      expect(find.text('JUERGA'), findsOneWidget);
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

    testWidgets('radius chips render the app_config options and select', (
      tester,
    ) async {
      final service = _FakeEventService([_eventRow('e-1')]);
      await _pumpScreen(
        tester,
        service,
        config: const {
          'feed.nearby_radius_km_options': '5,20,50,999',
          'feed.nearby_radius_km_default': '50',
        },
      );

      expect(find.text('5 km'), findsOneWidget);
      expect(find.text('20 km'), findsOneWidget);
      expect(find.text('50 km'), findsOneWidget);
      expect(find.text('En cualquier lugar'), findsOneWidget);

      await tester.tap(find.text('20 km'));
      await tester.pumpAndSettle();
      final chip = tester.widget<FilterChip>(
        find.ancestor(
          of: find.text('20 km'),
          matching: find.byType(FilterChip),
        ),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('default selection is anywhere while no location exists', (
      tester,
    ) async {
      final service = _FakeEventService([_eventRow('e-1')]);
      await _pumpScreen(tester, service);

      final anywhereChip = tester.widget<FilterChip>(
        find.ancestor(
          of: find.text('En cualquier lugar'),
          matching: find.byType(FilterChip),
        ),
      );
      expect(anywhereChip.selected, isTrue);
    });

    testWidgets('shows the empty state when there are no events', (
      tester,
    ) async {
      await _pumpScreen(tester, _FakeEventService([]));

      expect(find.text('No hay eventos próximos'), findsOneWidget);
    });

    testWidgets('the EMPTY feed is still pull-to-refreshable (R13 pattern, '
        'feed sliver form)', (tester) async {
      final service = _FakeEventService([]);
      await _pumpScreen(tester, service);
      expect(service.listCalls, 1);
      expect(find.text('No hay eventos próximos'), findsOneWidget);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(
        service.listCalls,
        greaterThanOrEqualTo(2),
        reason:
            'the empty feed keeps the refresh affordance (U-16 R13: '
            'empties stay refreshable — feed variant)',
      );
      expect(find.text('No hay eventos próximos'), findsOneWidget);
    });

    testWidgets('shows ErrorView and retry reloads the feed', (tester) async {
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Fiesta Salvaje'),
      ], error: Exception('boom'));
      await _pumpScreen(tester, service);

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('No se pudo cargar el feed'), findsOneWidget);

      service.error = null;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsNothing);
      expect(find.text('Fiesta Salvaje'), findsOneWidget);
    });

    testWidgets('pull-to-refresh reloads the feed', (tester) async {
      final service = _FakeEventService([_eventRow('e-1')]);
      await _pumpScreen(tester, service);
      expect(service.listCalls, 1);

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
      final service = _FakeEventService([
        _eventRow('e-1', name: 'Rave en el garaje'),
      ]);
      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
          GoRoute(
            path: RoutePaths.eventDetail('e-1'),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('EVENT STUB'))),
          ),
        ],
      );
      await _pumpScreen(tester, service, router: router);

      await tester.tap(find.text('Rave en el garaje'));
      await tester.pumpAndSettle();

      expect(find.text('EVENT STUB'), findsOneWidget);
    });
  });
}
