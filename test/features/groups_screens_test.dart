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
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/services/group_service.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/providers/recent_friends_provider.dart';
import 'package:samay/features/groups/screens/create_group_screen.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/donate_shards_screen.dart';
import 'package:samay/features/groups/screens/invite_screen.dart';
import 'package:samay/features/groups/screens/leaderboard_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_chip.dart';

import '../support/fake_supabase_http.dart' as support;

const _groupId = '33333333-3333-3333-3333-333333333333';
const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

Group _group(String id, String name, {String? myRole}) => Group(
  id: id,
  name: name,
  groupShards: 100,
  rankBracket: 'b0_20',
  myRole: myRole,
);

class _FakeGroupDetailNotifier extends GroupDetailNotifier {
  final Group? data;
  _FakeGroupDetailNotifier({this.data});

  @override
  Future<Group?> build(String arg) async => data;
}

class _FakeGroupMembersNotifier extends GroupMembersNotifier {
  final List<GroupMember> data;
  _FakeGroupMembersNotifier({this.data = const []});

  @override
  Future<List<GroupMember>> build(String arg) async => data;
}

class _FakeContributionsNotifier extends GroupContributionsNotifier {
  final GroupContributionsData data;
  _FakeContributionsNotifier({
    this.data = const GroupContributionsData(
      contributors: [],
      myContribution: 0,
    ),
  });

  @override
  Future<GroupContributionsData> build(String arg) async => data;
}

class _FakeGroupDetailCombinedNotifier extends GroupDetailCombinedNotifier {
  final GroupDetailData _data;
  _FakeGroupDetailCombinedNotifier(this._data);

  @override
  Future<GroupDetailData> build(String arg) async => _data;
}

class _FakeLeaderboardNotifier extends LeaderboardNotifier {
  final List<LeaderboardEntry> data;
  _FakeLeaderboardNotifier({this.data = const []});

  @override
  Future<List<LeaderboardEntry>> build(String arg) async => data;
}

class _FakeSearchResultsNotifier extends SearchResultsNotifier {
  final List<UserSearchResult> data;
  _FakeSearchResultsNotifier({this.data = const []});

  @override
  Future<List<UserSearchResult>> build(String arg) async => data;
}

/// Stubbed on-device friends cache — replaces the derived
/// [recentFriendsProvider] so InviteScreen tests control the friends list
/// directly (the recency derivation is covered in
/// `recent_friends_provider_test.dart`).
class _FakeRecentFriendsNotifier extends RecentFriendsNotifier {
  final List<UserSearchResult> data;
  _FakeRecentFriendsNotifier({this.data = const []});

  @override
  Future<List<UserSearchResult>> build() async => data;
}

/// Records every query the provider is asked to resolve, so tests can assert
/// that keystrokes were debounced into a single search (finding PERF-05).
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<UserSearchResult>> build(String arg) async {
    queries.add(arg);
    return const [];
  }
}

class _MockMediaService extends Mock implements MediaService {}

class _MockGroupService extends Mock implements GroupService {}

class _MockEventService extends Mock implements EventService {}

class _MockGroupsRepository extends Mock implements GroupsRepository {}

/// Records every tier argument the leaderboard family is asked to build, so
/// tests can assert that tapping a chip re-watches that tier (U-28). The
/// family override instantiates a notifier per member — the shared [tiers]
/// list is injected so every member records into the same log.
class _RecordingLeaderboardNotifier extends LeaderboardNotifier {
  _RecordingLeaderboardNotifier(this.tiers);

  final List<String> tiers;

  @override
  Future<List<LeaderboardEntry>> build(String arg) async {
    tiers.add(arg);
    return const [];
  }
}

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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
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

/// Pumps a screen inside a GoRouter so `context.pop()` (used by
/// CreateGroupScreen after a successful create) has a route to pop back to.
Future<ProviderContainer> _pumpWithRouter(
  WidgetTester tester,
  Widget child,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/create',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(),
        routes: [GoRoute(path: 'create', builder: (_, _) => child)],
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
  return container;
}

