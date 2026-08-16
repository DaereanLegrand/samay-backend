import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
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
import 'package:samay/shared/widgets/glass/v_gradient_border.dart';
import 'package:samay/shared/widgets/glass/v_glass.dart';
import 'package:samay/shared/widgets/rank_badge.dart';
import 'package:samay/shared/widgets/skeletons.dart';
import 'package:samay/shared/widgets/state_views.dart';
import 'package:samay/shared/widgets/v_aurora.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_chip.dart';
import 'package:samay/shared/widgets/v_display_text.dart';
import 'package:samay/shared/widgets/v_shard_icon.dart';

import '../../support/fake_supabase_http.dart' as support;

/// Groups-screens LUXE restyle ledger tests (XL-10, phase-04-luxe).
///
/// Pins the LUXE v2 violet-family restyle applied screen-by-screen (the
/// ledger in `docs/history/phase-04-luxe/2026-08-12_XL-10-groups.md`):
/// the violet `VAurora` backdrop, glass tiles (VGlassCard) everywhere rows
/// render, the group-name detail hero + leaderboard podium in violet
/// `VDisplayText` (Playfair MAYUS), the glowAccent CTAs carrying the violet
/// gradient, the violet ring on the invite search field, and the glass
/// member-actions sheet. The §5.5 podium gold/silver/bronze RankBadge
/// semantics and all hairline separators stay. Flow/text is byte-identical —
/// the existing groups_screens_test assertions stay untouched except the
/// uppercase hero names (deliberate, ledger).

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

/// Completer-gated group-detail variant — holds the provider pending so the
/// first-frame skeleton can be asserted (U-24, §5.8).
class _GatedGroupDetailNotifier extends GroupDetailNotifier {
  _GatedGroupDetailNotifier(this.gate);

  final Completer<Map<String, dynamic>?> gate;

  @override
  Future<Map<String, dynamic>?> build(String arg) => gate.future;
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

/// Pending search-results variant — pins the invite search-loading surface
/// (U-24: the §5.8 spinner replaced the Material linear bar).
class _PendingSearchResultsNotifier extends SearchResultsNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) =>
      Completer<List<Map<String, dynamic>>>().future;
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

/// The [VDisplayText] whose glyphs spell [text] (VDisplayText uppercases —
/// the MAYUS rule — so the finder targets the raw copy).
VDisplayText _display(WidgetTester tester, String text) {
  return tester.widget<VDisplayText>(
    find.ancestor(
      of: find.text(text.toUpperCase()),
      matching: find.byType(VDisplayText),
    ),
  );
}

/// The [Text] widget VDisplayText renders for [text] — the Playfair glyphs
/// the ShaderMask fills (color is white so the shader owns the fill).
Text _displayGlyphs(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text.toUpperCase()));

