import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/models/group.dart';
import 'package:samay/core/models/user_profile.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/social/screens/social_screen.dart';
import 'package:samay/features/social/widgets/social_action_tile.dart';
import 'package:samay/l10n/app_localizations.dart';

class _EmptyGroups extends MyGroupsNotifier {
  @override
  Future<List<Group>> build() async => const [];
}

class _EmptyFriends extends FriendsListNotifier {
  @override
  Future<List<UserProfile>> build() async => const [];
}

class _EmptyRequests extends FriendRequestsNotifier {
  @override
  Future<FriendRequestsData> build() async =>
      const FriendRequestsData(requests: [], names: {});
}

class _EmptyInvites extends GroupInvitesNotifier {
  @override
  Future<List<Map<String, dynamic>>> build() async => const [];
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myGroupsProvider.overrideWith(_EmptyGroups.new),
        friendsListProvider.overrideWith(_EmptyFriends.new),
        friendRequestsProvider.overrideWith(_EmptyRequests.new),
        groupInvitesProvider.overrideWith(_EmptyInvites.new),
      ],
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SocialScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the Grupos/Amigos pill tabs and defaults to Grupos', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Grupos'), findsOneWidget);
    expect(find.text('Amigos'), findsOneWidget);
    expect(
      find.text('Crear grupo'),
      findsOneWidget,
      reason: 'the Grupos sub-tab renders the create-group action by default',
    );
  });

  testWidgets('the lupa (search) is present on BOTH sub-tabs — Grupos '
      'default and after switching to Amigos', (tester) async {
    await _pump(tester);

    expect(
      find.byIcon(Icons.search),
      findsOneWidget,
      reason: 'D-social-density — the Grupos sub-tab shows the lupa too',
    );

    await tester.tap(find.text('Amigos'));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.search),
      findsOneWidget,
      reason: 'the Amigos sub-tab keeps the lupa in the top right',
    );
  });

  testWidgets('the pill tab bar is slim — outer height (incl. margins) '
      '≤ 34px', (tester) async {
    await _pump(tester);

    final pill = find.byKey(const ValueKey('socialPillTabBar'));
    expect(pill, findsOneWidget);
    final size = tester.getSize(pill);
    expect(
      size.height,
      lessThanOrEqualTo(34),
      reason:
          'D-social-density — the pill must be at most half of its old '
          '~68px footprint',
    );
  });

  testWidgets('both sub-tabs render the shared compact SocialActionTile '
      'entries at ≤ 44px', (tester) async {
    await _pump(tester);

    Future<void> expectCompactRow() async {
      final tiles = find.byType(SocialActionTile);
      final count = tester.widgetList(tiles).length;
      expect(
        count,
        2,
        reason: 'each sub-tab renders exactly two action entries',
      );
      for (var i = 0; i < count; i++) {
        final size = tester.getSize(tiles.at(i));
        expect(
          size.height,
          lessThanOrEqualTo(44),
          reason: 'the shared tile stays compact (40px target)',
        );
      }
    }

    // Grupos (default sub-tab): Crear grupo + Ranking.
    await expectCompactRow();
    expect(find.text('Crear grupo'), findsOneWidget);
    expect(find.text('Ranking'), findsOneWidget);

    // Amigos sub-tab: Solicitudes + Ranking.
    await tester.tap(find.text('Amigos'));
    await tester.pumpAndSettle();
    await expectCompactRow();
    expect(find.text('Solicitudes'), findsOneWidget);
    expect(find.text('Ranking'), findsOneWidget);
  });
}
