import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/services/minigame_service.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
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
  Object? createError;

  @override
  Future<List<Map<String, dynamic>>> build(String groupId) async {
    builds++;
    if (error != null) throw error!;
    return data;
  }

  @override
  Future<String> create(MinigameType type, int wager) async {
    if (createError != null) throw createError!;
    createdType = type;
    createdWager = wager;
    return 'new-session-id';
  }
}

ProviderContainer _container({
  List<Map<String, dynamic>> sessions = const [],
  Object? sessionsError,
}) {
  final container = ProviderContainer(
    overrides: [
      minigameSessionsProvider.overrideWith(
        () => _FakeSessionsNotifier(sessions, error: sessionsError),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester, {
  List<Map<String, dynamic>> sessions = const [],
  Object? sessionsError,
}) async {
  final container = _container(sessions: sessions, sessionsError: sessionsError);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MinigamesScreen(groupId: _groupId),
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
      await tester.pumpAndSettle();

      final notifier = container
          .read(minigameSessionsProvider(_groupId).notifier)
          as _FakeSessionsNotifier;
      expect(notifier.createdType, MinigameType.truthDare);
      expect(notifier.createdWager, 25);
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

    testWidgets('tapping a session card shows the detail placeholder',
        (tester) async {
      await _pumpScreen(tester, sessions: [_session()]);

      await tester.tap(find.text('Apuesta: 50 shards'));
      await tester.pumpAndSettle();

      expect(
        find.text('La partida se jugará aquí pronto.'),
        findsOneWidget,
      );
    });
  });
}
