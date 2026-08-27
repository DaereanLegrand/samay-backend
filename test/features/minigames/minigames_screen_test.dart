import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
import 'package:samay/features/minigames/screens/minigame_session_detail_screen.dart';
import 'package:samay/features/minigames/screens/minigames_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/state_views.dart';

/// GMCR foundation screen tests (I-63): the five game-type cards render,
/// the wager create flow drives the provider action with a fake service,
/// session cards show status chips, and empty/error states behave.
const _groupId = '22222222-2222-2222-2222-222222222222';
const _userId = '11111111-1111-1111-1111-111111111111';
const _sessionId = '33333333-3333-3333-3333-333333333333';

Map<String, dynamic> _session({
  String id = _sessionId,
  String gameType = 'poke_chain',
  String status = 'active',
  int wager = 50,
}) {
  return {
    'id': id,
    'group_id': _groupId,
    'game_type': gameType,
    'status': status,
    'shard_wager': wager,
    'participants': [_userId],
    'winner_id': null,
    'created_at': '2026-08-09T21:00:00Z',
  };
}

class _FakeSessionsNotifier extends MinigameSessionsNotifier {
  _FakeSessionsNotifier(this.data, {this.error});

  final List<Map<String, dynamic>> data;
  final Object? error;
  int builds = 0;
  MinigameType? createdType;
  int? createdWager;
  List<String>? createdInviteeIds;
  Object? createError;

  @override
  Future<List<Map<String, dynamic>>> build(String groupId) async {
    builds++;
    if (error != null) throw error!;
    return data;
  }

  @override
  Future<String> create(
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
  }) async {
    if (createError != null) throw createError!;
    createdType = type;
    createdWager = wager;
    createdInviteeIds = inviteeIds;
    return 'new-session-id';
  }
}

class _FakeMySessionsNotifier extends MyMinigameSessionsNotifier {
  _FakeMySessionsNotifier(this.data, {this.error});

  final List<Map<String, dynamic>> data;
  final Object? error;
  int builds = 0;
  MinigameType? createdType;
  int? createdWager;
  List<String>? createdInviteeIds;
  Object? createError;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    if (error != null) throw error!;
    return data;
  }

  @override
  Future<String> create(
    MinigameType type,
    int wager, {
    List<String> inviteeIds = const [],
  }) async {
    if (createError != null) throw createError!;
    createdType = type;
    createdWager = wager;
    createdInviteeIds = inviteeIds;
    return 'new-session-id';
  }
}

class _StubSearchResultsNotifier extends SearchResultsNotifier {
  _StubSearchResultsNotifier(this.data);

  final List<UserSearchResult> data;

  @override
  Future<List<UserSearchResult>> build(String arg) async => data;
}

class _StubMyGroupsNotifier extends MyGroupsNotifier {
  _StubMyGroupsNotifier(this.data);

  final List<Group> data;

  @override
  Future<List<Group>> build() async => data;
}

class _FakeSessionStatusNotifier extends MinigameSessionStatusNotifier {
  _FakeSessionStatusNotifier(this.row);

  final Map<String, dynamic> row;

  @override
  Future<Map<String, dynamic>> build(String sessionId) async => row;
}

class _FakeInviteNotifier extends MinigameInviteNotifier {
  _FakeInviteNotifier(this.invite);

  final Map<String, dynamic>? invite;

  @override
  Future<Map<String, dynamic>?> build(String sessionId) async => invite;
}

