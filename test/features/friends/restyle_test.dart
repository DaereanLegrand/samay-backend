import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_spacing.dart';
import 'package:samay/core/models/friend_request_summary.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/models/user_search_result.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/friends/screens/blocked_users_screen.dart';
import 'package:samay/features/friends/screens/friends_list_screen.dart';
import 'package:samay/features/friends/screens/requests_screen.dart';
import 'package:samay/features/friends/screens/search_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/shared/widgets/profile_avatar.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/glass/glass.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Friends screens LUXE v2 restyle ledger tests (XL-09, phase-04-luxe).
///
/// Pins the ORCHESTRATION-LUXE restyle applied screen-by-screen (the ledger
/// in `docs/history/phase-04-luxe/2026-08-12_XL-09-friends.md`): mint
/// family everywhere (NO PINK MAINS),
/// sharp [VGlassCard] hairline tiles instead of dividers, mint accents ONLY
/// on active elements (accept buttons, pending badges), cyan presence dots
/// stay semantic, AppBars keep Inter-white titles (no display heroes on
/// these list screens). Flow/text is byte-identical — the existing
/// friends_screens_test + flow_test assertions stay untouched.

const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

UserProfile _user(String id, String username) => UserProfile(
  id: id,
  username: username,
  avatarUrl: null,
);

UserSearchResult _searchResult(String id, String username) => UserSearchResult(
  id: id,
  username: username,
);

class _StubFriendsListNotifier extends FriendsListNotifier {
  final List<UserProfile> data;
  _StubFriendsListNotifier({this.data = const []});

  @override
  Future<List<UserProfile>> build() async => data;
}

class _PendingFriendsListNotifier extends FriendsListNotifier {
  @override
  Future<List<UserProfile>> build() =>
      Completer<List<UserProfile>>().future;
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
  final List<UserProfile> data;
  _StubBlockedUsersNotifier({this.data = const []});

  @override
  Future<List<UserProfile>> build() async => data;
}

class _StubSearchResultsNotifier extends SearchResultsNotifier {
  final List<UserSearchResult> data;
  _StubSearchResultsNotifier({this.data = const []});

  @override
  Future<List<UserSearchResult>> build(String arg) async => data;
}

class _PendingSearchResultsNotifier extends SearchResultsNotifier {
  @override
  Future<List<UserSearchResult>> build(String arg) =>
      Completer<List<UserSearchResult>>().future;
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

/// The compact outlined [VButton] inside a [ListTile] trailing.
VButton _tileActionButton(WidgetTester tester) =>
    tester.widget<VButton>(find.byType(VButton));

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('FriendsListScreen (mint glass tiles + presence dot)', () {
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
        reason:
            'presence stays the statusOnline (discoCyan) semantic — cyan '
            'is a status color, not the mint screen accent',
      );
      expect(dot.size, 8, reason: '§5.5: online dot = 8px circle');
    });

    testWidgets('rows are sharp mint glass tiles — no hairline dividers', (
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

      expect(
        find.byType(VGlassCard),
        findsNWidgets(2),
        reason: 'each friend row is one sharp glass tile',
      );
      expect(
        find.byType(Divider),
        findsNothing,
        reason: 'tile gaps replace the old hairline separators',
      );
      final card = tester.widget<VGlassCard>(find.byType(VGlassCard).first);
      expect(
        card.gradient,
        AppGradients.mint,
        reason: 'the glass ring + glow take the mint family',
      );
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

  group('SearchScreen (mint compact action + pending badge)', () {
    testWidgets('result tiles render ProfileAvatar initials', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [_searchResult(_userId1, 'ana'), _searchResult(_userId2, 'lucas')],
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

    testWidgets("'Agregar' is the compact mint-outlined VButton in the tile "
        'trailing; pending renders the mint status badge', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [
                  _searchResult(_userId1, 'ana'),
                  const UserSearchResult(
                    id: _userId2,
                    username: 'lucas',
                    friendshipStatus: 'pending',
                  ),
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
      expect(
        button.gradient,
        AppGradients.mint,
        reason: 'the active add action takes the mint gradient ring',
      );
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

      final badge = tester.widget<VBadge>(find.byType(VBadge));
      expect(
        badge.gradient,
        AppGradients.mint,
        reason: 'the pending readout is the row\'s mint badge accent',
      );
      expect(
        find.text('SOLICITADO'),
        findsOneWidget,
        reason: 'VBadge renders the pending label in the §3.3 label voice',
      );
    });

    testWidgets('results render as sharp mint glass tiles — no dividers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const SearchScreen(),
          overrides: [
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [_searchResult(_userId1, 'ana'), _searchResult(_userId2, 'lucas')],
              ),
            ),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'an');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(VGlassCard), findsNWidgets(2));
      expect(find.byType(Divider), findsNothing);
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

  group('RequestsScreen (mint accept + glass tiles + tab badges)', () {
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

    testWidgets('accept is the mint VButton, decline the theme TextButton; '
        'rows are mint glass tiles', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: requestsOverrides(
            data: const FriendRequestsData(
              requests: [
                FriendRequestSummary(
                  type: 'received',
                  friendshipId: 'f1',
                  userId: _userId1,
                ),
                FriendRequestSummary(
                  type: 'received',
                  friendshipId: 'f2',
                  userId: _userId2,
                ),
              ],
              names: {_userId1: 'ana', _userId2: 'lucas'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final accept = tester.widget<VButton>(find.byType(VButton).first);
      expect(
        accept.variant,
        VButtonVariant.emphasized,
        reason: 'accept is the row\'s active filled action',
      );
      expect(
        accept.gradient,
        AppGradients.mint,
        reason: 'the mint accent lives on the accept face — never pink',
      );
      expect(find.text('Aceptar'), findsNWidgets(2));

      final theme = Theme.of(tester.element(find.text('Rechazar').first));
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'decline stays the theme TextButton (U-04)',
      );

      expect(
        find.byType(VGlassCard),
        findsNWidgets(2),
        reason: '2 received rows → 2 sharp glass tiles',
      );
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('the pending-count tab badges take the mint family', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const RequestsScreen(),
          overrides: requestsOverrides(
            data: const FriendRequestsData(
              requests: [
                FriendRequestSummary(
                  type: 'received',
                  friendshipId: 'f1',
                  userId: _userId1,
                ),
              ],
              names: {_userId1: 'ana'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final badge = tester.widget<VCountBadge>(
        find.descendant(
          of: find.widgetWithText(Tab, 'Recibidas'),
          matching: find.byType(VCountBadge),
        ),
      );
      expect(
        badge.gradient,
        AppGradients.mint,
        reason: 'pending counts are mint accents',
      );
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

  group('BlockedUsersScreen (mint glass tiles + theme unblock)', () {
    testWidgets('renders ProfileAvatar tiles with mint glass tiles and a '
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
      expect(find.byType(VGlassCard), findsNWidgets(2));
      expect(find.byType(Divider), findsNothing);
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
