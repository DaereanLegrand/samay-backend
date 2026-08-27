import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/group_member.dart';
import 'package:samay/features/groups/screens/group_detail_screen.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/l10n/app_localizations.dart';

import '../support/fake_supabase_http.dart' as support;

/// Static guard for finding PERF-01 (H-27): every list whose children are
/// DERIVED FROM DATA must be a `ListView.builder` so off-screen rows are built
/// lazily. The plain `ListView(children: [...])` constructor eagerly builds
/// every child regardless of viewport visibility.
///
/// This test greps `lib/` for the plain `ListView(` constructor (the `(`
/// right after `ListView` never appears in `ListView.builder(` /
/// `ListView.separated(` / `ListView.custom(`) and fails on any file that is
/// not justified below.
///
/// Allowlist policy (matching the PERF-01 fix scope): only SHORT, FIXED-CONTENT
/// lists — forms, static menus, and info headers whose child count does not
/// depend on fetched data — may keep `ListView(children: ...)`. Converting
/// those to `ListView.builder` would only add index-switch noise. Every entry
/// MUST carry a justification. Never add a data-derived list here; convert it
/// to `ListView.builder` instead.
const _justifiedFixedLists = <String, String>{
  'lib/features/minigames/screens/minigame_session_detail_screen.dart':
      'fixed session header + status card + a conditional invite/closed card '
      '(≤3 children) — no data list (participants render as a count)',
  'lib/features/profile/screens/edit_profile_screen.dart':
      'fixed 5-child form (avatar, bio input, save button, password link) — no data list',
  'lib/features/profile/screens/public_profile_screen.dart':
      'fixed profile header + friendship actions — no data list',
  'lib/features/profile/screens/profile_screen.dart':
      'fixed profile header; its only data-derived list (my groups) is a '
      'ListView.builder child; the outer ListView type is asserted by '
      'test/features/profile_screens_test.dart (pull-to-refresh fling)',
  'lib/features/profile/screens/settings_screen.dart':
      'fixed 7-item settings menu — static routes, not data',
  'lib/features/groups/screens/donate_shards_screen.dart':
      'fixed 4-child donation form — no data list',
  'lib/features/groups/screens/create_group_screen.dart':
      'fixed 5-child create-group form — no data list',
  'lib/features/events/screens/event_detail_screen.dart':
      'fixed event header + section stack (cover, name, badges, info rows, '
      'pool card, promotores section, actions); the only data-derived content '
      '(promotores avatars, invite row) renders inside the fixed sections '
      'via Wrap/conditionals, not as list children',
  'lib/features/events/screens/create_event_screen.dart':
      'fixed ECRT creation form (cover, inputs, pickers, chips, preshards '
      'section, submit); the only data-derived content (myGroups dropdown '
      'items) renders inside the fixed group section, not as list children',
  'lib/features/subscriptions/screens/paywall_screen.dart':
      'fixed paywall: header + 3 const tier cards (Free/PRO/VIP) + restore '
      'button — the tier/feature catalogs are const (paywallTiers/'
      'paywallRows), only price values come from app_config, so the child '
      'count never depends on fetched data',
  'lib/features/profile/screens/notification_settings_screen.dart':
      'fixed 4-toggle notification preferences — static rows, not data',
  'lib/features/profile/screens/privacy_info_screen.dart':
      'fixed privacy/terms section stack — static content, not data',
};

final _plainListView = RegExp(r'ListView\(');

const _groupId = '33333333-3333-3333-3333-333333333333';
const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

class _FakeGroupDetail extends GroupDetailNotifier {
  @override
  Future<Group?> build(String arg) async =>
      const Group(id: _groupId, name: 'Disco Crew', groupShards: 100);
}

class _FakeGroupMembers extends GroupMembersNotifier {
  @override
  Future<List<GroupMember>> build(String arg) async => [
        GroupMember(
          id: 'gm-1',
          groupId: _groupId,
          userId: _userId1,
          role: 'promotor',
          joinedAt: DateTime(2026),
          users: const {'username': 'ana'},
        ),
        GroupMember(
          id: 'gm-2',
          groupId: _groupId,
          userId: _userId2,
          role: 'member',
          joinedAt: DateTime(2026),
          users: const {'username': 'lucas'},
        ),
      ];
}

