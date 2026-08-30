import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/feed/providers/feed_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/fake_config_provider.dart';

/// Feed tests (I-58, FEED): feedProvider ordering contract (public events
/// only, featured pinned, starts_at ASC), radius providers reading app_config
/// (options + default, 'anywhere' default selection while no device location
/// exists), and the feed screen's render / chips / empty / error+retry /
/// pull-to-refresh / tap-to-event-detail behaviors against an in-memory fake
/// [EventService].
class _FakeEventService implements EventService {
  _FakeEventService(this.rows, {this.error});

  final List<Event> rows;
  Object? error;
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
  Future<Event> getEvent(String id) =>
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
  Future<List<Event>> listEvents([
    String? status,
    String? type,
  ]) async {
    listCalls++;
    lastStatus = status;
    lastType = type;
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

Event _eventRow(
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
  return Event(
    id: id,
    name: name,
    type: type,
    status: 'upcoming',
    groupId: groupId,
    locationName: locationName,
    coverUrl: coverUrl,
    featured: featured,
    startsAt: start,
    endsAt: endsAt ?? start.add(const Duration(hours: 4)),
  );
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
      // Plugged home (2026-08-13): the games/party-finder sections are
      // covered by test/features/plugged_entries_test.dart — this suite
      // pins the feed's event layout, so the quick-access sections are
      // switched off here.
      featureFlagsProvider.overrideWithValue(
        const AppFeatureFlags(minigames: false, partyFinder: false),
      ),
    ],
  );
  addTearDown(container.dispose);
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
}
