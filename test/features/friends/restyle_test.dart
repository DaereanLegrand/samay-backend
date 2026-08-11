import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/blocked_users_screen.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/profile/widgets/profile_avatar.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_button.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Friends-screens disco restyle ledger tests (U-10, Phase 4.4).
///
/// Pins the visual changes from DISCO-DESIGN-SYSTEM §5 applied screen-by-
/// screen (the ledger in `docs/development/phase-04-ui/2026-08-11_U10-
/// friends-restyle.md`): the cyan presence dot (`statusOnline`), the shared
/// `ProfileAvatar` in every tile with size-scaled initials, hairline
/// separators between name rows, theme-owned TabBar/TextButtons, the compact
/// outlined 'Agregar' action, and the completed VStateView empty/loading
/// states. Flow/text is byte-identical — the existing
/// friends_screens_test assertions stay untouched.

const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

Map<String, dynamic> _user(String id, String username) => {
  'id': id,
  'username': username,
  'avatar_url': null,
};

class _StubFriendsListNotifier extends FriendsListNotifier {
  final List<Map<String, dynamic>> data;
  _StubFriendsListNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

class _PendingFriendsListNotifier extends FriendsListNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() =>
      Completer<List<Map<String, dynamic>>>().future;
}

class _StubFriendRequestsNotifier extends FriendRequestsNotifier {
  final FriendRequestsData data;
  _StubFriendRequestsNotifier({
    this.data = const FriendRequestsData(requests: [], names: {}),
  });

  @override
  Future<FriendRequestsData> build() async => data;
}

class _PendingFriendRequestsNotifier extends FriendRequestsNotifier {
  @override
  Future<FriendRequestsData> build() => Completer<FriendRequestsData>().future;
}

class _StubGroupInvitesNotifier extends GroupInvitesNotifier {
  final List<Map<String, dynamic>> data;
  _StubGroupInvitesNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

class _StubBlockedUsersNotifier extends BlockedUsersNotifier {
  final List<Map<String, dynamic>> data;
  _StubBlockedUsersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

class _StubSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _StubSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _PendingSearchResultsNotifier extends SearchResultsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) =>
      Completer<List<Map<String, dynamic>>>().future;
}

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SamayTheme.dark,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

/// The first (nearest) [Divider] in the tree and the theme that paints it
/// (M3: `widget.color ?? dividerTheme.color` — U-09's MISTAKE lesson).
Divider _firstDivider(WidgetTester tester) =>
    tester.widget<Divider>(find.byType(Divider).first);

/// Resolved hairline color the [divider] renders with under the test theme.
Color? _dividerColor(WidgetTester tester, Divider divider) {
  final theme = Theme.of(tester.element(find.byType(Divider).first));
  return divider.color ?? theme.dividerTheme.color;
}

