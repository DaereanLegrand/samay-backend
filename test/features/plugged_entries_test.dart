import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/models/event_photo.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/services/notification_service.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/features/photos/providers/photos_providers.dart';
import 'package:samay/features/photos/screens/photo_gallery_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_card.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

import '../support/fake_config_provider.dart';
import '../support/fake_supabase_http.dart' as support;
import '../support/stub_auth_notifier.dart';

/// Plugged-UI entry tests (2026-08-13): every screen that previously had no
/// button wiring now navigates to its real route —
/// home games section (feed), party finder, event QR/scanner/photos,
/// group games, and the friend-chat message button.
const _eventId = '44444444-4444-4444-4444-444444444444';
const _promotorId = '11111111-1111-1111-1111-111111111111';
const _peerUserId = '22222222-2222-2222-2222-222222222222';

class _MockFriendsRepository extends Mock implements FriendsRepository {}

class _MockChatService extends Mock implements ChatService {}

class _StubEventDetailNotifier extends EventDetailNotifier {
  final Event data;
  _StubEventDetailNotifier(this.data);

  @override
  Future<Event> build(String arg) async => data;
}

class _StubEventPromotoresNotifier extends EventPromotoresNotifier {
  final List<Map<String, dynamic>> data;
  _StubEventPromotoresNotifier(this.data);

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _StubMyEventInviteNotifier extends MyEventInviteNotifier {
  final Map<String, dynamic>? data;
  _StubMyEventInviteNotifier(this.data);

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
}

class _StubUploadPhotoNotifier extends PhotoUploadNotifier {
  @override
  Future<PhotoUploadState> build() async => const PhotoUploadState.idle();
}

class _StubEventPhotosNotifier extends EventPhotosNotifier {
  @override
  Future<List<EventPhoto>> build(String arg) async => const [];
}

Event _event({String status = 'upcoming'}) => Event(
  id: _eventId,
  name: 'Rave en el garaje',
  type: 'juerga',
  status: status,
  locationName: 'Av. Los Aromos 123',
  startsAt: DateTime(2026, 9, 15, 22),
  endsAt: DateTime(2026, 9, 16, 2),
);

List<Map<String, dynamic>> _promotores({bool asPromotor = false}) => [
  {
    'id': 'promo-1',
    'event_id': _eventId,
    'user_id': asPromotor ? _promotorId : '99999999-9999-9999-9999-999999999999',
    'role': 'promotor',
    'preshards_contributed': 300,
    'added_at': DateTime(2026, 5, 10).toIso8601String(),
    'users': {'username': 'ana'},
  },
];

class _FakeEventService extends Mock implements EventService {}

/// In-memory [NotificationService] fake for the feed badge wiring test —
/// rows are shaped like real `notifications` rows so the derived providers
/// parse them.
class _FakeNotificationService implements NotificationService {
  _FakeNotificationService(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> getNotifications() async =>
      List.of(rows);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _notificationRow(Map<String, dynamic>? data) => {
  'id': 'n-${DateTime.now().microsecondsSinceEpoch}',
  'type': 'minigame_invite',
  'title': 'Invitación a minijuego',
  'body': 'Te invitaron a un minijuego',
  'data': data,
  'read': false,
  'created_at': '2026-08-30T10:00:00Z',
};

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('plugged home — games section (feed)', () {
    testWidgets('tapping a game opens its dedicated page (no group needed)',
        (tester) async {
      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
          GoRoute(
            path: RoutePaths.minigame(':gameType'),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('GAME STUB'))),
          ),
        ],
      );
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [eventServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cadena de Pokes'));
      await tester.pumpAndSettle();

      expect(
        find.text('GAME STUB'),
        findsOneWidget,
        reason:
            'the feed game card opens the dedicated per-game page directly '
            '(2026-08-28) — the group-picker bottom sheet is gone',
      );
    });

    testWidgets('a pending invite shows the VCountBadge on that game\'s '
        'feed tile (170_minigame_invite_badges)', (tester) async {
      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
        ],
      );
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final notifications = _FakeNotificationService([
        _notificationRow({'gameType': 'truth_dare'}),
        _notificationRow({'gameType': 'truth_dare'}),
      ]);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          notificationServiceProvider.overrideWithValue(notifications),
          appConfigProvider.overrideWith(
            () => FakeAppConfigNotifier(const {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Two unread truth_dare invites → the Verdad o Reto tile carries a '2'
      // badge; a game with no invites renders none.
      await tester.scrollUntilVisible(
        find.text('Verdad o Reto'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final badge = tester.widget<VCountBadge>(
        find.descendant(
          of: find.ancestor(
            of: find.text('Verdad o Reto'),
            matching: find.byType(InkWell),
          ),
          matching: find.byType(VCountBadge),
        ),
      );
      expect(badge.count, 2,
          reason:
              'the per-game feed badge shows the invited-match count for that '
              'game type');
      // The OTHER game tiles (Cadena de Pokes, Preguntas, ...) carry no badge
      // — only tiles whose gameType has pending invites do. (The header's
      // chat-inbox button has its own unread badge, so assert on the games
      // row specifically.)
      final gamesBadges = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(VCountBadge),
      );
      expect(gamesBadges, findsOneWidget,
          reason: 'games without pending invites render no badge');
    });

    testWidgets('every game tile is a square of the SAME size — width equals '
        'height and matches the other tiles at any font setting (2026-08-30)',
        (tester) async {
      // Larger font setting reproduces the reported bug: a fixed 120px tile
      // width drifted from the text-scaled row height, so cards became
      // rectangles and some rendered wider than others.
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
        ],
      );
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          notificationServiceProvider.overrideWithValue(
            _FakeNotificationService(const []),
          ),
          appConfigProvider.overrideWith(
            () => FakeAppConfigNotifier(const {}),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Every BUILT game tile (the horizontal list lazily builds the visible
      // ones) must be a perfect square with identical dimensions. Scoped to
      // the games row ListView — the Party Finder card below is a full-width
      // row, not a tile.
      final gamesRow = find.byType(ListView);
      final tileInk = find.descendant(
        of: gamesRow,
        matching: find.byType(InkWell),
      );
      final sizes = <Size>[];
      for (var i = 0; i < tileInk.evaluate().length; i++) {
        sizes.add(tester.getSize(tileInk.at(i)));
      }
      expect(sizes, isNotEmpty, reason: 'the games row must build tiles');
      for (final size in sizes) {
        expect(size.width, size.height,
            reason: 'every game tile must be a square (width == height)');
        expect(size.width, sizes.first.width,
            reason: 'all game tiles must share the SAME width');
        expect(size.height, sizes.first.height,
            reason: 'all game tiles must share the SAME height');
      }

      // The reported symptom: the VCard BACKGROUND was narrower than the tile
      // for short names (the InkWell splash still covered the full square).
      // Each tile's VCard must fill its whole tile — same width AND height.
      for (var i = 0; i < tileInk.evaluate().length; i++) {
        final cardSize = tester.getSize(
          find.descendant(of: tileInk.at(i), matching: find.byType(VCard)),
        );
        expect(cardSize.width, sizes[i].width,
            reason:
                'tile $i: the VCard background must span the full tile width '
                '(not shrink-wrap to the name length)');
        expect(cardSize.height, sizes[i].height,
            reason:
                'tile $i: the VCard background must span the full tile height');
      }
    });
  });

