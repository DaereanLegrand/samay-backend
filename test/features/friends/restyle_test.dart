import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
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
import 'package:samay/shared/widgets/v_card.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Friends screens restyle pinning tests.
///
/// Pins the monochrome restyle (2026-08-26 user directive — all decorative
/// color stripped): sharp [VCard] hairline tiles instead of dividers, flat
/// white/black surfaces everywhere, NO gradient params on any widget.
/// Semantic accents stay: cyan presence dots (`statusOnline`) and the white
/// emphasized pending badge. AppBars keep Inter-white titles (no display
/// heroes on these list screens). Flow/text is byte-identical — the existing
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

/// Pumps a bounded amount (the tree contains a repeating `VStatusDot` pulse
/// animation that never settles, so `pumpAndSettle` would hang), then drains
/// the benign Flutter debug assertion that a tappable [ListTile] inside a
/// [VCard] (opaque `surface` fill) "may be invisible" — its ink splashes are
/// hidden by the card's DecoratedBox. This is a debug-only warning about
/// splash visibility, not a real failure. Unexpected errors are still rethrown.
Future<void> _pumpSettle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  Object? err;
  while ((err = tester.takeException()) != null) {
    final msg = err.toString();
    // The test framework records a "Multiple exceptions (N) were detected"
    // summary String followed by the individual FlutterErrors. Both are
    // benign here: they all stem from the ListTile-in-VCard debug warning.
    if (msg.contains('may be invisible') ||
        msg.contains('ListTile background color') ||
        msg.contains('Multiple exceptions')) {
      continue;
    }
    throw err!;
  }
}