class _FakeContributions extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      const GroupContributionsData(
        contributors: [
          {
            'user_id': _userId1,
            'shards_contributed': 50,
            'users': {'username': 'ana'},
          },
        ],
        myContribution: 0,
      );
}

class _FakeGroupDetailCombined extends GroupDetailCombinedNotifier {
  @override
  Future<GroupDetailData> build(String arg) async => GroupDetailData(
        group: const Group(
          id: _groupId,
          name: 'Disco Crew',
          groupShards: 100,
        ),
        members: [
          GroupMember(
            id: 'gm-1',
            groupId: _groupId,
            userId: _userId1,
            role: 'promotor',
            joinedAt: DateTime(2026),
            users: const {'username': 'ana'},
          ),
          GroupMember(
            id: 'gm-2',
            groupId: _groupId,
            userId: _userId2,
            role: 'member',
            joinedAt: DateTime(2026),
            users: const {'username': 'lucas'},
          ),
        ],
        contributions: const GroupContributionsData(
          contributors: [
            {
              'user_id': _userId1,
              'shards_contributed': 50,
              'users': {'username': 'ana'},
            },
          ],
          myContribution: 0,
        ),
        membership: null,
      );
}

void main() {
  test('every ListView(children:) in lib/ is a justified fixed-content list',
      () {
    final hitsPerFile = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final hits = entity
          .readAsLinesSync()
          .where((line) => _plainListView.hasMatch(line))
          .length;
      if (hits > 0) hitsPerFile[entity.path] = hits;
    }

    final missing = hitsPerFile.keys
        .where((path) => !_justifiedFixedLists.containsKey(path))
        .toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: 'unjustified ListView(children:) in: $missing — '
          'data-derived lists must use ListView.builder (PERF-01/H-27); '
          'add a justified entry only for short fixed-content lists',
    );

    final stale = _justifiedFixedLists.keys
        .where((path) => !hitsPerFile.containsKey(path))
        .toList()
      ..sort();
    expect(
      stale,
      isEmpty,
      reason: 'stale allowlist entries (no ListView(children:) remains): '
          '$stale — remove them so the allowlist stays honest',
    );
  });

  group('converted members tab (group_detail_screen.dart)', () {
    // U-16 R17 (coordination with I-20, U-11 precedent): the members tab is
    // admin-gated since R17 — it reads the current user's id from
    // `authServiceProvider`, so the test now boots the Supabase harness.
    setUpAll(() => support.initSupabaseHarness(sessionEmail: 'a@b.com'));

    testWidgets('renders the same contributors and members rows as before',
        (tester) async {
      final container = ProviderContainer(overrides: [
        groupDetailProvider.overrideWith(_FakeGroupDetail.new),
        groupMembersProvider.overrideWith(_FakeGroupMembers.new),
        contributionsProvider.overrideWith(_FakeContributions.new),
        groupDetailCombinedProvider.overrideWith(_FakeGroupDetailCombined.new),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: GroupDetailScreen(groupId: _groupId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Miembros'));
      await tester.pumpAndSettle();

      expect(find.text('Top contribuidores'), findsOneWidget);
      expect(find.text('Miembros (2)'), findsOneWidget);
      // 'ana' renders twice: top-contributor row + member row.
      expect(find.text('ana'), findsNWidgets(2));
      expect(find.text('50 shards'), findsOneWidget);
      // LUXE: rows sit in VGlassCards — the last lazy member row sits below
      // the 800px test fold; drag the members ListView to build it (the
      // hero + TabBarView make multiple Scrollables — drag the list itself).
      await tester.dragUntilVisible(
        find.text('lucas'),
        find.byType(ListView),
        const Offset(0, -60),
      );
      expect(find.text('lucas'), findsOneWidget);
      // U-11 restyle: roles render as §5.5 VBadges (uppercase labelSmall)
      // instead of raw subtitle text.
      expect(find.text('PROMOTOR'), findsOneWidget);
      expect(find.text('MEMBER'), findsOneWidget);
    });
  });
}
