import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/repositories/friends_repository.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/blocked_users_screen.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/my_groups_screen.dart';
import 'package:samay/features/profile/screens/public_profile_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

import '../../support/fake_supabase_http.dart' as support;

/// U-16 friends/groups FLOW ledger tests (R11-R15, 2026-08-11).
///
/// Pins the Juega-flow-alignment changes from U-13 §5.3 (the ledger in
/// `docs/development/phase-04-ui/2026-08-11_U16-friends-groups-flow.md`):
/// per-row request spinners (R11), count badges (R12), pull-to-refresh
/// including empty states (R13), search autofocus + min-chars hint (R14) and
/// the mutual-friend dialog (R15). R16/R17 (groups) live in
/// `test/features/groups/flow_test.dart`.

const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';
const _groupId1 = '33333333-3333-3333-3333-333333333333';

Map<String, dynamic> _user(String id, String username) => {
  'id': id,
  'username': username,
  'avatar_url': null,
};

class _MockFriendsRepository extends Mock implements FriendsRepository {}

class _MockGroupsRepository extends Mock implements GroupsRepository {}

/// Counting friends-list variant — the pull-to-refresh reload assertion (R13).
class _CountingFriendsListNotifier extends FriendsListNotifier {
  _CountingFriendsListNotifier(this.data);

  final List<Map<String, dynamic>> data;
  int builds = 0;

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    return data;
  }
}

class _StubFriendRequestsNotifier extends FriendRequestsNotifier {
  final FriendRequestsData data;
  _StubFriendRequestsNotifier({
    this.data = const FriendRequestsData(requests: [], names: {}),
  });

  @override
  Future<FriendRequestsData> build() async => data;
}

/// Counting requests variant — the tab-refresh reload assertion (R13).
class _CountingFriendRequestsNotifier extends FriendRequestsNotifier {
  _CountingFriendRequestsNotifier(this.data);

  final FriendRequestsData data;
  int builds = 0;

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<FriendRequestsData> build() async {
    builds++;
    return data;
  }
}

class _StubGroupInvitesNotifier extends GroupInvitesNotifier {
  final List<Map<String, dynamic>> data;
  _StubGroupInvitesNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

/// Counting group-invites variant — the invites-tab reload assertion (R13).
class _CountingGroupInvitesNotifier extends GroupInvitesNotifier {
  _CountingGroupInvitesNotifier(this.data);

  final List<Map<String, dynamic>> data;
  int builds = 0;

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    return data;
  }
}

/// Mutable requests variant (U-28): [build] reads the current [data], so a
/// container-level refresh re-derives the tab badges and they must follow.
class _LiveFriendRequestsNotifier extends FriendRequestsNotifier {
  FriendRequestsData data;

  _LiveFriendRequestsNotifier(this.data);

  @override
  Future<FriendRequestsData> build() async => data;
}

/// Counting blocked variant — the blocked-list reload assertion (R13).
class _CountingBlockedUsersNotifier extends BlockedUsersNotifier {
  _CountingBlockedUsersNotifier(this.data);

  final List<Map<String, dynamic>> data;
  int builds = 0;

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    return data;
  }
}

class _StubMyGroupsNotifier extends MyGroupsNotifier {
  final List<Map<String, dynamic>> data;
  _StubMyGroupsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

/// Counting my-groups variant — the groups-list reload assertion (R13).
class _CountingMyGroupsNotifier extends MyGroupsNotifier {
  _CountingMyGroupsNotifier(this.data);

  final List<Map<String, dynamic>> data;
  int builds = 0;

  @override
  Duration get refreshThrottle => Duration.zero;