class _GroupDetailHarness {
  _GroupDetailHarness(this.container, this.router);

  final ProviderContainer container;
  final GoRouter router;
}

/// Pumps GroupDetailScreen as a pushed route over a `/home` parent, so
/// navigation (donate push, leave-group pop) can be asserted against the real
/// router stack (TST-07/M-14).
Future<_GroupDetailHarness> _pumpGroupDetail(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('home-marker')),
      ),
      GoRoute(
        path: '/group/:groupId',
        builder: (_, state) =>
            GroupDetailScreen(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        path: '/group/:groupId/donate',
        builder: (_, state) =>
            Scaffold(body: Text('donate-${state.pathParameters['groupId']}')),
      ),
      GoRoute(
        path: '/event/:eventId',
        builder: (_, state) =>
            Scaffold(body: Text('event-${state.pathParameters['eventId']}')),
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
  // push (not go): the leave-group flow pops back to the `/home` parent.
  router.push(RoutePaths.groupDetail(_groupId));
  await tester.pumpAndSettle();
  return _GroupDetailHarness(container, router);
}

/// The full set of provider overrides that renders a loaded GroupDetailScreen.
List<Override> _loadedGroupDetailOverrides() {
  const g = Group(id: _groupId, name: 'Disco Crew', groupShards: 100);
  final members = [
    GroupMember(
      id: 'gm-1',
      groupId: _groupId,
      userId: _userId1,
      role: 'promotor',
      joinedAt: DateTime(2026),
      users: const {'username': 'ana'},
    ),
  ];
  const contributions =
      GroupContributionsData(contributors: [], myContribution: 0);
  return [
    groupDetailProvider.overrideWith(
      () => _FakeGroupDetailNotifier(data: g),
    ),
    groupMembersProvider.overrideWith(
      () => _FakeGroupMembersNotifier(data: members),
    ),
    contributionsProvider.overrideWith(
      () => _FakeContributionsNotifier(data: contributions),
    ),
    groupDetailCombinedProvider.overrideWith(
      () => _FakeGroupDetailCombinedNotifier(
        GroupDetailData(
          group: g,
          members: members,
          contributions: contributions,
          membership: null,
        ),
      ),
    ),
  ];
}

void main() {
  setUpAll(() async {
    registerFallbackValue(Uint8List(0));
    // Seeded session + deterministic HTTP layer: the leave-group flow reaches
    // `SupabaseService.instance.leaveGroup` (requires `auth.currentUser`) and
    // issues PostgREST requests — both served hermetically (I-45).
    await support.initSupabaseHarness(sessionEmail: 'a@b.com');
  });

  group('CreateGroupScreen', () {
    testWidgets('with a cover: uploads via MediaService.uploadGroupCover, then '
        'creates the group with the public URL (EF-03 swap)', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();
      const coverUrl = 'https://cdn.example/groups/group_covers/1.png';
      when(
        () => media.uploadGroupCover(any()),
      ).thenAnswer((_) async => coverUrl);
      when(() => group.getUserGroupCount()).thenAnswer((_) async => 1);
      when(
        () => group.createGroup(any()),
      ).thenAnswer((_) async => {'id': _groupId, 'name': 'Disco Crew'});

      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cover_test_'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final coverFile = File('${dir.path}/cover.png');
      final coverBytes = (await tester.runAsync(() async {
        final bytes = await _solidPng(8, 8);
        await coverFile.writeAsBytes(bytes);
        return bytes;
      }))!;
      // In-memory XFile (readAsBytes completes under the widget test's fake
      // async zone) whose `path` points at the real PNG, so the cover
      // preview's Image.file decodes without error.
      Future<XFile?> pickCover(ImageSource source) async =>
          XFile.fromData(coverBytes, path: coverFile.path);
      final permissions = PermissionService(
        request: (_) async => ph.PermissionStatus.granted,
      );

      await _pumpWithRouter(
        tester,
        CreateGroupScreen(permissions: permissions, galleryPicker: pickCover),
        [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ],
      );

      await tester.tap(find.byIcon(Icons.camera_alt));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Disco Crew');
      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      verify(() => media.uploadGroupCover(any())).called(1);
      final captured = verify(() => group.createGroup(captureAny())).captured;
      final created = captured.single as Map;
      expect(
        created['cover_url'],
        coverUrl,
        reason: 'the group row must carry the public cover URL',
      );
      expect(created['name'], 'Disco Crew');
    });

    testWidgets('without a cover: creates the group with a null cover_url and '
        'never touches the upload path', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();
      when(() => group.getUserGroupCount()).thenAnswer((_) async => 1);
      when(
        () => group.createGroup(any()),
      ).thenAnswer((_) async => {'id': _groupId, 'name': 'Disco Crew'});

      await _pumpWithRouter(tester, const CreateGroupScreen(), [
        mediaServiceProvider.overrideWithValue(media),
        groupServiceProvider.overrideWithValue(group),
      ]);

      await tester.enterText(find.byType(TextField).first, 'Disco Crew');
      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      verifyNever(() => media.uploadGroupCover(any()));
      final captured = verify(() => group.createGroup(captureAny())).captured;
      expect((captured.single as Map)['cover_url'], isNull);
    });

    testWidgets(
      'shows the group-limit dialog instead of creating at 5 groups',
      (tester) async {
        final media = _MockMediaService();
        final group = _MockGroupService();
        when(() => group.getUserGroupCount()).thenAnswer((_) async => 5);

        await _pumpWithRouter(tester, const CreateGroupScreen(), [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ]);

        await tester.enterText(find.byType(TextField).first, 'Disco Crew');
        await tester.tap(find.text('Crear'));
        await tester.pumpAndSettle();

        expect(find.text('Límite alcanzado'), findsOneWidget);
        expect(find.textContaining('límite de 5 grupos'), findsOneWidget);
        verifyNever(() => media.uploadGroupCover(any()));
        verifyNever(() => group.createGroup(any()));
      },
    );

    testWidgets(
      'empty name: no service call and no limit dialog (TST-07/M-14)',
      (tester) async {
        final media = _MockMediaService();
        final group = _MockGroupService();

        await _pumpWithRouter(tester, const CreateGroupScreen(), [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ]);

        await tester.tap(find.text('Crear'));
        await tester.pumpAndSettle();

        verifyNever(() => group.getUserGroupCount());
        verifyNever(() => group.createGroup(any()));
        verifyNever(() => media.uploadGroupCover(any()));
        expect(find.text('Límite alcanzado'), findsNothing);
        expect(find.byType(CreateGroupScreen), findsOneWidget);
      },
    );

    testWidgets('whitespace-only name: no service call and no limit dialog '
        '(I-73 requiredValidator trim-empty)', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();

      await _pumpWithRouter(tester, const CreateGroupScreen(), [
        mediaServiceProvider.overrideWithValue(media),
        groupServiceProvider.overrideWithValue(group),
      ]);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      verifyNever(() => group.getUserGroupCount());
      verifyNever(() => group.createGroup(any()));
      verifyNever(() => media.uploadGroupCover(any()));
      expect(find.text('Límite alcanzado'), findsNothing);
      expect(find.byType(CreateGroupScreen), findsOneWidget);
    });
  });

  group('GroupDetailScreen', () {
    testWidgets('donate button navigates to the donate route (TST-07/M-14)', (
      tester,
    ) async {
      final harness = await _pumpGroupDetail(
        tester,
        _loadedGroupDetailOverrides(),
      );

      await tester.tap(find.text('donar'));
      await tester.pumpAndSettle();

      expect(find.text('donate-$_groupId'), findsOneWidget);
      expect(
        harness.router.state.matchedLocation,
        RoutePaths.donateToGroup(_groupId),
      );
    });

    testWidgets(
      'leave-group flow: inline row → confirm dialog → leaveGroup service '
      'call → pops back (R16 repoint; TST-07/M-14)',
      (tester) async {
        await _pumpGroupDetail(tester, _loadedGroupDetailOverrides());

        // R16: the leave trigger is the inline danger row — the overflow menu
        // is gone for non-frozen groups.
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        await tester.tap(find.text('Abandonar grupo'));
        await tester.pumpAndSettle();

        expect(find.text('¿Estás seguro?'), findsOneWidget);

        // Cancelling keeps the screen.
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.byType(GroupDetailScreen), findsOneWidget);

        // Confirming deletes the membership and pops to the parent route.
        await tester.tap(find.text('Abandonar grupo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Abandonar'));
        await tester.pumpAndSettle();

        expect(
          support.harnessHttp.sent('DELETE', 'group_id=eq.$_groupId'),
          isTrue,
          reason: 'leaveGroup must delete the membership row',
        );
        expect(find.text('home-marker'), findsOneWidget);
        expect(find.byType(GroupDetailScreen), findsNothing);
      },
    );

    testWidgets(
      'events tab lists only this group\'s events (R2 — filters by group_id)',
      (tester) async {
        final events = _MockEventService();
        when(() => events.listEvents()).thenAnswer(
          (_) async => [
            Event(
              id: 'e1',
              name: 'Rave del Sábado',
              type: 'juerga',
              status: 'upcoming',
              groupId: _groupId,
              startsAt: DateTime.utc(2026, 9, 1, 22),
              endsAt: DateTime.utc(2026, 9, 2, 4),
              locationName: 'La Bodega',
            ),
            Event(
              id: 'e2',
              name: 'Ajeno',
              type: 'juerga',
              status: 'upcoming',
              groupId: '99999999-9999-9999-9999-999999999999',
              startsAt: DateTime.utc(2026, 9, 1, 22),
              endsAt: DateTime.utc(2026, 9, 2, 4),
            ),
          ],
        );
        await _pump(tester, const GroupDetailScreen(groupId: _groupId), [
          ..._loadedGroupDetailOverrides(),
          eventServiceProvider.overrideWithValue(events),
        ]);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Eventos'));
        await tester.pumpAndSettle();

        expect(
          find.text('Rave del Sábado'),
          findsOneWidget,
          reason: 'R2 — the group events tab lists the group\'s events',
        );
        expect(
          find.text('Ajeno'),
          findsNothing,
          reason: 'events from other groups must be filtered out',
        );
        expect(find.textContaining('La Bodega'), findsOneWidget);
      },
    );

    testWidgets('tapping a group event pushes the event-detail route (R2)', (
      tester,
    ) async {
      final events = _MockEventService();
      when(() => events.listEvents()).thenAnswer(
        (_) async => [
          Event(
            id: 'e1',
            name: 'Rave del Sábado',
            type: 'juerga',
            status: 'upcoming',
            groupId: _groupId,
            startsAt: DateTime.utc(2026, 9, 1, 22),
            endsAt: DateTime.utc(2026, 9, 2, 4),
          ),
        ],
      );
      final harness = await _pumpGroupDetail(tester, [
        ..._loadedGroupDetailOverrides(),
        eventServiceProvider.overrideWithValue(events),
      ]);

      await tester.tap(find.text('Eventos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rave del Sábado'));
      await tester.pumpAndSettle();

      expect(
        find.text('event-e1'),
        findsOneWidget,
        reason: 'R2 — event rows push RoutePaths.eventDetail',
      );
      expect(
        harness.router.state.matchedLocation,
        RoutePaths.eventDetail('e1'),
      );
    });
  });

  group('DonateShardsScreen', () {
    testWidgets('amount below 1 shows the invalid-amount snackbar and never '
        'touches the repository (I-73 numericValidator)', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Donar'));
      // LUXE: bounded pumps instead of pumpAndSettle — pumpAndSettle would
      // otherwise advance the fake clock past the snackbar's 4s auto-dismiss
      // before the assertion runs.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Ingresa un monto válido'), findsOneWidget);
      expect(find.byType(DonateShardsScreen), findsOneWidget);
    });

    testWidgets('non-numeric amount shows the invalid-amount snackbar and '
        'never touches the repository (I-73 numericValidator)', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Donar'));
      // LUXE: bounded pumps (see the sibling test's note — pumpAndSettle
      // would dismiss the snackbar before the assertion).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Ingresa un monto válido'), findsOneWidget);
      expect(find.byType(DonateShardsScreen), findsOneWidget);
    });

    testWidgets('a valid amount calls donateToGroup with the parsed value, '
        'toasts the success snackbar and pops back (U-28 pin)', (tester) async {
      final groups = _MockGroupsRepository();
      when(() => groups.donateToGroup(_groupId, 120)).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(groups)],
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
            path: '/donate',
            builder: (_, _) => const DonateShardsScreen(
              groupId: _groupId,
              groupName: 'Test Group',
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
      router.push('/donate');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '120');
      await tester.tap(find.text('Donar'));
      await tester.pumpAndSettle();

      verify(() => groups.donateToGroup(_groupId, 120)).called(1);
      expect(
        find.text('Donación exitosa'),
        findsOneWidget,
        reason: 'F7: the donation success is a transient snackbar',
      );
      expect(
        find.text('home-marker'),
        findsOneWidget,
        reason: 'a successful donation pops back to the group',
      );
    });

    testWidgets('a failed donation toasts the mapped error and stays on the '
        'screen (U-28 pin)', (tester) async {
      final groups = _MockGroupsRepository();
      when(
        () => groups.donateToGroup(_groupId, 120),
      ).thenThrow(Exception('donation failed'));
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [groupsRepositoryProvider.overrideWithValue(groups)],
      );

      await tester.enterText(find.byType(TextField), '120');
      await tester.tap(find.text('Donar'));
      // LUXE: bounded pumps (see the sibling test's note — pumpAndSettle
      // would dismiss the snackbar before the assertion).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Error del servidor'), findsOneWidget);
      expect(
        find.byType(DonateShardsScreen),
        findsOneWidget,
        reason: 'a failed donation keeps the form for a retry',
      );
    });
  });

  group('InviteScreen', () {
    testWidgets('query <5: shows the cached friends (filtered), never the '
        'backend', (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(tester, const InviteScreen(groupId: _groupId), [
        groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
        searchResultsProvider.overrideWith(() => recording),
        recentFriendsProvider.overrideWith(
          () => _FakeRecentFriendsNotifier(
            data: const [
              UserSearchResult(id: _userId1, username: 'analia'),
              UserSearchResult(id: _userId2, username: 'lucas'),
            ],
          ),
        ),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('@analia'), findsOneWidget);
      expect(find.text('@lucas'), findsNothing,
          reason: 'a sub-5-char query must filter the cached friends');
      expect(recording.queries, isEmpty,
          reason: 'sub-5-char queries must never reach the backend');
    });

    // User directive (2026-08-29): EMPTY input must display the friend list.
    testWidgets('EMPTY input displays the full cached friend list, no backend '
        'call', (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(tester, const InviteScreen(groupId: _groupId), [
        groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
        searchResultsProvider.overrideWith(() => recording),
        recentFriendsProvider.overrideWith(
          () => _FakeRecentFriendsNotifier(
            data: const [
              UserSearchResult(id: _userId1, username: 'analia'),
              UserSearchResult(id: _userId2, username: 'lucas'),
            ],
          ),
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('@analia'), findsOneWidget,
          reason: 'the empty invite query shows the first cached friend');
      expect(find.text('@lucas'), findsOneWidget,
          reason: 'the empty invite query shows the second cached friend');
      expect(recording.queries, isEmpty,
          reason: 'an empty invite query must never reach the backend');
    });

    testWidgets('excludes existing members from the cached friends', (
      tester,
    ) async {
      await _pump(tester, const InviteScreen(groupId: _groupId), [
        groupMembersProvider.overrideWith(
          () => _FakeGroupMembersNotifier(
            data: [
              GroupMember(
                id: 'gm-1',
                groupId: _groupId,
                userId: _userId1,
                role: 'member',
                joinedAt: DateTime(2026),
              ),
            ],
          ),
        ),
        searchResultsProvider.overrideWith(_FakeSearchResultsNotifier.new),
        recentFriendsProvider.overrideWith(
          () => _FakeRecentFriendsNotifier(
            data: const [
              UserSearchResult(id: _userId1, username: 'ana'),
              UserSearchResult(id: _userId2, username: 'lucas'),
            ],
          ),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('@lucas'), findsOneWidget);
      expect(find.text('@ana'), findsNothing);
    });

    testWidgets('query >=5: backend + cached friends merged, friends first, '
        'no duplicates, existing members excluded', (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(tester, const InviteScreen(groupId: _groupId), [
        groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
        searchResultsProvider.overrideWith(() => recording),
        recentFriendsProvider.overrideWith(
          () => _FakeRecentFriendsNotifier(
            data: const [
              UserSearchResult(id: _userId1, username: 'analia'),
            ],
          ),
        ),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, ['analia']);
      expect(find.text('@analia'), findsOneWidget,
          reason: 'a friend returned by the backend must not be duplicated');
    });

    testWidgets('debounces rapid keystrokes into a single query after 300ms', (
      tester,
    ) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(tester, const InviteScreen(groupId: _groupId), [
        groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
        searchResultsProvider.overrideWith(() => recording),
        recentFriendsProvider.overrideWith(_FakeRecentFriendsNotifier.new),
      ]);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, [
        'analia',
      ], reason: 'intermediate keystrokes must not fire a query');
    });
  });

  group('LeaderboardScreen', () {
    testWidgets('tapping a size-tier chip re-watches that tier of the family '
        'provider (U-28 pin)', (tester) async {
      final tiers = <String>[];
      await _pump(tester, const LeaderboardScreen(), [
        leaderboardProvider.overrideWith(
          () => _RecordingLeaderboardNotifier(tiers),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(tiers, [
        'micro',
      ], reason: 'the screen starts watching the micro tier');

      final smallChip = tester.widget<VChip>(
        find.widgetWithText(VChip, 'small'),
      );
      expect(smallChip.selected, isFalse);

      await tester.tap(find.text('small'));
      await tester.pumpAndSettle();

      expect(tiers, [
        'micro',
        'small',
      ], reason: 'tapping a chip re-watches the family member for that tier');
      final selectedChip = tester.widget<VChip>(
        find.widgetWithText(VChip, 'small'),
      );
      expect(
        selectedChip.selected,
        isTrue,
        reason: 'the tapped chip renders selected',
      );
    });

    testWidgets('tapping a ranking row navigates to the group detail route '
        '(U-28 pin)', (tester) async {
      final router = GoRouter(
        initialLocation: '/leaderboard',
        routes: [
          GoRoute(
            path: '/leaderboard',
            builder: (_, _) => const LeaderboardScreen(),
          ),
          GoRoute(
            path: RoutePaths.groupDetail(
              '44444444-4444-4444-4444-444444444444',
            ),
            builder: (_, _) => const Scaffold(body: Text('GROUP DETAIL STUB')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            leaderboardProvider.overrideWith(
              () => _FakeLeaderboardNotifier(
                data: [
                  LeaderboardEntry(
                    group: _group(
                      '44444444-4444-4444-4444-444444444444',
                      'Disco Crew',
                    ),
                    rankPosition: 1,
                    score: 500,
                    memberCount: 12,
                  ),
                ],
              ),
            ),
          ],
          child: MaterialApp.router(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Disco Crew'));
      await tester.pumpAndSettle();

      expect(
        find.text('GROUP DETAIL STUB'),
        findsOneWidget,
        reason: 'leaderboard rows push the group detail route',
      );
    });
  });
}
