import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/models/event_photo.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/providers/auth_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/chat_service.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/features/events/providers/events_providers.dart';
import 'package:samay/features/events/screens/event_detail_screen.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/photos/providers/photos_providers.dart';
import 'package:samay/features/photos/screens/photo_gallery_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../support/fake_supabase_http.dart' as support;
import '../support/stub_auth_notifier.dart';

/// Plugged-UI entry tests (2026-08-13): every screen that previously had no
/// button wiring now navigates to its real route —
/// home games section (feed), party finder, event QR/scanner/photos,
/// group games, and the friend-chat message button.
const _groupId = '33333333-3333-3333-3333-333333333333';
const _eventId = '44444444-4444-4444-4444-444444444444';
const _promotorId = '11111111-1111-1111-1111-111111111111';
const _peerUserId = '22222222-2222-2222-2222-222222222222';

class _MockFriendsRepository extends Mock implements FriendsRepository {}

class _MockGroupsRepository extends Mock implements GroupsRepository {}

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

class _StubGroupDetailNotifier extends GroupDetailNotifier {
  final Group? data;
  _StubGroupDetailNotifier(this.data);

  @override
  Future<Group?> build(String arg) async => data;
}

class _StubGroupMembersNotifier extends GroupMembersNotifier {
  @override
  Future<List<GroupMember>> build(String arg) async => const [];
}

class _StubContributionsNotifier extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      const GroupContributionsData(contributors: [], myContribution: 0);
}

class _StubGroupDetailCombinedNotifier extends GroupDetailCombinedNotifier {
  final GroupDetailData _data;
  _StubGroupDetailCombinedNotifier(this._data);

  @override
  Future<GroupDetailData> build(String arg) async => _data;
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

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('plugged home — games section (feed)', () {
    testWidgets('renders the five games and the Party Finder entry on top', (
      tester,
    ) async {
      final service = _FakeEventService();
      when(
        () => service.listEvents(any(), any()),
      ).thenAnswer((_) async => [_event()]);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
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
            home: FeedScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('JUEGOS'),
        findsOneWidget,
        reason: 'the games section header sits at the top of the home feed',
      );
      expect(find.text('Cadena de Pokes'), findsOneWidget);
      expect(find.text('Preguntas'), findsOneWidget);
      expect(find.text('Party Finder'), findsOneWidget);
    });

    testWidgets('tapping a game with one group navigates to the minigames hub',
        (tester) async {
      final groups = _MockGroupsRepository();
      when(() => groups.getMyGroups()).thenAnswer(
        (_) async => [
          const Group(
            id: _groupId,
            name: 'Disco Crew',
            groupShards: 100,
            myRole: 'member',
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
          GoRoute(
            path: RoutePaths.minigames(_groupId),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('GAMES STUB'))),
          ),
        ],
      );
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          groupsRepositoryProvider.overrideWithValue(groups),
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

      await tester.tap(find.text('Cadena de Pokes'));
      await tester.pumpAndSettle();

      expect(
        find.text('GAMES STUB'),
        findsOneWidget,
        reason: 'single-group users jump straight into the games hub',
      );
    });

    testWidgets('tapping a game with no groups shows the join-a-group hint', (
      tester,
    ) async {
      final groups = _MockGroupsRepository();
      when(() => groups.getMyGroups()).thenAnswer((_) async => []);
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
          groupsRepositoryProvider.overrideWithValue(groups),
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
            home: FeedScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cadena de Pokes'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('Aún no tienes grupos'),
        findsOneWidget,
        reason: 'the snackbar hints at joining a group first',
      );
    });

    testWidgets('tapping the Party Finder card navigates to the finder', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: RoutePaths.mainFeed,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const FeedScreen(),
          ),
          GoRoute(
            path: RoutePaths.partyFinder,
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('FINDER STUB'))),
          ),
        ],
      );
      final service = _FakeEventService();
      when(() => service.listEvents(any(), any())).thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [
          eventServiceProvider.overrideWithValue(service),
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

      await tester.tap(find.text('Party Finder'));
      await tester.pumpAndSettle();

      expect(find.text('FINDER STUB'), findsOneWidget);
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

    testWidgets('renders attendee QR, scanner (promotor) and photos actions', (
      tester,
    ) async {
      await pumpEventDetail(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -1600));
      await tester.pumpAndSettle();

      expect(find.text('Código de asistencia'), findsOneWidget);
      expect(find.text('Escáner de asistencia'), findsOneWidget);
      expect(find.text('Fotos'), findsOneWidget);
    });

    testWidgets('attendees never see the promotor scanner', (tester) async {
      await pumpEventDetail(
        tester,
        promotores: _promotores(asPromotor: false),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -1600));
      await tester.pumpAndSettle();

      expect(find.text('Código de asistencia'), findsOneWidget);
      expect(find.text('Escáner de asistencia'), findsNothing);
      expect(find.text('Fotos'), findsOneWidget);
    });

    testWidgets('closed events hide the live actions', (tester) async {
      await pumpEventDetail(tester, status: 'ended');
      await tester.drag(find.byType(ListView), const Offset(0, -1600));
      await tester.pumpAndSettle();

      expect(find.text('Código de asistencia'), findsNothing);
      expect(find.text('Escáner de asistencia'), findsNothing);
      expect(find.text('Fotos'), findsNothing);
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

  group('plugged group detail — games', () {    testWidgets('the Juegos button opens the group minigames hub', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('home-marker')),
          ),
          GoRoute(
            path: RoutePaths.groupDetail(_groupId),
            builder: (_, _) => const GroupDetailScreen(groupId: _groupId),
          ),
          GoRoute(
            path: RoutePaths.minigames(_groupId),
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('GAMES STUB'))),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          groupDetailProvider.overrideWith(
            () => _StubGroupDetailNotifier(
              const Group(
                id: _groupId,
                name: 'Disco Crew',
                groupShards: 100,
              ),
            ),
          ),
          groupMembersProvider.overrideWith(_StubGroupMembersNotifier.new),
          contributionsProvider.overrideWith(
            _StubContributionsNotifier.new,
          ),
          groupDetailCombinedProvider.overrideWith(
            () => _StubGroupDetailCombinedNotifier(
              const GroupDetailData(
                group: Group(
                  id: _groupId,
                  name: 'Disco Crew',
                  groupShards: 100,
                ),
                members: [],
                contributions: GroupContributionsData(
                  contributors: [],
                  myContribution: 0,
                ),
                membership: null,
              ),
            ),
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
      router.push(RoutePaths.groupDetail(_groupId));
      await tester.pumpAndSettle();

      expect(find.text('Juegos'), findsOneWidget);

      await tester.tap(find.text('Juegos'));
      await tester.pumpAndSettle();

      expect(
        find.text('GAMES STUB'),
        findsOneWidget,
        reason: 'the group action row routes straight into the hub',
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