  @override
  Future<List<Map<String, dynamic>>> build() async {
    builds++;
    return data;
  }
}

class _StubSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _StubSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

const _twoReceived = FriendRequestsData(
  requests: [
    {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
    {'type': 'received', 'friendship_id': 'f2', 'user_id': _userId2},
  ],
  names: {_userId1: 'ana', _userId2: 'lucas'},
);

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// The per-row in-flight spinner (R11): a 16-20px `CircularProgressIndicator`
/// inside the row being acted on.
Finder _rowSpinner(String rowName) => find.descendant(
  of: find.widgetWithText(ListTile, rowName),
  matching: find.byType(CircularProgressIndicator),
);

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('R11 — requests per-row busy spinners', () {
    testWidgets(
      'accepting a received request swaps ONLY that row\'s buttons for a '
      'spinner; the other row stays interactive',
      (tester) async {
        final friends = _MockFriendsRepository();
        final acceptCompleter = Completer<void>();
        when(
          () => friends.acceptFriendRequest('f1'),
        ).thenAnswer((_) => acceptCompleter.future);
        when(
          () => friends.declineFriendRequest(any()),
        ).thenAnswer((_) async {});

        await tester.pumpWidget(
          _wrap(
            const RequestsScreen(),
            overrides: [
              friendRequestsProvider.overrideWith(
                () => _StubFriendRequestsNotifier(data: _twoReceived),
              ),
              groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
              friendsRepositoryProvider.overrideWithValue(friends),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Aceptar'), findsNWidgets(2));

        await tester.tap(find.text('Aceptar').first);
        await tester.pump();

        expect(
          _rowSpinner('ana'),
          findsOneWidget,
          reason: 'the tapped row must show the in-flight spinner (R11)',
        );
        expect(
          find.descendant(
            of: find.widgetWithText(ListTile, 'lucas'),
            matching: find.text('Aceptar'),
          ),
          findsOneWidget,
          reason: 'the untouched row keeps its interactive accept button',
        );

        acceptCompleter.complete();
        await tester.pumpAndSettle();
        expect(
          _rowSpinner('ana'),
          findsNothing,
          reason: 'the spinner clears once the action completes',
        );
        expect(
          find.text('Aceptar'),
          findsNWidgets(2),
          reason: 'both rows are back to interactive buttons after reload',
        );
      },
    );

    testWidgets('declining a received request swaps only that row\'s buttons '
        'for a spinner', (tester) async {
      final friends = _MockFriendsRepository();
      when(() => friends.acceptFriendRequest(any())).thenAnswer((_) async {});
      final declineCompleter = Completer<void>();
      when(
        () => friends.declineFriendRequest('f1'),
      ).thenAnswer((_) => declineCompleter.future);

      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              () => _StubFriendRequestsNotifier(data: _twoReceived),
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
            friendsRepositoryProvider.overrideWithValue(friends),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rechazar').first);
      await tester.pump();

      expect(_rowSpinner('ana'), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'lucas'),
          matching: find.text('Rechazar'),
        ),
        findsOneWidget,
        reason: 'the untouched row keeps its decline button',
      );

      declineCompleter.complete();
      await tester.pumpAndSettle();
      expect(_rowSpinner('ana'), findsNothing);
    });

    testWidgets('sent-tab cancel gets the same per-row spinner', (
      tester,
    ) async {
      final friends = _MockFriendsRepository();
      final declineCompleter = Completer<void>();
      when(
        () => friends.declineFriendRequest('f9'),
      ).thenAnswer((_) => declineCompleter.future);

      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              () => _StubFriendRequestsNotifier(
                data: const FriendRequestsData(
                  requests: [
                    {
                      'type': 'sent',
                      'friendship_id': 'f9',
                      'user_id': _userId1,
                    },
                  ],
                  names: {_userId1: 'ana'},
                ),
              ),
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
            friendsRepositoryProvider.overrideWithValue(friends),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enviadas'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelar'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      expect(_rowSpinner('ana'), findsOneWidget);

      declineCompleter.complete();
      await tester.pumpAndSettle();
      expect(_rowSpinner('ana'), findsNothing);
    });

    testWidgets('group-invite accept row gets the same per-row spinner', (
      tester,
    ) async {
      final groups = _MockGroupsRepository();
      final acceptCompleter = Completer<void>();
      when(
        () => groups.acceptInvite('m1'),
      ).thenAnswer((_) => acceptCompleter.future);

      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              () => _StubFriendRequestsNotifier(
                data: const FriendRequestsData(requests: [], names: {}),
              ),
            ),
            groupInvitesProvider.overrideWith(
              () => _StubGroupInvitesNotifier(
                data: [
                  {
                    'id': 'm1',
                    'groups': {'name': 'Disco Crew'},
                    'role': 'member',
                  },
                  {
                    'id': 'm2',
                    'groups': {'name': 'Vinyl Lovers'},
                    'role': 'member',
                  },
                ],
              ),
            ),
            groupsRepositoryProvider.overrideWithValue(groups),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aceptar').first);
      await tester.pump();

      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Disco Crew'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Vinyl Lovers'),
          matching: find.text('Aceptar'),
        ),
        findsOneWidget,
      );

      acceptCompleter.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('R12 — count badges on entry points', () {
    VCountBadge tabBadge(WidgetTester tester, String tabLabel) {
      final badge = tester.widget<VCountBadge>(
        find.descendant(
          of: find.widgetWithText(Tab, tabLabel),
          matching: find.byType(VCountBadge),
        ),
      );
      return badge;
    }

    testWidgets('requests tabs show the received/invites counts and hide the '
        'sent one', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              () => _StubFriendRequestsNotifier(
                data: const FriendRequestsData(
                  requests: [
                    {
                      'type': 'received',
                      'friendship_id': 'f1',
                      'user_id': _userId1,
                    },
                    {
                      'type': 'received',
                      'friendship_id': 'f2',
                      'user_id': _userId2,
                    },
                    {
                      'type': 'sent',
                      'friendship_id': 'f3',
                      'user_id': _userId1,
                    },
                  ],
                  names: {_userId1: 'ana', _userId2: 'lucas'},
                ),
              ),
            ),
            groupInvitesProvider.overrideWith(
              () => _StubGroupInvitesNotifier(
                data: [
                  {
                    'id': 'm1',
                    'groups': {'name': 'Disco Crew'},
                    'role': 'member',
                  },
                ],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tabBadge(tester, 'Recibidas').count,
        2,
        reason: 'received tab badge counts the received requests (R12)',
      );
      expect(
        tabBadge(tester, 'Invitaciones').count,
        1,
        reason: 'invites tab badge counts the pending group invites (R12)',
      );
      expect(
        find.descendant(
          of: find.widgetWithText(Tab, 'Enviadas'),
          matching: find.byType(VCountBadge),
        ),
        findsNothing,
        reason: 'the sent tab carries no count badge',
      );
    });

    testWidgets('badges are hidden when the counts are zero', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              _StubFriendRequestsNotifier.new,
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(VCountBadge),
        findsNothing,
        reason: 'no pending counts → no badges anywhere (R12)',
      );
    });

    testWidgets('the my-groups Solicitudes button carries the total pending '
        'count (received + invites)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(_StubMyGroupsNotifier.new),
            friendRequestsProvider.overrideWith(
              () => _StubFriendRequestsNotifier(
                data: const FriendRequestsData(
                  requests: [
                    {
                      'type': 'received',
                      'friendship_id': 'f1',
                      'user_id': _userId1,
                    },
                  ],
                  names: {_userId1: 'ana'},
                ),
              ),
            ),
            groupInvitesProvider.overrideWith(
              () => _StubGroupInvitesNotifier(
                data: [
                  {
                    'id': 'm1',
                    'groups': {'name': 'Disco Crew'},
                    'role': 'member',
                  },
                ],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final badge = tester.widget<VCountBadge>(
        find.descendant(
          of: find.widgetWithText(TextButton, 'Solicitudes'),
          matching: find.byType(VCountBadge),
        ),
      );
      expect(
        badge.count,
        2,
        reason: '1 received friend request + 1 group invite (R12)',
      );
    });

    testWidgets('the my-groups Solicitudes button badge hides with zero '
        'pending', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(_StubMyGroupsNotifier.new),
            friendRequestsProvider.overrideWith(
              _StubFriendRequestsNotifier.new,
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.widgetWithText(TextButton, 'Solicitudes'),
          matching: find.byType(VCountBadge),
        ),
        findsNothing,
        reason: 'no pending requests/invites → the entry badge is hidden',
      );
    });