/// The [VGlassCard] nearest to [text] (the tile/card surface that owns the
/// row — the LUXE glass treatment).
VGlassCard _glassOf(WidgetTester tester, String text) {
  final card = find.ancestor(
    of: find.text(text),
    matching: find.byType(VGlassCard),
  );
  return tester.widget<VGlassCard>(card.first);
}

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
          group ?? {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100},
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

    testWidgets('tiles render ProfileAvatar, gold shard icons and the VBadge '
        'role on hairline rows (XL-17: no per-row glass, no rank badge)', (
      tester,
    ) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      expect(
        find.byType(VAurora),
        findsOneWidget,
        reason: 'the LUXE violet ambient aurora backs the screen',
      );
      expect(
        tester.widget<VAurora>(find.byType(VAurora)).gradients,
        const [AppGradients.violet],
        reason: 'the groups family is violet (NO PINK MAINS)',
      );
      expect(
        find.byType(ProfileAvatar),
        findsNWidgets(2),
        reason: 'cover/initials render through the shared avatar widget',
      );
      final shards = tester.widgetList<VShardIcon>(find.byType(VShardIcon));
      expect(shards.length, 2);
      for (final shard in shards) {
        expect(
          shard.color,
          AppColors.currencyShards,
          reason: '§5.6 — the diamond is gold (13.71:1)',
        );
        expect(
          shard.size,
          AppIconSizes.xs,
          reason: '§5.6 — inline list-subtitle size xs 12',
        );
      }
      expect(
        find.text('PROMOTOR'),
        findsOneWidget,
        reason: 'the role renders as a §5.5 VBadge (uppercase labelSmall)',
      );
      expect(
        find.byType(RankBadge),
        findsNothing,
        reason:
            'XL-17 (09_groups declutter) — the rank badge belongs to the '
            'leaderboard, not every group tile',
      );
      expect(
        find.byType(VGlassCard),
        findsNothing,
        reason:
            'XL-17 — one hairline per row: the tile glass card + glow are '
            'gone, the violet stays on the hero/primary CTA',
      );
    });

    testWidgets('group names render bodyLarge white (§5 list voice)', (
      tester,
    ) async {
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
      expect(
        listDivider,
        findsOneWidget,
        reason: '2 tiles → 1 hairline separator between them',
      );
      expect(
        _dividerColor(tester),
        AppColors.hairline,
        reason: 'dividers resolve the U-04 dividerTheme (hairline)',
      );
    });

    testWidgets('Crear grupo is the glowAccent filled primary (the screen\'s '
        'one violet accent); Ranking is a neutral outlined VButton; the '
        'Amigos/Solicitudes entries are TextButtons', (tester) async {
      await tester.pumpWidget(pumpMyGroups());
      await tester.pumpAndSettle();

      final create = _buttonWithLabel(tester, 'Crear grupo');
      expect(create.variant, VButtonVariant.glow);
      expect(
        create.filled,
        isTrue,
        reason:
            'XL-17 (09_groups: violet at 1 accent per screen) — the primary '
            'CTA owns the violet fill/glow',
      );
      expect(
        create.gradient,
        AppGradients.violet,
        reason: 'the primary CTA carries the violet family gradient',
      );
      final ranking = _buttonWithLabel(tester, 'Ranking');
      expect(ranking.variant, VButtonVariant.outlined);
      expect(
        ranking.gradient,
        isNull,
        reason:
            'XL-17 — the secondary entry drops to neutral white outline; '
            'two violet buttons side by side read as color spray',
      );
      expect(find.widgetWithText(TextButton, 'Amigos'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Solicitudes'), findsOneWidget);
    });

    testWidgets('a group row missing `my_role` renders without crashing '
        '(U-24 null-guard)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const MyGroupsScreen(),
          overrides: [
            myGroupsProvider.overrideWith(
              () => _StubMyGroupsNotifier(
                data: [
                  {
                    'id': _groupId,
                    'name': 'No Role Club',
                    'group_shards': 7,
                    'rank_bracket': null,
                  },
                ],
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'U-24: a row without `my_role` must not crash the tile '
            '(previously a null-cast TypeError at the role VBadge)',
      );
      expect(
        find.text('No Role Club'),
        findsOneWidget,
        reason: 'the row still renders its name and shards',
      );
      expect(
        find.text('7'),
        findsOneWidget,
        reason: 'the shard count survives the fallback path',
      );
      expect(
        find.byType(VBadge),
        findsNothing,
        reason: 'the member default renders no role badge',
      );
    });
  });

  group('GroupDetailScreen (USER FIX 4 — AppBar title, no hero banner)', () {
    testWidgets('the group name renders in the AppBar title (next to the '
        'back arrow) exactly once — no hero banner above the tabs', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const GroupDetailScreen(groupId: _groupId),
          overrides: _detailOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final appBarName = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Disco Crew'),
      );
      expect(
        appBarName,
        findsOneWidget,
        reason:
            'USER FIX 4 — the name lives in the AppBar title next to the '
            'back arrow',
      );
      expect(
        find.text('Disco Crew'),
        findsOneWidget,
        reason: 'the name appears exactly once in the whole tree (USER FIX 4)',
      );
      final title = tester.widget<Text>(appBarName);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(
        find.byType(VDisplayText),
        findsNothing,
        reason: 'the hero display voice above the tabs is gone (USER FIX 4)',
      );
      expect(
        find.byType(VGlassCard),
        findsNothing,
        reason: 'the hero glass card above the tabs is gone (USER FIX 4)',
      );
    });

    testWidgets('size tier renders a VBadge, the rank a RankBadge and the '
        'shards a gold icon', (tester) async {
      await tester.pumpWidget(
        _wrap(
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
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('MICRO'),
        findsOneWidget,
        reason: 'the size badge is a §5.5 VBadge (uppercase labelSmall)',
      );
      expect(find.byType(VBadge), findsOneWidget);
      expect(find.byType(RankBadge), findsOneWidget);
      final shard = tester.widget<VShardIcon>(find.byType(VShardIcon));
      expect(shard.color, AppColors.currencyShards);
      expect(shard.size, AppIconSizes.sm, reason: '§5.6 default 16');
    });

    testWidgets('Donar is the glowAccent filled primary; Crear evento and '
        'Invitar stay outlined', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const GroupDetailScreen(groupId: _groupId),
          overrides: _detailOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      final donate = _buttonWithLabel(tester, 'Donar shards');
      expect(
        donate.variant,
        VButtonVariant.glow,
        reason: '§5.1 — the primary detail action is the glow accent',
      );
      expect(donate.filled, isTrue);
      expect(
        donate.gradient,
        AppGradients.violet,
        reason: 'LUXE — the donate CTA carries the violet family gradient',
      );
      expect(
        _buttonWithLabel(tester, 'Crear evento').variant,
        VButtonVariant.outlined,
      );
      expect(
        _buttonWithLabel(tester, 'Invitar').variant,
        VButtonVariant.outlined,
      );
    });

    testWidgets('members tab renders ProfileAvatar + VBadge role + hairline '
        'rows', (tester) async {
      await tester.pumpWidget(
        _wrap(
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
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Miembros'));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('PROMOTOR'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
      // Scoped to the members list: the detail body no longer owns a
      // screen-level divider (the hero banner is gone — USER FIX 4), so the
      // ListView scope isolates the row hairs.
      final rows = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Divider),
      );
      expect(
        rows,
        findsNWidgets(2),
        reason: 'each member/contributor row closes with a hairline',
      );
      expect(_dividerColor(tester), AppColors.hairline);
    });

    testWidgets('frozen banner uses the errorFill (glowPinkDeep) treatment '
        'with white text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const GroupDetailScreen(groupId: _groupId),
          overrides: _detailOverrides(
            group: {
              'id': _groupId,
              'name': 'Disco Crew',
              'group_shards': 100,
              'frozen_at': '2026-01-01T00:00:00Z',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final banner = find.textContaining('Grupo congelado');
      expect(banner, findsOneWidget);
      // The banner is a `Container(color: ...)` — its widget `decoration` is
      // null (Container folds `color:` into the effective decoration in
      // build); resolve the fill from `color` directly.
      final container = tester.widget<Container>(
        find.ancestor(of: banner, matching: find.byType(Container)).first,
      );
      expect(
        container.color,
        AppColors.errorFill,
        reason:
            '§5.2 — never raw red on black; white-on-glowPinkDeep is '
            '5.87:1 (AA)',
      );
      final text = tester.widget<Text>(banner);
      expect(text.style?.color, AppColors.white);
    });

    testWidgets('first load shows the cover+lines skeleton, not a spinner '
        '(U-24 §5.8)', (tester) async {
      final gate = Completer<Map<String, dynamic>?>();
      await tester.pumpWidget(
        _wrap(
          const GroupDetailScreen(groupId: _groupId),
          overrides: [
            groupDetailProvider.overrideWith(
              () => _GatedGroupDetailNotifier(gate),
            ),
            groupMembersProvider.overrideWith(_StubGroupMembersNotifier.new),
            contributionsProvider.overrideWith(_StubContributionsNotifier.new),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byType(VSkeletonDetail),
        findsOneWidget,
        reason:
            'the heaviest groups screen (three stacked fetches) shows '
            'the detail skeleton on the nothing-on-screen frame (U-22 '
            'handoff → U-24)',
      );
      expect(find.byType(VLoadingView), findsNothing);

      gate.complete({
        'id': _groupId,
        'name': 'Disco Crew',
        'group_shards': 100,
      });
      await tester.pumpAndSettle();

      expect(
        find.byType(VSkeletonDetail),
        findsNothing,
        reason: 'the skeleton is gone once the data lands',
      );
      expect(
        find.text('Disco Crew'),
        findsOneWidget,
        reason: 'the loaded screen owns the name in the AppBar title',
      );
    });
  });

  group('LeaderboardScreen (LUXE violet podium — XL-10)', () {
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

      final gold = _rowBadge(tester, 'TOP UNO');
      expect(gold.rank, 1);
      expect(_badgeBorderColor(tester, 'TOP UNO'), AppColors.discoGold);

      final silver = _rowBadge(tester, 'TOP DOS');
      expect(silver.rank, 2);
      expect(_badgeBorderColor(tester, 'TOP DOS'), AppColors.discoSilver);

      final bronze = _rowBadge(tester, 'TOP TRES');
      expect(bronze.rank, 3);
      expect(_badgeBorderColor(tester, 'TOP TRES'), AppColors.discoBronze);

      expect(
        _rowBadge(tester, 'Cuarto').rank,
        isNull,
        reason: 'non-top rows keep the §5.5 neutral white badge',
      );
    });

    testWidgets('top-3 names render violet VDisplayText (Playfair MAYUS 28) '
        'in glass cards; the rest stay Inter', (tester) async {
      await tester.pumpWidget(pumpLeaderboard());
      await tester.pumpAndSettle();

      for (final name in ['Top Uno', 'Top Dos', 'Top Tres']) {
        final display = _display(tester, name);
        expect(display.size, 28);
        expect(
          display.gradient,
          AppGradients.violet,
          reason: 'LUXE — podium names carry the violet display voice',
        );
        final glyphs = _displayGlyphs(tester, name);
        expect(
          glyphs.style?.fontFamily,
          AppTypography.playfair,
          reason: '§3.2 — podium names are Playfair 28',
        );
        expect(glyphs.style?.fontSize, 28);
        expect(
          _glassOf(tester, name.toUpperCase()).gradient?.colors,
          AppGradients.watered(AppGradients.violet.colors, mix: 0.4),
          reason:
              'XL-17 — the podium card ring rides the watered violet run; '
              'the vivid VDisplayText shader above keeps the accent',
        );
      }

      final rest = tester.widget<Text>(find.text('Cuarto'));
      expect(
        rest.style?.fontFamily,
        isNot(AppTypography.playfair),
        reason: 'the fancy treatment is for the podium only',
      );
    });

    testWidgets('tier chips are neutral white VChips (XL-17: the violet '
        'accent is spent on the podium hero, not the filter row)', (
      tester,
    ) async {
      await tester.pumpWidget(pumpLeaderboard());
      await tester.pumpAndSettle();

      expect(find.byType(VChip), findsNWidgets(4));
      for (final tier in ['micro', 'small', 'medium', 'large']) {
        expect(find.text(tier), findsOneWidget);
      }
      for (final chip in tester.widgetList<VChip>(find.byType(VChip))) {
        expect(
          chip.accent,
          isFalse,
          reason:
              'XL-17 (09_groups: "reduce the violet everywhere") — the '
              'filter row drops to the §5.4 neutral white chip treatment',
        );
        expect(chip.gradient, isNull);
      }
    });
  });

  group('CreateGroupScreen (LUXE violet glass form — XL-10)', () {
    testWidgets('cover picker renders surfaceAlt + border + camera '
        'affordance inside the violet glass form card', (tester) async {
      await tester.pumpWidget(_wrap(const CreateGroupScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(VAurora), findsOneWidget);
      expect(tester.widget<VAurora>(find.byType(VAurora)).gradients, const [
        AppGradients.violet,
      ]);
      expect(
        tester.widget<VGlassCard>(find.byType(VGlassCard)).gradient,
        AppGradients.violet,
        reason: 'LUXE — the whole form sits in a violet glass card',
      );
      final picker = tester.widget<Container>(
        find
            .ancestor(
              of: find.byIcon(Icons.camera_alt),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = picker.decoration as BoxDecoration;
      expect(
        decoration.color,
        AppColors.surfaceAlt,
        reason: '§5.8 skeleton-base surface for the empty cover slot',
      );
      expect(
        decoration.border,
        Border.all(color: AppColors.border),
        reason: 'the §2.1 interactive-outline token',
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.camera_alt));
      expect(
        icon.color,
        AppColors.muted,
        reason: 'muted #666666 passes the 3:1 non-text rule as an icon',
      );
      final label = tester.widget<Text>(find.text('Agregar foto de portada'));
      expect(
        label.style?.color,
        AppColors.mutedStrong,
        reason: 'informational text must be AA (muted fails §2.4)',
      );
    });

    testWidgets('the create CTA uses glowAccent filled with the violet '
        'gradient (§5.1 canonical primary)', (tester) async {
      await tester.pumpWidget(_wrap(const CreateGroupScreen()));
      await tester.pumpAndSettle();

      final create = _buttonWithLabel(tester, 'Crear');
      expect(create.variant, VButtonVariant.glow);
      expect(create.filled, isTrue);
      expect(
        create.gradient,
        AppGradients.violet,
        reason: 'LUXE — the create CTA carries the violet family gradient',
      );
    });
  });

  group('DonateShardsScreen (LUXE violet glass form — XL-10)', () {
    testWidgets('amount VInput keeps the token label treatment and the '
        'donate CTA is glowAccent filled with the violet gradient', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const DonateShardsScreen(groupId: _groupId, groupName: 'Test Group'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VAurora), findsOneWidget);
      expect(
        tester.widget<VGlassCard>(find.byType(VGlassCard)).gradient,
        AppGradients.violet,
        reason: 'LUXE — the donation form sits in a violet glass card',
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.decoration?.labelStyle?.color,
        AppColors.mutedStrong,
        reason:
            'the U-05 VInput label token (AA — the §5.2 shard-amount '
            'seam)',
      );
      final donate = _buttonWithLabel(tester, 'Donar');
      expect(
        donate.variant,
        VButtonVariant.glow,
        reason: '§5.1 — donating shards is the screen\'s primary action',
      );
      expect(donate.filled, isTrue);
      expect(
        donate.gradient,
        AppGradients.violet,
        reason: 'LUXE — the donate CTA carries the violet family gradient',
      );
    });
  });

  group('InviteScreen (LUXE violet glass search — XL-10)', () {
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

    testWidgets('search field sits in a violet gradient glass ring with no '
        'decoration border', (tester) async {
      await tester.pumpWidget(pumpInvite());
      await tester.pumpAndSettle();

      final ring = tester.widget<VGradientBorder>(
        find.ancestor(
          of: find.byType(TextField),
          matching: find.byType(VGradientBorder),
        ),
      );
      expect(
        ring.gradient.colors,
        AppGradients.violet.colors,
        reason:
            'LUXE — the search slot is a violet gradient ring (liquid, '
            'radius 16), no underline and no OutlineInputBorder',
      );
      expect(ring.radius, const BorderRadius.all(Radius.circular(16)));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.decoration?.border,
        InputBorder.none,
        reason:
            'the glass ring owns the border — the decoration renders '
            'borderless',
      );
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
      expect(
        find.byType(Checkbox),
        findsNWidgets(2),
        reason: 'the selection checkbox survives (U-04 sharp theme)',
      );
      expect(
        find.byType(VGlassCard),
        findsNWidgets(2),
        reason: 'LUXE — every result row sits in a violet glass card',
      );
      for (final card in tester.widgetList<VGlassCard>(
        find.byType(VGlassCard),
      )) {
        expect(card.gradient, AppGradients.violet);
      }
      expect(
        find.byType(Divider),
        findsOneWidget,
        reason: '2 results → 1 hairline separator',
      );
      expect(_dividerColor(tester), AppColors.hairline);
    });

    testWidgets('search loading renders the §5.8 spinner, not a Material '
        'linear bar (U-24)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const InviteScreen(groupId: _groupId),
          overrides: [
            groupMembersProvider.overrideWith(_StubGroupMembersNotifier.new),
            searchResultsProvider.overrideWith(
              _PendingSearchResultsNotifier.new,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'lu');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(
        find.byType(VLoadingView),
        findsOneWidget,
        reason:
            'the search-loading surface is the §5.8 spinner — the raw '
            'Material LinearProgressIndicator is gone (U-24)',
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('GroupMembersScreen (LUXE violet glass rows — XL-10)', () {
    testWidgets('rows render ProfileAvatar + VBadge roles with hairline '
        'separators inside violet glass cards', (tester) async {
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

      await tester.pumpWidget(
        _wrap(
          const GroupMembersScreen(groupId: _groupId),
          overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VAurora), findsOneWidget);
      expect(find.byType(ProfileAvatar), findsNWidgets(2));
      expect(find.text('PROMOTOR'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
      expect(
        find.byType(VGlassCard),
        findsNothing,
        reason:
            'XL-17 (09_groups declutter) — member rows are plain hairline '
            'rows; the violet glass stays on the detail hero only',
      );
      expect(
        find.byType(Divider),
        findsOneWidget,
        reason: '2 rows → 1 hairline separator',
      );
      expect(_dividerColor(tester), AppColors.hairline);
    });
  });
}
