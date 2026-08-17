import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/features/party_finder/providers/party_finder_providers.dart';
import 'package:samay/features/party_finder/screens/party_finder_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/error_view.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';

/// PFND screen widget tests (I-60): discovery-off first-run explainer,
/// opt-in toggle persistence, match cards (username, shared count, tag
/// chips), block → service + reload, tap → user profile route, empty and
/// error states. Providers are pinned with fake notifiers; the block path
/// goes through a mocked [FriendsRepository].
const _otherId = '22222222-2222-2222-2222-222222222222';

class _FakeDiscoveryOptInNotifier extends DiscoveryOptInNotifier {
  _FakeDiscoveryOptInNotifier(this.value);

  bool value;
  bool? persisted;

  @override
  Future<bool> build() async => value;

  @override
  Future<void> setOptIn(bool v) async {
    persisted = v;
    value = v;
    state = AsyncData(v);
  }
}

class _FakePartyMatchesNotifier extends PartyMatchesNotifier {
  _FakePartyMatchesNotifier(this.data, {this.error, this.gate});

  final List<Map<String, dynamic>> data;
  final Object? error;

  /// When set, the first [build] waits on it (skeleton-frame pinning, the
  /// U-22 feed-test pattern).
  final Future<void>? gate;
  int builds = 0;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    if (gate != null) await gate;
    if (error != null) throw error!;
    return data;
  }
}

class _MockFriendsRepository extends Mock implements FriendsRepository {}

Map<String, dynamic> _match(
  String id, {
  String username = 'ana',
  List<String> tags = const ['musica'],
}) {
  return {
    'id': id,
    'username': username,
    'avatar_url': null,
    'interest_tags': tags,
    'shared_tags': tags,
    'shared_count': tags.length,
  };
}

