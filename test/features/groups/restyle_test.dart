import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/core/repositories/groups_repository.dart';
import 'package:samay/core/repositories/repository_providers.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/groups/screens/create_group_screen.dart';
import 'package:samay/features/groups/screens/donate_shards_screen.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/screens/group_members_screen.dart';
import 'package:samay/features/groups/screens/invite_screen.dart';
import 'package:samay/features/groups/screens/leaderboard_screen.dart';
import 'package:samay/features/groups/screens/my_groups_screen.dart';
import 'package:samay/features/profile/widgets/profile_avatar.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/rank_badge.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_chip.dart';
import 'package:samay/shared/widgets/v_shard_icon.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Groups-screens disco restyle ledger tests (U-11, Phase 4.4).
///
/// Pins the visual changes from DISCO-DESIGN-SYSTEM §5 applied screen-by-
/// screen (the ledger in `docs/development/phase-04-ui/2026-08-11_U11-
/// groups-restyle.md`): the §5.5 RankBadge podium (gold/silver/bronze for
/// the top-3 leaderboard rows), the §3.2 Playfair `headlineLarge` group-hero
/// name, the §5.1 glowAccent CTAs (create group, donate, detail donate),
/// the §5.6 gold shard icons, the hairline rows (my-groups list, members
/// tab, invite results, members screen) and the §5.2/§5.9 token treatments
/// (cover picker, search field, frozen banner). Flow/text is byte-identical
/// — the existing groups_screens_test assertions stay untouched except the
/// single `PROMOTOR · ` → `VBadge` row-text update (deliberate, ledger).

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

class _StubMyGroupsNotifier extends MyGroupsNotifier {
  final List<Map<String, dynamic>> data;
  _StubMyGroupsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

class _StubGroupDetailNotifier extends GroupDetailNotifier {
  final Map<String, dynamic>? data;
  _StubGroupDetailNotifier({this.data});

  @override
  Future<Map<String, dynamic>?> build(String arg) async => data;
}

class _StubGroupMembersNotifier extends GroupMembersNotifier {
  final List<Map<String, dynamic>> data;
  _StubGroupMembersNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _StubContributionsNotifier extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      const GroupContributionsData(contributors: [], myContribution: 0);
}

class _StubLeaderboardNotifier extends LeaderboardNotifier {
  final List<Map<String, dynamic>> data;
  _StubLeaderboardNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _StubSearchResultsNotifier extends SearchResultsNotifier {
  final List<Map<String, dynamic>> data;
  _StubSearchResultsNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => data;
}

class _MockGroupsRepository extends Mock implements GroupsRepository {}

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

/// The [VButton] whose label is [label] (buttons render their label as a
/// Text child, so the ancestor-of-text scope isolates it from siblings).
VButton _buttonWithLabel(WidgetTester tester, String label) =>
    tester.widget<VButton>(
      find.ancestor(of: find.text(label), matching: find.byType(VButton)),
    );

/// The first (nearest) [Divider] in the tree and the theme that paints it
/// (M3: `widget.color ?? dividerTheme.color` — U-09's MISTAKE lesson).
Color? _dividerColor(WidgetTester tester) {
  final divider = find.byType(Divider).first;
  final theme = Theme.of(tester.element(divider));
  return theme.dividerTheme.color;
}

/// The glow-soft stack the theme bakes into `headlineLarge` (U-02).
List<Shadow> get _playfairGlow => AppTypography.fancyTitle(
      AppTypography.headlineLarge,
      soft: true,
    ).shadows!;

/// The [RankBadge] inside the leaderboard row whose title is [name].
RankBadge _rowBadge(WidgetTester tester, String name) {
  final badge = find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
    matching: find.byType(RankBadge),
  );
  return tester.widget<RankBadge>(badge);
}

/// The border color the [RankBadge] of row [name] renders (the §5.5 podium
/// accent is on the badge's inner Container border + label).
Color _badgeBorderColor(WidgetTester tester, String name) {
  final badge = find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
    matching: find.byType(RankBadge),
  );
  final container = tester.widget<Container>(
    find.descendant(of: badge, matching: find.byType(Container)).first,
  );
  return ((container.decoration as BoxDecoration).border as Border).top.color;
}

