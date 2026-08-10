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
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/group_service.dart';
import 'package:samay/core/services/media_service.dart';
import 'package:samay/core/services/permission_service.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/screens/create_group_screen.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/screens/group_members_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/donate_shards_screen.dart';
import 'package:samay/features/groups/screens/invite_screen.dart';
import 'package:samay/features/groups/screens/leaderboard_screen.dart';
import 'package:samay/features/groups/screens/my_groups_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';

import '../support/fake_supabase_http.dart' as support;

const _groupId = '33333333-3333-3333-3333-333333333333';
const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

Map<String, dynamic> _group(String id, String name, {String? myRole}) => {
      'id': id,
      'name': name,
      'group_shards': 100,
      'rank_bracket': 'b0_20',
      'my_role': myRole,
    };

class _FakeMyGroupsNotifier extends MyGroupsNotifier {
  final List<Map<String, dynamic>> data;
  final Object? error;
  _FakeMyGroupsNotifier({this.data = const [], this.error});

  @override
  Future<List<Map<String, dynamic>>> build() async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeGroupDetailNotifier extends GroupDetailNotifier {
  final Map<String, dynamic>? data;
  final Object? error;
  _FakeGroupDetailNotifier({this.data, this.error});

  @override
  Future<Map<String, dynamic>?> build(String arg) async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeGroupMembersNotifier extends GroupMembersNotifier {
  final List<Map<String, dynamic>> data;
  _FakeGroupMembersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _FakeContributionsNotifier extends GroupContributionsNotifier {
  final GroupContributionsData data;
  _FakeContributionsNotifier({this.data = const GroupContributionsData(contributors: [], myContribution: 0)});

  @override
  Future<GroupContributionsData> build(String arg) async => data;
}

class _FakeLeaderboardNotifier extends LeaderboardNotifier {
  final List<Map<String, dynamic>> data;
  final Object? error;
  _FakeLeaderboardNotifier({this.data = const [], this.error});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    if (error != null) throw error!;
    return data;
  }
}

class _FakeSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _FakeSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

/// Records every query the provider is asked to resolve, so tests can assert
/// that keystrokes were debounced into a single search (finding PERF-05).
class _RecordingSearchResultsNotifier extends SearchResultsNotifier {
  final List<String> queries = [];

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async {
    queries.add(arg);
    return const [];
  }
}

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
        routes: [
          GoRoute(path: 'create', builder: (_, _) => child),
        ],
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
        builder: (_, state) => Scaffold(
          body: Text('donate-${state.pathParameters['groupId']}'),
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
  // push (not go): the leave-group flow pops back to the `/home` parent.
  router.push(RoutePaths.groupDetail(_groupId));
  await tester.pumpAndSettle();
  return _GroupDetailHarness(container, router);
}

/// The full set of provider overrides that renders a loaded GroupDetailScreen.
List<Override> _loadedGroupDetailOverrides() => [
      groupDetailProvider.overrideWith(
        () => _FakeGroupDetailNotifier(
          data: {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
        ),
      ),
      groupMembersProvider.overrideWith(
        () => _FakeGroupMembersNotifier(
          data: [
            {
              'user_id': _userId1,
              'role': 'promotor',
              'users': {'username': 'ana'},
            },
          ],
        ),
      ),
      contributionsProvider.overrideWith(
        () => _FakeContributionsNotifier(
          data: const GroupContributionsData(contributors: [], myContribution: 0),
        ),
      ),
    ];

void main() {
  setUpAll(() async {
    registerFallbackValue(Uint8List(0));
    // Seeded session + deterministic HTTP layer: the leave-group flow reaches
    // `SupabaseService.instance.leaveGroup` (requires `auth.currentUser`) and
    // issues PostgREST requests — both served hermetically (I-45).
    await support.initSupabaseHarness(sessionEmail: 'a@b.com');
  });

  group('CreateGroupScreen', () {
    testWidgets('renders create group form', (tester) async {
      await _pump(tester, const CreateGroupScreen(), []);
      expect(find.text('Crear grupo'), findsOneWidget);
      expect(find.text('Nombre del grupo'), findsOneWidget);
      expect(find.text('Descripción (opcional)'), findsOneWidget);
      expect(find.text('Crear'), findsOneWidget);
    });

    testWidgets(
        'with a cover: uploads via MediaService.uploadGroupCover, then '
        'creates the group with the public URL (EF-03 swap)', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();
      const coverUrl = 'https://cdn.example/groups/group_covers/1.png';
      when(() => media.uploadGroupCover(any()))
          .thenAnswer((_) async => coverUrl);
      when(() => group.getUserGroupCount()).thenAnswer((_) async => 1);
      when(() => group.createGroup(any()))
          .thenAnswer((_) async => {'id': _groupId, 'name': 'Disco Crew'});

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
      expect(created['cover_url'], coverUrl,
          reason: 'the group row must carry the public cover URL');
      expect(created['name'], 'Disco Crew');
    });

    testWidgets('without a cover: creates the group with a null cover_url and '
        'never touches the upload path', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();
      when(() => group.getUserGroupCount()).thenAnswer((_) async => 1);
      when(() => group.createGroup(any()))
          .thenAnswer((_) async => {'id': _groupId, 'name': 'Disco Crew'});

      await _pumpWithRouter(
        tester,
        const CreateGroupScreen(),
        [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ],
      );

      await tester.enterText(find.byType(TextField).first, 'Disco Crew');
      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      verifyNever(() => media.uploadGroupCover(any()));
      final captured = verify(() => group.createGroup(captureAny())).captured;
      expect((captured.single as Map)['cover_url'], isNull);
    });

    testWidgets('shows the group-limit dialog instead of creating at 5 groups',
        (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();
      when(() => group.getUserGroupCount()).thenAnswer((_) async => 5);

      await _pumpWithRouter(
        tester,
        const CreateGroupScreen(),
        [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ],
      );

      await tester.enterText(find.byType(TextField).first, 'Disco Crew');
      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      expect(find.text('Límite alcanzado'), findsOneWidget);
      expect(find.textContaining('límite de 5 grupos'), findsOneWidget);
      verifyNever(() => media.uploadGroupCover(any()));
      verifyNever(() => group.createGroup(any()));
    });

    testWidgets('empty name: no service call and no limit dialog (TST-07/M-14)',
        (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();

      await _pumpWithRouter(
        tester,
        const CreateGroupScreen(),
        [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ],
      );

      await tester.tap(find.text('Crear'));
      await tester.pumpAndSettle();

      verifyNever(() => group.getUserGroupCount());
      verifyNever(() => group.createGroup(any()));
      verifyNever(() => media.uploadGroupCover(any()));
      expect(find.text('Límite alcanzado'), findsNothing);
      expect(find.byType(CreateGroupScreen), findsOneWidget);
    });

    testWidgets('whitespace-only name: no service call and no limit dialog '
        '(I-73 requiredValidator trim-empty)', (tester) async {
      final media = _MockMediaService();
      final group = _MockGroupService();

      await _pumpWithRouter(
        tester,
        const CreateGroupScreen(),
        [
          mediaServiceProvider.overrideWithValue(media),
          groupServiceProvider.overrideWithValue(group),
        ],
      );

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

  group('MyGroupsScreen', () {
    testWidgets('shows empty state when the provider returns no groups',
        (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [myGroupsProvider.overrideWith(_FakeMyGroupsNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('No perteneces a ningún grupo'), findsOneWidget);
      expect(find.text('Crea un grupo o únete a uno existente'), findsOneWidget);
    });

    testWidgets('renders group rows from the provider', (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [
          myGroupsProvider.overrideWith(
            () => _FakeMyGroupsNotifier(
              data: [
                _group(_groupId, 'Disco Crew', myRole: 'promotor'),
                _group('44444444-4444-4444-4444-444444444444', 'Vinyl Lovers',
                    myRole: 'member'),
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Vinyl Lovers'), findsOneWidget);
      expect(find.text('PROMOTOR · '), findsOneWidget);
    });

    testWidgets('renders ErrorView with retry when the provider fails',
        (tester) async {
      await _pump(
        tester,
        const MyGroupsScreen(),
        [
          myGroupsProvider.overrideWith(
            () => _FakeMyGroupsNotifier(error: Exception('grupos caídos')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });

  group('GroupDetailScreen', () {
    testWidgets('renders group header and tabs when data is loaded',
        (tester) async {
      await _pump(
        tester,
        const GroupDetailScreen(groupId: _groupId),
        [
          groupDetailProvider.overrideWith(
            () => _FakeGroupDetailNotifier(
              data: {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
            ),
          ),
          groupMembersProvider.overrideWith(
            () => _FakeGroupMembersNotifier(
              data: [
                {'user_id': _userId1, 'role': 'promotor', 'users': {'username': 'ana'}},
                {'user_id': _userId2, 'role': 'member', 'users': {'username': 'lucas'}},
              ],
            ),
          ),
          contributionsProvider.overrideWith(
            () => _FakeContributionsNotifier(
              data: GroupContributionsData(
                contributors: [
                  {'user_id': _userId1, 'shards_contributed': 50, 'users': {'username': 'ana'}},
                ],
                myContribution: 30,
              ),
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Miembros'), findsOneWidget);
      expect(find.text('Eventos'), findsOneWidget);
      expect(find.textContaining('2 / 14 miembros'), findsOneWidget);
      expect(find.textContaining('Mi contribuci\u00f3n: 30'), findsOneWidget);
    });

    testWidgets('renders ErrorView when the group provider fails',
        (tester) async {
      await _pump(
        tester,
        const GroupDetailScreen(groupId: _groupId),
        [
          groupDetailProvider.overrideWith(
            () => _FakeGroupDetailNotifier(error: Exception('grupo perdido')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });

    testWidgets('donate button navigates to the donate route (TST-07/M-14)',
        (tester) async {
      final harness = await _pumpGroupDetail(tester, _loadedGroupDetailOverrides());

      await tester.tap(find.text('Donar shards'));
      await tester.pumpAndSettle();

      expect(find.text('donate-$_groupId'), findsOneWidget);
      expect(
        harness.router.state.matchedLocation,
        RoutePaths.donateToGroup(_groupId),
      );
    });

    testWidgets(
        'leave-group flow: menu → confirm dialog → leaveGroup service call → '
        'pops back (TST-07/M-14)', (tester) async {
      await _pumpGroupDetail(tester, _loadedGroupDetailOverrides());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abandonar grupo'));
      await tester.pumpAndSettle();

      expect(find.text('¿Estás seguro?'), findsOneWidget);

      // Cancelling keeps the screen.
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupDetailScreen), findsOneWidget);

      // Confirming deletes the membership and pops to the parent route.
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
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
    });
  });

  group('DonateShardsScreen', () {
    testWidgets('renders donation form', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.text('Donar shards'), findsOneWidget);
      expect(find.textContaining('Test Group'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('shows boost info text', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.textContaining('impulsarán el ranking'), findsOneWidget);
    });

    testWidgets('shows donation button', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );
      expect(find.text('Donar'), findsOneWidget);
    });

    testWidgets('amount below 1 shows the invalid-amount snackbar and never '
        'touches the repository (I-73 numericValidator)', (tester) async {
      await _pump(
        tester,
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        [],
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Donar'));
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

      expect(find.text('Ingresa un monto válido'), findsOneWidget);
      expect(find.byType(DonateShardsScreen), findsOneWidget);
    });
  });

  group('InviteScreen', () {
    testWidgets('renders search bar and hint text', (tester) async {
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
          searchResultsProvider.overrideWith(_FakeSearchResultsNotifier.new),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Buscar usuarios'), findsOneWidget);
      expect(find.textContaining('Escribe al menos 2 caracteres'), findsOneWidget);
    });

    testWidgets('excludes existing members from search results', (tester) async {
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(
            () => _FakeGroupMembersNotifier(
              data: [
                {'user_id': _userId1, 'role': 'member'},
              ],
            ),
          ),
          searchResultsProvider.overrideWith(
            () => _FakeSearchResultsNotifier(
              data: [
                {'id': _userId1, 'username': 'ana', 'avatar_url': null},
                {'id': _userId2, 'username': 'lucas', 'avatar_url': null},
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pumpAndSettle();
      expect(find.text('@lucas'), findsOneWidget);
      expect(find.text('@ana'), findsNothing);
    });

    testWidgets('debounces rapid keystrokes into a single query after 300ms',
        (tester) async {
      final recording = _RecordingSearchResultsNotifier();
      await _pump(
        tester,
        InviteScreen(groupId: _groupId),
        [
          groupMembersProvider.overrideWith(_FakeGroupMembersNotifier.new),
          searchResultsProvider.overrideWith(() => recording),
        ],
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'l');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(recording.queries, ['lu'],
          reason: 'intermediate keystrokes must not fire a query');
    });
  });

  group('GroupMembersScreen', () {
    testWidgets('renders loading state first', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No hay miembros'), findsNothing);
    });

    testWidgets('renders empty state when no members', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      await tester.pumpAndSettle();
      expect(find.text('No hay miembros'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders screen with members title', (tester) async {
      await _pump(tester, const GroupMembersScreen(groupId: _groupId), []);
      await tester.pumpAndSettle();
      expect(find.text('Miembros'), findsOneWidget);
    });
  });

  group('LeaderboardScreen', () {
    testWidgets('renders leaderboard title and size tier chips', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [leaderboardProvider.overrideWith(_FakeLeaderboardNotifier.new)],
      );
      expect(find.text('Ranking de grupos'), findsOneWidget);
      expect(find.text('micro'), findsOneWidget);
      expect(find.text('small'), findsOneWidget);
      expect(find.text('medium'), findsOneWidget);
      expect(find.text('large'), findsOneWidget);
    });

    testWidgets('renders rankings from the provider', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [
          leaderboardProvider.overrideWith(
            () => _FakeLeaderboardNotifier(
              data: [
                {
                  ..._group('44444444-4444-4444-4444-444444444444', 'Disco Crew'),
                  'rank_position': 1,
                  'score': 500,
                  'member_count': 12,
                },
                {
                  ..._group('55555555-5555-5555-5555-555555555555', 'Vinyl Lovers'),
                  'rank_position': 2,
                  'score': 300,
                  'member_count': 8,
                },
              ],
            ),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('Disco Crew'), findsOneWidget);
      expect(find.text('Vinyl Lovers'), findsOneWidget);
      expect(find.textContaining('12 miembros'), findsOneWidget);
      expect(find.textContaining('500 shards'), findsOneWidget);
    });

    testWidgets('shows empty ranking state', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [leaderboardProvider.overrideWith(_FakeLeaderboardNotifier.new)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin datos de ranking'), findsOneWidget);
    });

    testWidgets('renders ErrorView when the provider fails', (tester) async {
      await _pump(
        tester,
        const LeaderboardScreen(),
        [
          leaderboardProvider.overrideWith(
            () => _FakeLeaderboardNotifier(error: Exception('ranking caído')),
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
    });
  });
}
