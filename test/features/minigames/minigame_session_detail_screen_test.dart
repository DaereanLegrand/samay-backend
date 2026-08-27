import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/minigames/providers/minigames_providers.dart';
import 'package:samay/features/minigames/screens/minigame_session_detail_screen.dart';
import 'package:samay/l10n/app_localizations.dart';

/// MinigameSessionDetailScreen tests (140_minigame_invites): the session
/// renders its game/wager/status, a PENDING invite shows Aceptar/Rechazar
/// (accept drives the provider + snackbar), and a FINISHED session closes the
/// invite (no accept path).
const _groupId = '22222222-2222-2222-2222-222222222222';
const _sessionId = '33333333-3333-3333-3333-333333333333';
const _inviteId = '44444444-4444-4444-4444-444444444444';

Map<String, dynamic> _session({String status = 'active'}) {
  return {
    'id': _sessionId,
    'group_id': _groupId,
    'game_type': 'poke_chain',
    'status': status,
    'shard_wager': 0,
    'participants': ['11111111-1111-1111-1111-111111111111'],
    'winner_id': null,
    'created_at': '2026-08-09T21:00:00Z',
  };
}

Map<String, dynamic> _invite({String status = 'pending'}) {
  return {
    'id': _inviteId,
    'session_id': _sessionId,
    'invitee_id': '11111111-1111-1111-1111-111111111111',
    'created_by': _groupId,
    'status': status,
    'created_at': '2026-08-26T10:00:00Z',
  };
}

class _FakeStatusNotifier extends MinigameSessionStatusNotifier {
  _FakeStatusNotifier(this.row);
  final Map<String, dynamic> row;
  @override
  Future<Map<String, dynamic>> build(String id) async => row;
}

class _FakeInviteNotifier extends MinigameInviteNotifier {
  _FakeInviteNotifier(this.invite);
  Map<String, dynamic>? invite;
  int acceptCalls = 0;
  int declineCalls = 0;

  @override
  Future<Map<String, dynamic>?> build(String id) async => invite;

  @override
  Future<void> accept() async {
    acceptCalls++;
    invite = _invite(status: 'accepted');
    await refresh();
  }

  @override
  Future<void> decline() async {
    declineCalls++;
    invite = _invite(status: 'declined');
    await refresh();
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> session,
  Map<String, dynamic>? invite,
}) async {
  final container = ProviderContainer(
    overrides: [
      sessionStatusProvider.overrideWith(() => _FakeStatusNotifier(session)),
      minigameInviteProvider.overrideWith(() => _FakeInviteNotifier(invite)),
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
        home: MinigameSessionDetailScreen(sessionId: _sessionId),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('MinigameSessionDetailScreen', () {
    testWidgets('renders the game, status and participant count', (tester) async {
      await _pump(tester, session: _session());

      expect(find.text('Cadena de Pokes'), findsOneWidget);
      expect(find.text('Participantes: 1'), findsOneWidget);
      expect(find.text('Activa'), findsOneWidget);
      expect(find.text('Aceptar'), findsNothing);
      expect(find.text('Rechazar'), findsNothing);
    });

    testWidgets('a pending invite shows Aceptar/Rechazar and accept drives '
        'the provider', (tester) async {
      final container = await _pump(
        tester,
        session: _session(),
        invite: _invite(),
      );

      expect(find.text('Te invitaron a esta partida.'), findsOneWidget);
      expect(find.text('Aceptar'), findsOneWidget);
      expect(find.text('Rechazar'), findsOneWidget);

      await tester.tap(find.text('Aceptar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier =
          container.read(minigameInviteProvider(_sessionId).notifier)
              as _FakeInviteNotifier;
      expect(notifier.acceptCalls, 1);
      // The joined snackbar AND the accepted-state card both say it.
      expect(find.text('Te uniste a la partida'), findsWidgets);
    });

    testWidgets('declining drives the provider and shows the declined snackbar',
        (tester) async {
      final container = await _pump(
        tester,
        session: _session(),
        invite: _invite(),
      );

      await tester.tap(find.text('Rechazar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final notifier =
          container.read(minigameInviteProvider(_sessionId).notifier)
              as _FakeInviteNotifier;
      expect(notifier.declineCalls, 1);
      expect(find.text('Invitación rechazada'), findsOneWidget);
    });

    testWidgets('a finished session closes the invite (no accept path)',
        (tester) async {
      await _pump(
        tester,
        session: _session(status: 'finished'),
        invite: _invite(),
      );

      expect(find.text('Terminada'), findsOneWidget);
      expect(find.text('Aceptar'), findsNothing);
      expect(find.text('Rechazar'), findsNothing);
      expect(
        find.text('Esta partida ya terminó. Ya no puedes aceptar la invitación.'),
        findsOneWidget,
      );
    });

    testWidgets('an accepted invite shows the joined state', (tester) async {
      await _pump(
        tester,
        session: _session(),
        invite: _invite(status: 'accepted'),
      );

      expect(find.text('Te uniste a la partida'), findsOneWidget);
      expect(find.text('Aceptar'), findsNothing);
      expect(find.text('Rechazar'), findsNothing);
    });
  });
}