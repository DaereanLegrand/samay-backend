import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/features/groups/group_detail_screen.dart';
import 'package:samay/features/groups/groups_providers.dart';
import 'package:samay/l10n/app_localizations.dart';

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
  'lib/features/profile/edit_profile_screen.dart':
      'fixed 5-child form (avatar, bio input, save button, password link) — no data list',
  'lib/features/profile/public_profile_screen.dart':
      'fixed profile header + friendship actions — no data list',
  'lib/features/profile/profile_screen.dart':
      'fixed profile header; its only data-derived list (my groups) is a '
      'ListView.builder child; the outer ListView type is asserted by '
      'test/features/profile_screens_test.dart (pull-to-refresh fling)',
  'lib/features/profile/settings_screen.dart':
      'fixed 7-item settings menu — static routes, not data',
  'lib/features/groups/donate_shards_screen.dart':
      'fixed 4-child donation form — no data list',
  'lib/features/groups/create_group_screen.dart':
      'fixed 5-child create-group form — no data list',
};

final _plainListView = RegExp(r'ListView\(');

const _groupId = '33333333-3333-3333-3333-333333333333';
const _userId1 = '11111111-1111-1111-1111-111111111111';
const _userId2 = '22222222-2222-2222-2222-222222222222';

class _FakeGroupDetail extends GroupDetailNotifier {
  @override
  Future<Map<String, dynamic>?> build(String arg) async =>
      {'id': _groupId, 'name': 'Disco Crew', 'group_shards': 100};
}

class _FakeGroupMembers extends GroupMembersNotifier {
  @override
  Future<List<Map<String, dynamic>>> build(String arg) async => [
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
      ];
}

class _FakeContributions extends GroupContributionsNotifier {
  @override
  Future<GroupContributionsData> build(String arg) async =>
      GroupContributionsData(
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
    testWidgets('renders the same contributors and members rows as before',
        (tester) async {
      final container = ProviderContainer(overrides: [
        groupDetailProvider.overrideWith(_FakeGroupDetail.new),
        groupMembersProvider.overrideWith(_FakeGroupMembers.new),
        contributionsProvider.overrideWith(_FakeContributions.new),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const GroupDetailScreen(groupId: _groupId),
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
      expect(find.text('lucas'), findsOneWidget);
      expect(find.text('promotor'), findsOneWidget);
      expect(find.text('member'), findsOneWidget);
    });
  });
}