  group('plugged event detail — QR / scanner / photos', () {
    Future<ProviderContainer> pumpEventDetail(
      WidgetTester tester, {
      List<Map<String, dynamic>>? promotores,
      String status = 'upcoming',
    }) async {
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(() => StubAuthNotifier(
                authenticated: true,
                hasProfile: true,
                userId: _promotorId,
              )),
          eventDetailProvider.overrideWith(
            () => _StubEventDetailNotifier(_event(status: status)),
          ),
          eventPromotoresProvider.overrideWith(
            () => _StubEventPromotoresNotifier(
              promotores ?? _promotores(asPromotor: true),
            ),
          ),
          myEventInviteProvider.overrideWith(
            () => _StubMyEventInviteNotifier(null),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: EventDetailScreen(eventId: _eventId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('closed events hide the live actions', (tester) async {
      await pumpEventDetail(tester, status: 'ended');
      await tester.drag(find.byType(ListView), const Offset(0, -1600));
      await tester.pumpAndSettle();

      expect(find.text('código'), findsNothing);
      expect(find.text('escáner'), findsNothing);
      expect(find.text('fotos'), findsNothing);
    });
  });

  group('plugged photo gallery — collage', () {
    testWidgets('the collage button opens the auto-wall', (tester) async {
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('home-marker')),
          ),
          GoRoute(
            path: RoutePaths.eventPhotos(_eventId),
            builder: (_, _) => const PhotoGalleryScreen(eventId: _eventId),
          ),
          GoRoute(
            path: RoutePaths.eventCollage(_eventId),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('COLLAGE STUB'))),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          eventPhotosProvider.overrideWith(_StubEventPhotosNotifier.new),
          eventDetailProvider.overrideWith(
            () => _StubEventDetailNotifier(_event()),
          ),
          uploadPhotoProvider.overrideWith(
            () => _StubUploadPhotoNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      router.push(RoutePaths.eventPhotos(_eventId));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('photos-wall-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('COLLAGE STUB'),
        findsOneWidget,
        reason: 'the gallery header opens the auto-collage wall',
      );
    });
  });

  group('plugged public profile — message', () {
    testWidgets('friends see the Message button and it opens the chat', (
      tester,
    ) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.getUserProfile(_peerUserId),
      ).thenAnswer(
        (_) async => const UserProfile(id: _peerUserId, username: 'pepe'),
      );
      when(
        () => friends.getFriendshipDetail(_peerUserId),
      ).thenAnswer(
        (_) async => {
          'id': 'friendship-1',
          'requester_id': _promotorId,
          'user_id': _peerUserId,
          'status': 'accepted',
        },
      );
      when(
        () => friends.getBlockStatus(_peerUserId),
      ).thenAnswer((_) async => false);

      final chat = _MockChatService();
      when(
        () => chat.createDirectChat(_peerUserId),
      ).thenAnswer((_) async => 'chat-1');

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('home-marker')),
          ),
          GoRoute(
            path: RoutePaths.userProfile(_peerUserId),
            builder: (_, _) => const PublicProfileScreen(userId: _peerUserId),
          ),
          GoRoute(
            path: RoutePaths.chat('chat-1'),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('CHAT STUB'))),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          friendsRepositoryProvider.overrideWithValue(friends),
          chatServiceProvider.overrideWithValue(chat),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations
                .localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      router.push(RoutePaths.userProfile(_peerUserId));
      await tester.pumpAndSettle();

      expect(
        find.text('Mensaje'),
        findsOneWidget,
        reason: 'accepted friends get the E2EE chat entry',
      );

      await tester.tap(find.text('Mensaje'));
      await tester.pumpAndSettle();

      verify(() => chat.createDirectChat(_peerUserId)).called(1);
      expect(
        find.text('CHAT STUB'),
        findsOneWidget,
        reason: 'the message button opens the direct chat thread',
      );
    });
  });
}