/// The compact outlined [VButton] inside a [ListTile] trailing.
VButton _tileActionButton(WidgetTester tester) =>
    tester.widget<VButton>(find.byType(VButton));

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('FriendsListScreen (§5.5 presence dot + §5 avatar tiles)', () {
    testWidgets('renders ProfileAvatar tiles with size-scaled initials', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(
              () => _StubFriendsListNotifier(
                data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      final initialA = tester.widget<Text>(
        find.descendant(
          of: find.byType(ProfileAvatar).first,
          matching: find.text('A'),
        ),
      );
      expect(
        initialA.style?.fontSize,
        AppSpacing.avatar * 0.25,
        reason: 'initials scale with the tile avatar (40 → 10px)',
      );

      final ring = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(ProfileAvatar).first,
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = ring.decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, AppColors.surfaceAlt);
    });

    testWidgets('presence dot is the statusOnline (cyan) 8px token', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(
              () => _StubFriendsListNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final dot = tester.widget<Icon>(find.byIcon(Icons.circle));
      expect(
        dot.color,
        AppColors.statusOnline,
        reason: 'green presence dot → the statusOnline (discoCyan) alias',
      );
      expect(dot.size, 8, reason: '§5.5: online dot = 8px circle');
    });

    testWidgets('name rows are separated by hairline dividers', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(
              () => _StubFriendsListNotifier(
                data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(Divider),
        findsOneWidget,
        reason: 'separated list: N-1 hairlines between 2 tiles',
      );
      expect(_dividerColor(tester, _firstDivider(tester)), AppColors.hairline);
    });

    testWidgets('shows VLoadingView while the provider is pending', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(_PendingFriendsListNotifier.new),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(VLoadingView), findsOneWidget);
    });

    testWidgets('shows VEmptyView when there are no friends', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(_StubFriendsListNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin amigos aún'), findsOneWidget);
    });

    testWidgets('shows VEmptyView when the filter matches nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(
              () => _StubFriendsListNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('No hay resultados'), findsOneWidget);
    });

    testWidgets('the @username handle renders once — the subtitle no longer '
        'duplicates the title (U-24)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FriendsListScreen(),
          overrides: [
            friendsListProvider.overrideWith(
              () => _StubFriendsListNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('@ana'),
        findsOneWidget,
        reason:
            'U-16\'s flagged double render — title AND subtitle were '
            'both @username; the subtitle is gone (name-only row)',
      );
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.text('@ana')),
        findsOneWidget,
        reason: 'the handle survives exactly once, in the tile title',
      );
    });
  });

  group('SearchScreen (§5.1 compact action + §5 avatar tiles)', () {
    testWidgets('result tiles render ProfileAvatar initials', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(ProfileAvatar).first,
          matching: find.text('A'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      "'Agregar' is a compact VButton.outlined in the tile trailing",
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const SearchScreen(),
            overrides: [
              searchResultsProvider.overrideWith(
                () => _StubSearchResultsNotifier(
                  data: [
                    _user(_userId1, 'ana'),
                    {
                      ..._user(_userId2, 'lucas'),
                      'friendship_status': 'pending',
                    },
                  ],
                ),
              ),
            ],
          ),
        );
        await tester.enterText(find.byType(TextField), 'an');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();

        final button = _tileActionButton(tester);
        expect(button.variant, VButtonVariant.outlined);
        expect(find.text('Agregar'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.byType(VButton),
          ),
          findsOneWidget,
          reason: 'the action stays inside the result tile trailing',
        );
        final wrapper = tester.widget<SizedBox>(
          find
              .ancestor(
                of: find.byType(VButton),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        expect(
          wrapper.width,
          104,
          reason: 'compact — VButton is full-width by §5.1',
        );

        expect(
          find.text('Solicitado'),
          findsOneWidget,
          reason: 'status labels stay theme TextButtons (muted when disabled)',
        );
      },
    );

    testWidgets('results list uses hairline separators', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(Divider), findsOneWidget);
      expect(_dividerColor(tester, _firstDivider(tester)), AppColors.hairline);
    });

    testWidgets('shows VLoadingView while the search is pending', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              _PendingSearchResultsNotifier.new,
            ),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.byType(VLoadingView), findsOneWidget);
    });

    testWidgets('shows VEmptyView when no users match', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(_StubSearchResultsNotifier.new),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('No se encontraron usuarios'), findsOneWidget);
    });
  });

  group('RequestsScreen (U-04 TabBar/TextButton theme + §5.9 empties)', () {
    List<Override> requestsOverrides({FriendRequestsData? data}) => [
      friendRequestsProvider.overrideWith(
        () => _StubFriendRequestsNotifier(
          data: data ?? const FriendRequestsData(requests: [], names: {}),
        ),
      ),
      groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
    ];

    testWidgets('the 3 tabs are theme-owned (white indicator + label)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const RequestsScreen(), overrides: requestsOverrides()),
      );
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.byType(TabBar)));
      expect(theme.tabBarTheme.indicatorColor, AppColors.white);
      expect(theme.tabBarTheme.labelColor, AppColors.white);
      expect(find.text('Recibidas'), findsOneWidget);
      expect(find.text('Enviadas'), findsOneWidget);
      expect(find.text('Invitaciones'), findsOneWidget);
    });

    testWidgets('accept/decline are theme TextButtons and rows are hairline '
        'separated', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: requestsOverrides(
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
              ],
              names: {_userId1: 'ana', _userId2: 'lucas'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Aceptar'), findsNWidgets(2));
      expect(find.text('Rechazar'), findsNWidgets(2));
      final theme = Theme.of(tester.element(find.text('Aceptar').first));
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'actions render via the U-04 textButtonTheme',
      );

      expect(
        find.byType(Divider),
        findsOneWidget,
        reason: '2 received rows → 1 hairline separator',
      );
      expect(_dividerColor(tester, _firstDivider(tester)), AppColors.hairline);
    });

    testWidgets('empty tabs render VEmptyView', (tester) async {
      await tester.pumpWidget(
        _wrap(const RequestsScreen(), overrides: requestsOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin solicitudes recibidas'), findsOneWidget);

      await tester.tap(find.text('Enviadas'));
      await tester.pumpAndSettle();
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin solicitudes enviadas'), findsOneWidget);

      await tester.tap(find.text('Invitaciones'));
      await tester.pumpAndSettle();
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin invitaciones'), findsOneWidget);
    });

    testWidgets('shows VLoadingView while the requests provider is pending', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: [
            friendRequestsProvider.overrideWith(
              _PendingFriendRequestsNotifier.new,
            ),
            groupInvitesProvider.overrideWith(_StubGroupInvitesNotifier.new),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(VLoadingView), findsOneWidget);
    });
  });

  group('BlockedUsersScreen (VStateView + §5 avatar tiles)', () {
    testWidgets('renders ProfileAvatar tiles with hairline separators and a '
        'theme TextButton unblock action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const BlockedUsersScreen(),
          overrides: [
            blockedUsersProvider.overrideWith(
              () => _StubBlockedUsersNotifier(
                data: [_user(_userId1, 'ana'), _user(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('Desbloquear'), findsNWidgets(2));
      final theme = Theme.of(tester.element(find.text('Desbloquear').first));
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'unblock renders via the U-04 textButtonTheme',
      );
      expect(find.byType(Divider), findsOneWidget);
      expect(_dividerColor(tester, _firstDivider(tester)), AppColors.hairline);
    });

    testWidgets('empty state renders through VStateView + VEmptyView', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const BlockedUsersScreen(),
          overrides: [
            blockedUsersProvider.overrideWith(_StubBlockedUsersNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VStateView), findsOneWidget);
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);
    });

    testWidgets('the @username handle renders once in blocked rows (U-24)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const BlockedUsersScreen(),
          overrides: [
            blockedUsersProvider.overrideWith(
              () => _StubBlockedUsersNotifier(data: [_user(_userId1, 'ana')]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('@ana'),
        findsOneWidget,
        reason:
            'U-16\'s flagged double render hit the blocked rows too — '
            'the duplicate subtitle is gone',
      );
    });
  });
}