    testWidgets('tab badge counts UPDATE when the pending data changes '
        '(U-28 badges-count-updates pin)', (tester) async {
      final requests = _LiveFriendRequestsNotifier(
        const FriendRequestsData(
          requests: [
            {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
            {'type': 'received', 'friendship_id': 'f2', 'user_id': _userId2},
          ],
          names: {_userId1: 'ana', _userId2: 'lucas'},
        ),
      );
      final container = ProviderContainer(
        overrides: [
          friendRequestsProvider.overrideWith(() => requests),
          groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
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
            home: RequestsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tabBadge(tester, 'Recibidas').count, 2);

      // One request gets accepted: the received list drops to 1 — the tab
      // badge must re-derive 1.
      requests.data = const FriendRequestsData(
        requests: [
          {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
        ],
        names: {_userId1: 'ana'},
      );
      container.refresh(friendRequestsProvider);
      await tester.pumpAndSettle();

      expect(
        tabBadge(tester, 'Recibidas').count,
        1,
        reason: 'the count badge follows the provider state live',
      );
    });
  });

  group('R13 — pull-to-refresh on every list, including empties', () {
    Future<void> dragToRefresh(WidgetTester tester, Finder target) async {
      await tester.fling(target, const Offset(0, 300), 1000);
      await tester.pumpAndSettle();
    }

    testWidgets('friends list drag reloads the provider', (tester) async {
      final friends = _CountingFriendsListNotifier([_user(_userId1, 'ana')]);
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [friendsListProvider.overrideWith(() => friends)],
        ),
      );
      await tester.pumpAndSettle();
      expect(friends.builds, 1);

      await dragToRefresh(tester, find.byType(ListView));
      expect(
        friends.builds,
        2,
        reason: 'pull-to-refresh must reload the friends provider (R13)',
      );
    });

    testWidgets('friends list EMPTY state is still pull-to-refreshable', (
      tester,
    ) async {
      final friends = _CountingFriendsListNotifier(const []);
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [friendsListProvider.overrideWith(() => friends)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin amigos aún'), findsOneWidget);

      await dragToRefresh(tester, find.byType(SingleChildScrollView));
      expect(
        friends.builds,
        2,
        reason: 'the empty state must remain refreshable (R13)',
      );
    });

    testWidgets('requests received-tab drag reloads the requests provider', (
      tester,
    ) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(
          requests: [
            {'type': 'received', 'friendship_id': 'f1', 'user_id': _userId1},
          ],
          names: {_userId1: 'ana'},
        ),
      );
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(() => requests),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.builds, 1);

      await dragToRefresh(tester, find.byType(ListView));
      expect(
        requests.builds,
        2,
        reason: 'the requests tab must reload on pull (R13)',
      );
    });

    testWidgets('requests received EMPTY tab is still pull-to-refreshable', (
      tester,
    ) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(requests: [], names: {}),
      );
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(() => requests),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sin solicitudes recibidas'), findsOneWidget);

      await dragToRefresh(tester, find.byType(SingleChildScrollView));
      expect(
        requests.builds,
        2,
        reason: 'the empty received tab must remain refreshable (R13)',
      );
    });

    testWidgets('invites-tab drag reloads the group-invites provider', (
      tester,
    ) async {
      final requests = _CountingFriendRequestsNotifier(
        const FriendRequestsData(requests: [], names: {}),
      );
      final invites = _CountingGroupInvitesNotifier(const [
        {
          'id': 'm1',
          'groups': {'name': 'Disco Crew'},
          'role': 'member',
        },
      ]);
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(() => requests),
            groupInvitesProvider.overrideWith(() => invites),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(invites.builds, 1);

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      await dragToRefresh(tester, find.byType(ListView));
      expect(
        invites.builds,
        2,
        reason: 'the invites tab must reload on pull (R13)',
      );
    });

    testWidgets('blocked-users list drag reloads the provider', (tester) async {
      final blocked = _CountingBlockedUsersNotifier([_user(_userId1, 'ana')]);
      await tester.pumpWidget(
        _wrap(
          const BlockedUsersScreen(),
          overrides: [blockedUsersProvider.overrideWith(() => blocked)],
        ),
      );
      await tester.pumpAndSettle();
      expect(blocked.builds, 1);

      await dragToRefresh(tester, find.byType(ListView));
      expect(
        blocked.builds,
        2,
        reason: 'the blocked list must reload on pull (R13)',
      );
    });

    testWidgets('blocked-users EMPTY state is still pull-to-refreshable', (
      tester,
    ) async {
      final blocked = _CountingBlockedUsersNotifier(const []);
      await tester.pumpWidget(
        _wrap(
          const BlockedUsersScreen(),
          overrides: [blockedUsersProvider.overrideWith(() => blocked)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);

      await dragToRefresh(tester, find.byType(SingleChildScrollView));
      expect(
        blocked.builds,
        2,
        reason: 'the empty blocked state must remain refreshable (R13)',
      );
    });

    testWidgets('my-groups list drag reloads the provider', (tester) async {
      final groups = _CountingMyGroupsNotifier([
        {
          'id': _groupId1,
          'name': 'Disco Crew',
          'group_shards': 100,
          'my_role': 'member',
        },
      ]);
      await tester.pumpWidget(
        _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(() => groups),
            friendRequestsProvider.overrideWith(
              _StubFriendRequestsNotifier.new,
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(groups.builds, 1);

      await dragToRefresh(tester, find.byType(ListView));
      expect(
        groups.builds,
        2,
        reason: 'the groups list must reload on pull (R13)',
      );
    });

    testWidgets('my-groups EMPTY state is still pull-to-refreshable', (
      tester,
    ) async {
      final groups = _CountingMyGroupsNotifier(const []);
      await tester.pumpWidget(
        _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(() => groups),
            friendRequestsProvider.overrideWith(
              _StubFriendRequestsNotifier.new,
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No perteneces a ningún grupo'), findsOneWidget);

      await dragToRefresh(tester, find.byType(SingleChildScrollView));
      expect(
        groups.builds,
        2,
        reason: 'the empty groups state must remain refreshable (R13)',
      );
    });
  });

  group('R14 — search autofocus + min-chars hint', () {
    testWidgets('the search field takes keyboard focus on entry', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(_StubSearchResultsNotifier.new),
          ],
        ),
      );
      await tester.pump();

      expect(
        tester.testTextInput.hasAnyClients,
        isTrue,
        reason: 'autofocus must attach the keyboard to the field (R14)',
      );
    });

    testWidgets('queries shorter than 2 chars show the min-chars hint instead '
        'of results', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(
        find.text('Escribe al menos 2 caracteres para buscar'),
        findsOneWidget,
        reason: 'a 1-char query shows the min-2 hint (R14)',
      );
      expect(
        find.text('@ana'),
        findsNothing,
        reason: 'no results for a sub-2-char query',
      );
    });

    testWidgets('queries of 2+ chars render results', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('@ana'), findsOneWidget);
      expect(
        find.text('Escribe al menos 2 caracteres para buscar'),
        findsNothing,
      );
    });
  });

  group('R15 — mutual-friend dialog on instant accept', () {
    testWidgets('search: an accepted send opens the mutual-friend dialog '
        'instead of the snackbar', (tester) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.sendFriendRequest(_userId1),
      ).thenAnswer((_) async => 'accepted');

      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(data: [_user(_userId1, 'ana')]),
            ),
            friendsRepositoryProvider.overrideWithValue(friends),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agregar'));
      await tester.pumpAndSettle();

      expect(
        find.text('¡Solicitud aceptada!'),
        findsOneWidget,
        reason: 'instant accept must surface the mutual dialog (R15)',
      );
      expect(find.textContaining('ya son amigos'), findsOneWidget);
      expect(
        find.text('Solicitud enviada'),
        findsNothing,
        reason: 'the plain snackbar is not shown for an instant accept',
      );

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('search: a pending send keeps the snackbar and shows no '
        'dialog', (tester) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.sendFriendRequest(_userId1),
      ).thenAnswer((_) async => 'pending');

      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(data: [_user(_userId1, 'ana')]),
            ),
            friendsRepositoryProvider.overrideWithValue(friends),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agregar'));
      // LUXE note: bounded pumps, NOT pumpAndSettle — the screen's VAurora
      // drift advances the fake clock past the snackbar's 4s auto-dismiss
      // under pumpAndSettle (XL-10 MISTAKE XL-10-B).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Solicitud enviada'), findsOneWidget);
    });

    testWidgets('public profile: an accepted send opens the mutual-friend '
        'dialog', (tester) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.getUserProfile(_userId2),
      ).thenAnswer((_) async => null);
      when(
        () => friends.getFriendshipDetail(_userId2),
      ).thenAnswer((_) async => null);
      when(
        () => friends.getBlockStatus(_userId2),
      ).thenAnswer((_) async => false);
      when(
        () => friends.sendFriendRequest(_userId2),
      ).thenAnswer((_) async => 'accepted');

      await tester.pumpWidget(
        _wrap(
          const PublicProfileScreen(userId: _userId2),
          overrides: [friendsRepositoryProvider.overrideWithValue(friends)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agregar amigo'));
      await tester.pumpAndSettle();

      expect(
        find.text('¡Solicitud aceptada!'),
        findsOneWidget,
        reason: 'the public-profile send also honors the mutual dialog (R15)',
      );
    });
  });

  group('U-26 disabled controls — tapping does nothing (U-28 pin)', () {
    testWidgets('tapping the "Bloqueado" status readout fires no action: no '
        'dialog, no re-fetch, no navigation', (tester) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.getUserProfile(_userId2),
      ).thenAnswer((_) async => null);
      when(
        () => friends.getFriendshipDetail(_userId2),
      ).thenAnswer((_) async => null);
      when(
        () => friends.getBlockStatus(_userId2),
      ).thenAnswer((_) async => true);

      await tester.pumpWidget(
        _wrap(
          const PublicProfileScreen(userId: _userId2),
          overrides: [friendsRepositoryProvider.overrideWithValue(friends)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bloqueado'), findsOneWidget);

      await tester.tap(find.text('Bloqueado'));
      await tester.pumpAndSettle();

      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'a disabled status readout must not open anything',
      );
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'a disabled status readout must not toast anything',
      );
      expect(
        find.text('Bloqueado'),
        findsOneWidget,
        reason: 'the screen stays put',
      );
      verify(() => friends.getBlockStatus(_userId2)).called(1);
      verifyNever(() => friends.sendFriendRequest(_userId2));
      verifyNever(() => friends.declineFriendRequest(_userId2));
    });

    testWidgets('tapping the "Amigos" status readout fires no action', (
      tester,
    ) async {
      final friends = _MockFriendsRepository();
      when(
        () => friends.getUserProfile(_userId2),
      ).thenAnswer((_) async => null);
      when(() => friends.getFriendshipDetail(_userId2)).thenAnswer(
        (_) async => const {
          'id': 'f1',
          'status': 'accepted',
          'requester_id': 'x',
        },
      );
      when(
        () => friends.getBlockStatus(_userId2),
      ).thenAnswer((_) async => false);

      await tester.pumpWidget(
        _wrap(
          const PublicProfileScreen(userId: _userId2),
          overrides: [friendsRepositoryProvider.overrideWithValue(friends)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Amigos'), findsOneWidget);

      await tester.tap(find.text('Amigos'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Amigos'), findsOneWidget);
      verifyNever(() => friends.sendFriendRequest(_userId2));
      verifyNever(() => friends.declineFriendRequest(_userId2));
    });
  });
}