ProviderContainer _container({
  bool optIn = false,
  List<Map<String, dynamic>> matches = const [],
  Object? matchesError,
  Future<void>? matchesGate,
  FriendsRepository? friends,
}) {
  final container = ProviderContainer(
    overrides: [
      discoveryOptInProvider.overrideWith(
        () => _FakeDiscoveryOptInNotifier(optIn),
      ),
      partyMatchesProvider.overrideWith(
        () => _FakePartyMatchesNotifier(
          matches,
          error: matchesError,
          gate: matchesGate,
        ),
      ),
      if (friends != null)
        friendsRepositoryProvider.overrideWithValue(friends),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester, {
  bool optIn = false,
  List<Map<String, dynamic>> matches = const [],
  Object? matchesError,
  Future<void>? matchesGate,
  FriendsRepository? friends,
  GoRouter? router,
}) async {
  final container = _container(
    optIn: optIn,
    matches: matches,
    matchesError: matchesError,
    matchesGate: matchesGate,
    friends: friends,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router == null
          ? const MaterialApp(
              locale: Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PartyFinderScreen(),
            )
          : MaterialApp.router(
              routerConfig: router,
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('PartyFinderScreen', () {
    testWidgets(
        'shows the avatar+lines skeleton while the matches load '
        '(U-22 handoff, §5.8)', (tester) async {
      final gate = Completer<void>();
      final container = _container(
        optIn: true,
        matches: [_match(_otherId, username: 'ana')],
        matchesGate: gate.future,
      );
      // Bounded pump: the shimmer sweep never settles while the gate is
      // pending, so _pumpScreen's pumpAndSettle would time out (the U-22
      // feed-test pattern).
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PartyFinderScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(VSkeletonList),
        findsOneWidget,
        reason: 'the list-y match rows show the skeleton on first load, '
            'not the bare spinner',
      );
      expect(find.byType(VLoadingView), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(VSkeletonList), findsNothing);
      expect(find.text('@ana'), findsOneWidget);
    });

    testWidgets('shows the discovery-off explainer with the toggle when off',
        (tester) async {
      await _pumpScreen(tester);

      expect(find.text('Party Finder'), findsOneWidget);
      expect(find.text('Descubrimiento está apagado'), findsOneWidget);
      expect(find.text('Aparecer en Party Finder'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      final switchFinder = find.byType(Switch);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);
    });

    testWidgets('toggling the switch on persists the opt-in and reveals the '
        'matches area', (tester) async {
      final container = await _pumpScreen(tester);
      final optIn =
          container.read(discoveryOptInProvider.notifier)
              as _FakeDiscoveryOptInNotifier;

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(optIn.persisted, isTrue);
      expect(find.text('Descubrimiento está apagado'), findsNothing);
      expect(find.text('Aún no hay coincidencias'), findsOneWidget);
    });

    testWidgets('renders match cards with username, shared count and tag '
        'chips', (tester) async {
      await _pumpScreen(
        tester,
        optIn: true,
        matches: [
          _match(_otherId, username: 'ana', tags: ['musica', 'cine']),
          _match('33333333-3333-3333-3333-333333333333',
              username: 'luis', tags: ['musica']),
        ],
      );

      expect(find.text('@ana'), findsOneWidget);
      expect(find.text('@luis'), findsOneWidget);
      expect(find.text('2 intereses en común'), findsOneWidget);
      expect(find.text('1 interés en común'), findsOneWidget);
      expect(find.text('Música'), findsNWidgets(2));
      expect(find.text('Cine'), findsOneWidget);
    });

    testWidgets('shows the empty state when no matches exist', (tester) async {
      await _pumpScreen(tester, optIn: true);

      expect(find.text('Aún no hay coincidencias'), findsOneWidget);
      expect(find.text('Agrega más intereses a tu perfil para encontrar '
          'personas afines.'), findsOneWidget);
      expect(find.byType(VEmptyView), findsOneWidget);
    });

    testWidgets('shows an error view with retry when loading fails',
        (tester) async {
      final container = await _pumpScreen(
        tester,
        optIn: true,
        matchesError: Exception('boom'),
      );

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.text('No se pudo cargar el Party Finder'), findsOneWidget);

      final matches = container.read(partyMatchesProvider.notifier)
          as _FakePartyMatchesNotifier;
      final before = matches.builds;
      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();
      expect(matches.builds, before + 1);
    });

    testWidgets('tapping a match navigates to the user profile route',
        (tester) async {
      final router = GoRouter(
        initialLocation: RoutePaths.partyFinder,
        routes: [
          GoRoute(
            path: RoutePaths.partyFinder,
            builder: (_, _) => const PartyFinderScreen(),
          ),
          GoRoute(
            path: RoutePaths.userProfile(':userId'),
            builder: (_, _) => const Scaffold(
              body: Center(child: Text('PROFILE STUB')),
            ),
          ),
        ],
      );
      await _pumpScreen(
        tester,
        optIn: true,
        matches: [_match(_otherId, username: 'ana')],
        router: router,
      );

      await tester.tap(find.text('@ana'));
      await tester.pumpAndSettle();

      expect(find.text('PROFILE STUB'), findsOneWidget);
    });

    testWidgets('blocking a match calls the service, shows the snackbar and '
        'reloads', (tester) async {
      final friends = _MockFriendsRepository();
      when(() => friends.blockUser(any())).thenAnswer((_) async {});

      final container = await _pumpScreen(
        tester,
        optIn: true,
        matches: [_match(_otherId, username: 'ana')],
        friends: friends,
      );

      await tester.tap(find.byTooltip('Bloquear'));
      // Bounded pumps, not pumpAndSettle: the fake clock must not advance
      // past pending timers, which would run the snackbar through its full
      // 4s lifecycle and dismiss it (LUXE restyle, XL-13).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      verify(() => friends.blockUser(_otherId)).called(1);
      expect(find.text('Usuario bloqueado'), findsOneWidget);
      expect(
        (container.read(partyMatchesProvider.notifier)
                as _FakePartyMatchesNotifier)
            .builds,
        2,
      );
    });

    testWidgets('a failed block surfaces the mapped error snackbar',
        (tester) async {
      final friends = _MockFriendsRepository();
      when(() => friends.blockUser(any())).thenThrow(
        const SocketException('network down'),
      );

      await _pumpScreen(
        tester,
        optIn: true,
        matches: [_match(_otherId, username: 'ana')],
        friends: friends,
      );

      await tester.tap(find.byTooltip('Bloquear'));
      // Bounded pumps — see the block-success test above (pending timers vs
      // the 4s snackbar lifecycle under pumpAndSettle).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Error de conexión. Verifica tu internet.'),
          findsOneWidget);
    });
  });
}