ProviderContainer _container({
  List<Map<String, dynamic>> sessions = const [],
  Object? sessionsError,
  List<Map<String, dynamic>> mySessions = const [],
  Object? mySessionsError,
  List<Group> myGroups = const [],
  List<UserSearchResult> searchUsers = const [],
  Map<String, dynamic>? sessionStatus,
  Map<String, dynamic>? invite,
}) {
  final container = ProviderContainer(
    overrides: [
      minigameSessionsProvider.overrideWith(
        () => _FakeSessionsNotifier(sessions, error: sessionsError),
      ),
      myMinigameSessionsProvider.overrideWith(
        () => _FakeMySessionsNotifier(mySessions, error: mySessionsError),
      ),
      myGroupsProvider.overrideWith(() => _StubMyGroupsNotifier(myGroups)),
      if (searchUsers.isNotEmpty)
        searchResultsProvider.overrideWith(
          () => _StubSearchResultsNotifier(searchUsers),
        ),
      if (sessionStatus != null)
        sessionStatusProvider.overrideWith(
          () => _FakeSessionStatusNotifier(sessionStatus),
        ),
      if (invite != null)
        minigameInviteProvider.overrideWith(
          () => _FakeInviteNotifier(invite),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester, {
  String? groupId = _groupId,
  List<Map<String, dynamic>> sessions = const [],
  Object? sessionsError,
  List<Map<String, dynamic>> mySessions = const [],
  Object? mySessionsError,
  List<Group> myGroups = const [],
  List<UserSearchResult> searchUsers = const [],
}) async {
  final container = _container(
    sessions: sessions,
    sessionsError: sessionsError,
    mySessions: mySessions,
    mySessionsError: mySessionsError,
    myGroups: myGroups,
    searchUsers: searchUsers,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MinigamesScreen(groupId: groupId),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('MinigamesScreen', () {
    testWidgets('renders the five game-type cards with names and taglines',
        (tester) async {
      await _pumpScreen(tester);

      expect(find.text('Juegos'), findsOneWidget);
      for (final name in const [
        'Cadena de Pokes',
        'Preguntas',
        'Verdad o Reto',
        'Botella',
        'Retos',
      ]) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Pasa el poke antes de que se acabe el tiempo'),
          findsOneWidget);
      expect(find.text('Gira la botella y veamos a quién apunta'),
          findsOneWidget);
    });

    testWidgets('selecting a game, entering a wager and confirming creates '
        'the session through the provider', (tester) async {
      final container = await _pumpScreen(tester);

      await tester.tap(find.text('Verdad o Reto'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '25');
      await tester.tap(find.text('Crear partida'));
      // The create action first opens the player picker; back dismisses it
      // without selecting anyone (empty invite list) and the session is
      // created.
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      // Bounded pumps, not pumpAndSettle: the fake clock must not advance
      // past pending timers, which would run the snackbar through its full
      // 4s lifecycle and dismiss it (LUXE restyle, XL-13).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      expect(notifier.createdType, MinigameType.truthDare);
      expect(notifier.createdWager, 25);
      expect(notifier.createdInviteeIds, isEmpty);
      expect(find.text('Partida creada'), findsOneWidget);
    });

    testWidgets('selecting players in the picker invites them on create',
        (tester) async {
      final container = await _pumpScreen(
        tester,
        searchUsers: const [
          UserSearchResult(id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', username: 'zoe'),
        ],
      );

      await tester.tap(find.text('Preguntas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();

      // The picker opened — search and select the user. The debounce timer
      // needs an explicit clock advance to fire (pumpAndSettle alone stops
      // before a plain Timer schedules a frame).
      await tester.enterText(find.byType(TextField), 'zo');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@zoe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invitar (1)'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      expect(notifier.createdType, MinigameType.questions);
      expect(notifier.createdInviteeIds, ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa']);
      expect(find.text('Partida creada'), findsOneWidget);
    });

    testWidgets('a zero wager still creates the session (social games)',
        (tester) async {
      final container = await _pumpScreen(tester);

      await tester.tap(find.text('Botella'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      expect(notifier.createdType, MinigameType.drunkBottle);
      expect(notifier.createdWager, 0);
    });

    testWidgets('an invalid wager input is treated as zero (no crash)',
        (tester) async {
      final container = await _pumpScreen(tester);

      await tester.tap(find.text('Preguntas'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      expect(notifier.createdWager, 0);
    });

    testWidgets('the create button is disabled until a game is selected',
        (tester) async {
      await _pumpScreen(tester);

      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Crear partida'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.text('Preguntas'));
      await tester.pumpAndSettle();

      final enabled = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Crear partida'),
          matching: find.byType(TextButton),
        ),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('an insufficient-shards rejection surfaces the friendly '
        'snackbar', (tester) async {
      final container = await _pumpScreen(tester);
      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      notifier.createError = const MinigameSessionRejectedException(
        MinigameSessionRejection.insufficientShards,
      );

      await tester.tap(find.text('Cadena de Pokes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      // Bounded pumps — pumpAndSettle would advance the fake clock past the
      // 4s snackbar's auto-dismiss (LUXE restyle, XL-13).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('No tienes suficientes shards para esta apuesta.'),
        findsOneWidget,
      );
    });

    testWidgets('a not-member rejection surfaces the friendly snackbar',
        (tester) async {
      final container = await _pumpScreen(tester);
      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      notifier.createError = const MinigameSessionRejectedException(
        MinigameSessionRejection.notMember,
      );

      await tester.tap(find.text('Preguntas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      // Bounded pumps — pumpAndSettle would advance the fake clock past the
      // 4s snackbar's auto-dismiss (LUXE restyle, XL-13).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('No eres miembro de este grupo.'), findsOneWidget);
    });

    testWidgets('session cards render with game name, wager and status chips',
        (tester) async {
      await _pumpScreen(
        tester,
        sessions: [
          _session(),
          _session(
            id: '99999999-9999-9999-9999-999999999999',
            gameType: 'questions',
            status: 'finished',
            wager: 0,
          ),
        ],
      );

      expect(find.text('Cadena de Pokes'), findsNWidgets(2));
      expect(find.text('Preguntas'), findsNWidgets(2));
      expect(find.text('Apuesta: 50 shards'), findsOneWidget);
      expect(find.text('Activa'), findsOneWidget);
      expect(find.text('Terminada'), findsOneWidget);
    });

    testWidgets('shows the empty state when the group has no sessions',
        (tester) async {
      await _pumpScreen(tester);

      expect(find.text('Aún no hay partidas en este grupo'), findsOneWidget);
      expect(
        find.text('Crea la primera partida con uno de los juegos de arriba.'),
        findsOneWidget,
      );
      expect(find.byType(VEmptyView), findsOneWidget);
    });

    testWidgets('shows an error view with retry when loading fails',
        (tester) async {
      final container = await _pumpScreen(
        tester,
        sessionsError: Exception('boom'),
      );

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('No se pudieron cargar las partidas'), findsOneWidget);

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      final before = notifier.builds;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(notifier.builds, before + 1);
    });

    testWidgets('tapping a session card opens the session detail route',
        (tester) async {
      final container = _container(
        sessions: [_session()],
        sessionStatus: _session(),
      );
      final router = GoRouter(
        initialLocation: RoutePaths.minigames(_groupId),
        routes: [
          GoRoute(
            path: RoutePaths.minigames(':groupId'),
            builder: (_, _) => const MinigamesScreen(groupId: _groupId),
          ),
          GoRoute(
            path: RoutePaths.minigameSession(':sessionId'),
            builder: (_, state) => MinigameSessionDetailScreen(
              sessionId: state.pathParameters['sessionId']!,
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

      await tester.tap(find.text('Apuesta: 50 shards'));
      await tester.pumpAndSettle();

      expect(find.byType(MinigameSessionDetailScreen), findsOneWidget);
      expect(find.text('Cadena de Pokes'), findsOneWidget);
    });
  });

  group('MinigamesScreen — DIRECT scope (direct-minigames 2026-08-27)', () {
    testWidgets('renders the Direct scope by default with no groupId',
        (tester) async {
      await _pumpScreen(tester, groupId: null);

      // Direct chip selected + the direct empty state (no group required).
      expect(find.text('Directa'), findsOneWidget);
      expect(find.text('Grupo'), findsOneWidget);
      expect(find.text('Aún no hay partidas directas'), findsOneWidget);
      expect(
        find.text('Crea una partida para jugar ya con un amigo, sin necesidad de un grupo.'),
        findsOneWidget,
      );
      // The five game cards are still creatable in the direct scope.
      expect(find.text('Cadena de Pokes'), findsOneWidget);
    });

    testWidgets('creates a DIRECT session through the direct provider',
        (tester) async {
      final container = await _pumpScreen(tester, groupId: null);

      await tester.tap(find.text('Verdad o Reto'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '25');
      await tester.tap(find.text('Crear partida'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier = container
          .read(myMinigameSessionsProvider.notifier)
          as _FakeMySessionsNotifier;
      expect(notifier.createdType, MinigameType.truthDare);
      expect(notifier.createdWager, 25);
      expect(find.text('Partida creada'), findsOneWidget);
    });

    testWidgets('switches from Direct to the Group picker and back',
        (tester) async {
      await _pumpScreen(tester, groupId: null);

      await tester.tap(find.text('Grupo'));
      await tester.pumpAndSettle();
      // The group picker shows the zero-groups empty state (Direct is the
      // default for a fresh user — groups are optional, not required).
      expect(find.text('Aún no tienes grupos'), findsOneWidget);
      expect(find.text('Aún no hay partidas directas'), findsNothing);

      await tester.tap(find.text('Directa'));
      await tester.pumpAndSettle();
      expect(find.text('Aún no hay partidas directas'), findsOneWidget);
    });
  });
}