List<Override> _detailOverrides({
  Map<String, dynamic>? group,
  List<Map<String, dynamic>> members = const [],
}) => [
      groupDetailProvider.overrideWith(
        () => _StubGroupDetailNotifier(
          data:
              group ??
              {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
        ),
      ),
      groupMembersProvider.overrideWith(
        () => _StubGroupMembersNotifier(data: members),
      ),
      contributionsProvider.overrideWith(_StubContributionsNotifier.new),
    ];

void main() {
  setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

  group('MyGroupsScreen (§5.5/§5.6/§5 avatar tiles — U-11 ledger)', () {
    Widget pumpMyGroups() => _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(
              () => _StubMyGroupsNotifier(
                data: [
                  _group(_groupId, 'Disco Crew', myRole: 'promotor'),
                  _group(
                    '44444444-4444-4444-4444-444444444444',
                    'Vinyl Lovers',
                    myRole: 'member',
                  ),
                ],
              ),
            ),
          ],
        );

    testWidgets('tiles render ProfileAvatar, gold shard icons, VBadge role '
        'and RankBadge', (tester) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2),
          reason: 'cover/initials render through the shared avatar widget');
      final shards = tester.widgetList<VShardIcon>(find.byType(VShardIcon));
      expect(shards.length, 2);
      for (final shard in shards) {
        expect(shard.color, AppColors.currencyShards,
            reason: '§5.6 — the diamond is gold (13.71:1)');
        expect(shard.size, AppIconSizes.xs,
            reason: '§5.6 — inline list-subtitle size xs 12');
      }
      expect(find.text('PROMOTOR'), findsOneWidget,
          reason: 'the role renders as a §5.5 VBadge (uppercase labelSmall)');
      expect(find.byType(RankBadge), findsNWidgets(2),
          reason: 'the rank bracket badge survives in every tile');
    });

    testWidgets('group names render bodyLarge white (§5 list voice)',
        (tester) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      final name = tester.widget<Text>(find.text('Disco Crew'));
      expect(name.style?.fontSize, AppTypography.bodyLarge.fontSize);
      expect(name.style?.color, AppColors.white);
    });

    testWidgets('tiles are hairline separated', (tester) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      // Scoped to the list: the screen also carries a pre-existing section
      // Divider above the list (unchanged) — the separated-list separators
      // live inside the ListView only.
      final listDivider = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Divider),
      );
      expect(listDivider, findsOneWidget,
          reason: '2 tiles → 1 hairline separator between them');
      expect(_dividerColor(tester), AppColors.hairline,
          reason: 'dividers resolve the U-04 dividerTheme (hairline)');
    });

    testWidgets('Crear grupo/Ranking are §5.1 outlined VButtons and the '
        'Amigos/Solicitudes entries are TextButtons', (tester) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      expect(_buttonWithLabel(tester, 'Crear grupo').variant,
          VButtonVariant.outlined);
      expect(_buttonWithLabel(tester, 'Ranking').variant,
          VButtonVariant.outlined);
      expect(find.widgetWithText(TextButton, 'Amigos'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Solicitudes'), findsOneWidget);
    });
  });

  group('GroupDetailScreen hero (§3.2/§5.5/§5.6/§5.1 — U-11 ledger)', () {
    testWidgets('hero name renders Playfair headlineLarge with glow-soft',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const GroupDetailScreen(groupId: _groupId),
        overrides: _detailOverrides(),
      ));
      await tester.pumpAndSettle();

      final name = tester.widget<Text>(find.text('Disco Crew'));
      expect(name.style?.fontFamily, AppTypography.playfair,
          reason: '§3.2 — group names on the detail hero are Playfair');
      expect(name.style?.fontStyle, FontStyle.italic);
      expect(name.style?.fontSize, 28);
      expect(name.style?.shadows, _playfairGlow,
          reason: 'the theme role bakes the glow-soft stack (U-02)');
    });

    testWidgets('size tier renders a VBadge, the rank a RankBadge and the '
        'shards a gold icon', (tester) async {
      await tester.pumpWidget(_wrap(
        const GroupDetailScreen(groupId: _groupId),
        overrides: _detailOverrides(
          group: {
            'id': _groupId,
            'name': 'Disco Crew',
            'group_shards': 100,
            'size_tier': 'micro',
            'rank_bracket': 'b0_20',
          },
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('MICRO'), findsOneWidget,
          reason: 'the size badge is a §5.5 VBadge (uppercase labelSmall)');
      expect(find.byType(VBadge), findsOneWidget);
      expect(find.byType(RankBadge), findsOneWidget);
      final shard = tester.widget<VShardIcon>(find.byType(VShardIcon));
      expect(shard.color, AppColors.currencyShards);
      expect(shard.size, AppIconSizes.sm, reason: '§5.6 default 16');
    });

    testWidgets('Donar is the glowAccent filled primary; Crear evento and '
        'Invitar stay outlined', (tester) async {
      await tester.pumpWidget(_wrap(
        const GroupDetailScreen(groupId: _groupId),
        overrides: _detailOverrides(),
      ));
      await tester.pumpAndSettle();

      final donate = _buttonWithLabel(tester, 'Donar shards');
      expect(donate.variant, VButtonVariant.glow,
          reason: '§5.1 — the primary detail action is the glow accent');
      expect(donate.filled, isTrue);
      expect(_buttonWithLabel(tester, 'Crear evento').variant,
          VButtonVariant.outlined);
      expect(_buttonWithLabel(tester, 'Invitar').variant,
          VButtonVariant.outlined);
    });

    testWidgets('members tab renders ProfileAvatar + VBadge role + hairline '
        'rows', (tester) async {
      await tester.pumpWidget(_wrap(
        const GroupDetailScreen(groupId: _groupId),
        overrides: _detailOverrides(
          members: [
            {
              'user_id': _userId1,
              'role': 'promotor',
              'users': {'username': 'ana'},
            },
            {
              'user_id': _userId2,
              'role': 'member',
              'users': {'username': 'lucas'},
            },
          ],
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Miembros'));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('PROMOTOR'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
      // Scoped to the members list: the hero column also carries a
      // pre-existing section Divider above the TabBarView (unchanged).
      final rows = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Divider),
      );
      expect(rows, findsNWidgets(2),
          reason: 'each member/contributor row closes with a hairline');
      expect(_dividerColor(tester), AppColors.hairline);
    });

    testWidgets('frozen banner uses the errorFill (glowPinkDeep) treatment '
        'with white text', (tester) async {
      await tester.pumpWidget(_wrap(
        const GroupDetailScreen(groupId: _groupId),
        overrides: _detailOverrides(
          group: {
            'id': _groupId,
            'name': 'Disco Crew',
            'group_shards': 100,
            'frozen_at': '2026-01-01T00:00:00Z',
          },
        ),
      ));
      await tester.pumpAndSettle();

      final banner = find.textContaining('Grupo congelado');
      expect(banner, findsOneWidget);
      // The banner is a `Container(color: ...)` — its widget `decoration` is
      // null (Container folds `color:` into the effective decoration in
      // build); resolve the fill from `color` directly.
      final container = tester.widget<Container>(
        find.ancestor(of: banner, matching: find.byType(Container)).first,
      );
      expect(container.color, AppColors.errorFill,
          reason: '§5.2 — never raw red on black; white-on-glowPinkDeep is '
              '5.87:1 (AA)');
      final text = tester.widget<Text>(banner);
      expect(text.style?.color, AppColors.white);
    });
  });

  group('LeaderboardScreen (§5.5 podium + §3.2 — U-11 ledger)', () {
    List<Map<String, dynamic>> podium() => [
          {
            ..._group('11111111-1111-1111-1111-111111111111', 'Top Uno'),
            'rank_position': 1,
            'score': 500,
            'member_count': 12,
          },
          {
            ..._group('22222222-2222-2222-2222-222222222222', 'Top Dos'),
            'rank_position': 2,
            'score': 300,
            'member_count': 8,
          },
          {
            ..._group('33333333-3333-3333-3333-333333333333', 'Top Tres'),
            'rank_position': 3,
            'score': 150,
            'member_count': 5,
          },
          {
            ..._group('44444444-4444-4444-4444-444444444444', 'Cuarto'),
            'rank_position': 4,
            'score': 50,
            'member_count': 3,
          },
        ];

    Widget pumpLeaderboard() => _wrap(
          const LeaderboardScreen(),
          overrides: [
            leaderboardProvider.overrideWith(
              () => _StubLeaderboardNotifier(data: podium()),
            ),
          ],
        );

    testWidgets('podium rows 1-3 use RankBadge rank gold/silver/bronze; the '
        'rest stay neutral', (tester) async {
      await tester.pumpWidget(pumpLeaderboard());
      await tester.pumpAndSettle();

      final gold = _rowBadge(tester, 'Top Uno');
      expect(gold.rank, 1);
      expect(_badgeBorderColor(tester, 'Top Uno'), AppColors.discoGold);

      final silver = _rowBadge(tester, 'Top Dos');
      expect(silver.rank, 2);
      expect(_badgeBorderColor(tester, 'Top Dos'), AppColors.discoSilver);

      final bronze = _rowBadge(tester, 'Top Tres');
      expect(bronze.rank, 3);
      expect(_badgeBorderColor(tester, 'Top Tres'), AppColors.discoBronze);

      expect(_rowBadge(tester, 'Cuarto').rank, isNull,
          reason: 'non-top rows keep the §5.5 neutral white badge');
    });

    testWidgets('top-3 names render Playfair headlineLarge with glow-soft; '
        'the rest stay Inter', (tester) async {
      await tester.pumpWidget(pumpLeaderboard());
      await tester.pumpAndSettle();

      for (final name in ['Top Uno', 'Top Dos', 'Top Tres']) {
        final text = tester.widget<Text>(find.text(name));
        expect(text.style?.fontFamily, AppTypography.playfair,
            reason: '§3.2 — podium names are Playfair 28');
        expect(text.style?.fontSize, 28);
        expect(text.style?.shadows, _playfairGlow);
      }

      final rest = tester.widget<Text>(find.text('Cuarto'));
      expect(rest.style?.fontFamily, isNot(AppTypography.playfair),
          reason: 'the fancy treatment is for the podium only');
    });

    testWidgets('tier chips are VChips (verify-only)', (tester) async {
      await tester.pumpWidget(pumpLeaderboard());
      await tester.pumpAndSettle();

      expect(find.byType(VChip), findsNWidgets(4));
      for (final tier in ['micro', 'small', 'medium', 'large']) {
        expect(find.text(tier), findsOneWidget);
      }
    });
  });

  group('CreateGroupScreen (§5.2/§5.1 — U-11 ledger)', () {
    testWidgets('cover picker renders surfaceAlt + border + camera '
        'affordance', (tester) async {
      await tester.pumpWidget(_wrap(const CreateGroupScreen()));
      await tester.pumpAndSettle();

      final picker = tester.widget<Container>(
        find.ancestor(
          of: find.byIcon(Icons.camera_alt),
          matching: find.byType(Container),
        ).first,
      );
      final decoration = picker.decoration as BoxDecoration;
      expect(decoration.color, AppColors.surfaceAlt,
          reason: '§5.8 skeleton-base surface for the empty cover slot');
      expect(decoration.border, Border.all(color: AppColors.border),
          reason: 'the §2.1 interactive-outline token');
      final icon = tester.widget<Icon>(find.byIcon(Icons.camera_alt));
      expect(icon.color, AppColors.muted,
          reason: 'muted #666666 passes the 3:1 non-text rule as an icon');
      final label = tester.widget<Text>(find.text('Agregar foto de portada'));
      expect(label.style?.color, AppColors.mutedStrong,
          reason: 'informational text must be AA (muted fails §2.4)');
    });

    testWidgets('the create CTA uses glowAccent filled (§5.1 canonical '
        'primary)', (tester) async {
      await tester.pumpWidget(_wrap(const CreateGroupScreen()));
      await tester.pumpAndSettle();

      final create = _buttonWithLabel(tester, 'Crear');
      expect(create.variant, VButtonVariant.glow);
      expect(create.filled, isTrue);
    });
  });

  group('DonateShardsScreen (§5.2/§5.1 — U-11 ledger)', () {
    testWidgets('amount VInput keeps the token label treatment and the '
        'donate CTA is glowAccent filled', (tester) async {
      await tester.pumpWidget(_wrap(
        const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
      ));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.labelStyle?.color, AppColors.mutedStrong,
          reason: 'the U-05 VInput label token (AA — the §5.2 shard-amount '
              'seam)');
      final donate = _buttonWithLabel(tester, 'Donar');
      expect(donate.variant, VButtonVariant.glow,
          reason: '§5.1 — donating shards is the screen\'s primary action');
      expect(donate.filled, isTrue);
    });
  });

  group('InviteScreen (§5.2/§5 avatar tiles + hairline — U-11 ledger)', () {
    Widget pumpInvite() => _wrap(
          const InviteScreen(groupId: _groupId),
          overrides: [
            groupMembersProvider.overrideWith(_StubGroupMembersNotifier.new),
            searchResultsProvider.overrideWith(
              () => _StubSearchResultsNotifier(
                data: [
                  {'id': _userId1, 'username': 'ana', 'avatar_url': null},
                  {'id': _userId2, 'username': 'lucas', 'avatar_url': null},
                ],
              ),
            ),
          ],
        );

    testWidgets('search field is theme-owned (no OutlineInputBorder)',
        (tester) async {
      await tester.pumpWidget(pumpInvite());
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.border, isNull,
          reason: 'the raw OutlineInputBorder is gone — the U-04 '
              'inputDecorationTheme underline owns the field');
    });

    testWidgets('result rows render ProfileAvatar with hairline separators '
        'and keep the checkbox', (tester) async {
      await tester.pumpWidget(pumpInvite());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('@lucas'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(2),
          reason: 'the selection checkbox survives (U-04 sharp theme)');
      expect(find.byType(Divider), findsOneWidget,
          reason: '2 results → 1 hairline separator');
      expect(_dividerColor(tester), AppColors.hairline);
    });
  });

  group('GroupMembersScreen (§5 avatar tiles + role badges — U-11 ledger)',
      () {
    testWidgets('rows render ProfileAvatar + VBadge roles with hairline '
        'separators', (tester) async {
      final repo = _MockGroupsRepository();
      when(() => repo.getGroupMembers(_groupId)).thenAnswer(
        (_) async => [
          GroupMember.fromJson({
            'id': 'm1',
            'group_id': _groupId,
            'user_id': _userId1,
            'role': 'promotor',
            'joined_at': '2026-01-01T00:00:00Z',
            'users': {'username': 'ana'},
          }),
          GroupMember.fromJson({
            'id': 'm2',
            'group_id': _groupId,
            'user_id': _userId2,
            'role': 'member',
            'joined_at': '2026-01-01T00:00:00Z',
            'users': {'username': 'lucas'},
          }),
        ],
      );

      await tester.pumpWidget(_wrap(
        const GroupMembersScreen(groupId: _groupId),
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('PROMOTOR'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget,
          reason: '2 rows → 1 hairline separator');
      expect(_dividerColor(tester), AppColors.hairline);
    });
  });
}