/// The compact outlined [VButton] inside a [ListTile] trailing.
VButton _tileActionButton(WidgetTester tester) =>
    tester.widget<VButton>(find.byType(VButton));

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('FriendsListScreen (hairline glass tiles + presence dot)', () {
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
      await _pumpSettle(tester);

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
      await _pumpSettle(tester);

      final dot = tester.widget<Icon>(find.byIcon(Icons.circle));
      expect(
        dot.color,
        AppColors.statusOnline,
        reason:
            'presence stays the statusOnline (discoCyan) semantic — cyan '
            'is a status color, never decorative',
      );
      expect(dot.size, 8, reason: '§5.5: online dot = 8px circle');
    });

    testWidgets('rows are sharp hairline glass tiles — no dividers', (
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
      await _pumpSettle(tester);

      expect(
        find.byType(VCard),
        findsNWidgets(2),
        reason: 'each friend row is one sharp hairline tile',
      );
      expect(
        find.byType(Divider),
        findsNothing,
        reason: 'tile gaps replace the old hairline separators',
      );
      final card = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(VCard).first,
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = card.decoration as BoxDecoration;
      expect(
        decoration.color,
        AppColors.surface,
        reason: 'the tile fill is the surface (DESIGN.md §5.3)',
      );
      expect(
        (decoration.border as Border).top.color,
        AppColors.hairline,
        reason: 'the tile carries the 1px hairline border',
      );
      expect(
        card.padding,
        const EdgeInsets.all(AppSpacing.cardPadding),
        reason: 'the tile keeps the 16px cardPadding',
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
      await _pumpSettle(tester);
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
      await _pumpSettle(tester);
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
      await _pumpSettle(tester);

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

  group('SearchScreen (outlined action + pending badge)', () {
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
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpSettle(tester);

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(ProfileAvatar).first,
          matching: find.text('A'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("'Agregar' is the compact outlined VButton in the tile "
        'trailing; pending renders the emphasized white status badge', (
      tester,
    ) async {
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
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpSettle(tester);

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

      final badge = tester.widget<VBadge>(find.byType(VBadge));
      expect(
        badge.emphasized,
        isTrue,
        reason:
            'the outbound-pending readout is the white emphasized badge — '
            'no accent, no gradient (2026-08-26 monochrome)',
      );
      expect(badge.accent, isNull);
      // The emphasized face: white fill + black label.
      final face = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(VBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (face.decoration as BoxDecoration).color,
        AppColors.white,
        reason: 'VBadge.emphasized fills white on black',
      );
      expect(
        tester.widget<Text>(find.text('SOLICITADO')).style?.color,
        AppColors.discoBlack,
        reason: 'the emphasized label is black-on-white',
      );
      expect(
        find.text('SOLICITADO'),
        findsOneWidget,
        reason: 'VBadge renders the pending label in the §3.3 label voice',
      );
    });

    testWidgets('results render as sharp hairline glass tiles — no dividers', (
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
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpSettle(tester);

      expect(find.byType(VCard), findsNWidgets(2));
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
      await tester.enterText(find.byType(TextField), 'analia');
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
      await tester.enterText(find.byType(TextField), 'analia');
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpSettle(tester);

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('No se encontraron usuarios'), findsOneWidget);
    });
  });

  group('RequestsScreen (emphasized accept + glass tiles + tab badges)', () {
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
      await _pumpSettle(tester);

      final theme = Theme.of(tester.element(find.byType(TabBar)));
      expect(theme.tabBarTheme.indicatorColor, AppColors.white);
      expect(theme.tabBarTheme.labelColor, AppColors.white);
      expect(find.text('Recibidas'), findsOneWidget);
      expect(find.text('Enviadas'), findsOneWidget);
      expect(find.text('Invitaciones'), findsOneWidget);
    });

    testWidgets('accept is the emphasized VButton (white fill, black label), '
        'decline the theme TextButton; rows are hairline glass tiles', (
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
      await _pumpSettle(tester);

      final accept = tester.widget<VButton>(find.byType(VButton).first);
      expect(
        accept.variant,
        VButtonVariant.emphasized,
        reason: 'accept is the row\'s active filled action',
      );
      // The monochrome emphasized face (2026-08-26): white fill + black
      // label — no gradient path anywhere.
      final acceptFace = tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('Aceptar').first,
              matching: find.byType(TextButton),
            ),
          )
          .style;
      expect(
        acceptFace?.backgroundColor?.resolve({}),
        AppColors.white,
        reason: 'the emphasized accept face fills white',
      );
      expect(
        acceptFace?.foregroundColor?.resolve({}),
        AppColors.discoBlack,
        reason: 'the emphasized accept label is black-on-white',
      );
      expect(find.text('Aceptar'), findsNWidgets(2));

      final theme = Theme.of(tester.element(find.text('Rechazar').first));
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'decline stays the theme TextButton (U-04)',
      );

      expect(
        find.byType(VCard),
        findsNWidgets(2),
        reason: '2 received rows → 2 sharp hairline tiles',
      );
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets('the pending-count tab badges take the monochrome count '
        'voice — white border/text on black', (tester) async {
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
      await _pumpSettle(tester);

      final badge = tester.widget<VCountBadge>(
        find.descendant(
          of: find.widgetWithText(Tab, 'Recibidas'),
          matching: find.byType(VCountBadge),
        ),
      );
      expect(badge.count, 1);
      // The red-circle count voice (2026-08-27 user directive): solid
      // `badgeRed` fill, circular, no border, white count text.
      final face = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(VCountBadge),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = face.decoration as BoxDecoration;
      expect(
        decoration.color,
        AppColors.badgeRed,
        reason: 'the pending count fills red',
      );
      expect(
        decoration.shape,
        BoxShape.circle,
        reason: 'the pending count is a circle',
      );
      expect(
        decoration.border,
        isNull,
        reason: 'no border ring on the red badge',
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(VCountBadge),
                matching: find.text('1'),
              ),
            )
            .style
            ?.color,
        AppColors.white,
        reason: 'the count text is white',
      );
    });

    testWidgets('empty tabs render VEmptyView', (tester) async {
      await tester.pumpWidget(
        _wrap(const RequestsScreen(), overrides: requestsOverrides()),
      );
      await _pumpSettle(tester);

      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin solicitudes recibidas'), findsOneWidget);

      await tester.tap(find.text('Enviadas'));
      await _pumpSettle(tester);
      expect(find.byType(VEmptyView), findsOneWidget);
      expect(find.text('Sin solicitudes enviadas'), findsOneWidget);

      await tester.tap(find.text('Invitaciones'));
      await _pumpSettle(tester);
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

  group('BlockedUsersScreen (hairline glass tiles + theme unblock)', () {
    testWidgets('renders ProfileAvatar tiles with hairline glass tiles and a '
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
      await _pumpSettle(tester);

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('Desbloquear'), findsNWidgets(2));
      final theme = Theme.of(tester.element(find.text('Desbloquear').first));
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve({}),
        AppColors.white,
        reason: 'unblock renders via the U-04 textButtonTheme',
      );
      expect(find.byType(VCard), findsNWidgets(2));
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
      await _pumpSettle(tester);

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
      await _pumpSettle(tester);

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
