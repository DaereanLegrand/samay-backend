import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/models/friend_request_summary.dart';
import 'package:samay/core/models/notification_item.dart';
import 'package:samay/core/router/main_shell.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/features/friends/providers/friends_providers.dart';
import 'package:samay/features/groups/providers/groups_providers.dart';
import 'package:samay/features/notifications/providers/notifications_providers.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_count_badge.dart';
import 'package:samay/shared/widgets/v_tab_fade.dart';

const _emptyRequests = FriendRequestsData(requests: [], names: {});

/// U-17 R18: the shell watches the pending-count sources, so the harness pins
/// them to inert stubs (zero counts by default) — no Supabase needed.
class _StubFriendRequestsNotifier extends FriendRequestsNotifier {
  final FriendRequestsData data;

  _StubFriendRequestsNotifier({this.data = _emptyRequests});

  @override
  Future<FriendRequestsData> build() async => data;
}

class _StubGroupInvitesNotifier extends GroupInvitesNotifier {
  final List<Map<String, dynamic>> data;

  _StubGroupInvitesNotifier({this.data = const []});

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

/// The shell also derives pending minigame invites from the notifications
/// list (2026-08-27) — stubbed to zero by default so no service is needed.
class _StubNotificationsNotifier extends NotificationsNotifier {
  final List<NotificationItem> data;

  _StubNotificationsNotifier({this.data = const []});

  @override
  Future<List<NotificationItem>> build() async => data;
}

/// Mutable requests notifier for the badge live-update pin (U-28): [build]
/// reads the current [data], so a container-level refresh re-derives the
/// pending count and the shell badge must follow.
class _LiveFriendRequestsNotifier extends FriendRequestsNotifier {
  FriendRequestsData data;

  _LiveFriendRequestsNotifier(this.data);

  @override
  Future<FriendRequestsData> build() async => data;
}

class _LiveGroupInvitesNotifier extends GroupInvitesNotifier {
  List<Map<String, dynamic>> data;

  _LiveGroupInvitesNotifier(this.data);

  @override
  Future<List<Map<String, dynamic>>> build() async => data;
}

ThemeData _navTheme() {
  return ThemeData(
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      type: BottomNavigationBarType.fixed,
      showSelectedLabels: true,
      showUnselectedLabels: true,
    ),
  );
}

Widget _localized(
  Widget child, {
  FriendRequestsData requests = _emptyRequests,
  List<Map<String, dynamic>> invites = const [],
}) {
  return ProviderScope(
    overrides: [
      friendRequestsProvider.overrideWith(
        () => _StubFriendRequestsNotifier(data: requests),
      ),
      groupInvitesProvider.overrideWith(
        () => _StubGroupInvitesNotifier(data: invites),
      ),
      notificationsProvider.overrideWith(_StubNotificationsNotifier.new),
    ],
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _navTheme(),
      home: child,
    ),
  );
}

class _StubScreen extends StatelessWidget {
  final String label;

  const _StubScreen(this.label);

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

GoRouter _stubRouter() {
  return GoRouter(
    initialLocation: RoutePaths.mainFeed,
    routes: [
      ShellRoute(
        builder: (context, state, child) => MainShell(
          currentIndex: shellIndexFor(state.matchedLocation),
          child: child,
        ),
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const _StubScreen('Feed stub'),
          ),
          GoRoute(
            path: RoutePaths.mainGroups,
            builder: (_, _) => const _StubScreen('Groups stub'),
          ),
          GoRoute(
            path: RoutePaths.mainEvents,
            builder: (_, _) => const _StubScreen('Events stub'),
          ),
          GoRoute(
            path: RoutePaths.mainNotifications,
            builder: (_, _) => const _StubScreen('Notifications stub'),
          ),
          GoRoute(
            path: RoutePaths.mainProfile,
            builder: (_, _) => const _StubScreen('Profile stub'),
          ),
        ],
      ),
    ],
  );
}

Widget _localizedRouter(
  GoRouter router, {
  FriendRequestsData requests = _emptyRequests,
  List<Map<String, dynamic>> invites = const [],
}) {
  return ProviderScope(
    overrides: [
      friendRequestsProvider.overrideWith(
        () => _StubFriendRequestsNotifier(data: requests),
      ),
      groupInvitesProvider.overrideWith(
        () => _StubGroupInvitesNotifier(data: invites),
      ),
      notificationsProvider.overrideWith(_StubNotificationsNotifier.new),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

void main() {
  group('shellIndexFor', () {
    test('maps the feed location to index 0', () {
      expect(shellIndexFor(RoutePaths.mainFeed), 0);
    });

    test('maps the groups location to index 1', () {
      expect(shellIndexFor(RoutePaths.mainGroups), 1);
    });

    test('maps the events location to index 2', () {
      expect(shellIndexFor(RoutePaths.mainEvents), 2);
    });

    test('maps the notifications location to index 3', () {
      expect(shellIndexFor(RoutePaths.mainNotifications), 3);
    });

    test('maps the profile location to index 4', () {
      expect(shellIndexFor(RoutePaths.mainProfile), 4);
    });

    test('maps an unknown location to index 0', () {
      expect(shellIndexFor('/main/unknown'), 0);
      expect(shellIndexFor('/login'), 0);
      expect(shellIndexFor(''), 0);
    });

    test('matches child locations under each tab by prefix', () {
      expect(shellIndexFor('${RoutePaths.mainGroups}/some/child'), 1);
      expect(shellIndexFor('${RoutePaths.mainEvents}?tab=upcoming'), 2);
    });
  });

  group('mainShellTabs', () {
    test('defines exactly five tabs', () {
      expect(mainShellTabs, hasLength(5));
    });

    test('keeps labels identical to the original shell', () {
      expect(mainShellTabs.map((t) => t.label).toList(), [
        'Feed',
        'Social',
        'Eventos',
        'Notis',
        'Perfil',
      ]);
    });

    test('keeps icons identical to the original shell', () {
      expect(mainShellTabs.map((t) => t.icon).toList(), [
        Icons.explore_outlined,
        Icons.group_outlined,
        Icons.event_outlined,
        Icons.notifications_outlined,
        Icons.person_outline,
      ]);
    });

    test('provides a distinct selected icon per tab', () {
      for (final tab in mainShellTabs) {
        expect(tab.selectedIcon, isNot(tab.icon));
      }
    });

    test('maps tabs to their RoutePaths in order', () {
      expect(mainShellTabs.map((t) => t.path).toList(), [
        RoutePaths.mainFeed,
        RoutePaths.mainGroups,
        RoutePaths.mainEvents,
        RoutePaths.mainNotifications,
        RoutePaths.mainProfile,
      ]);
    });
  });

  group('MainShell', () {
    testWidgets('renders the child and the floating nav bar', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: Text('Shell body'))),
      );

      expect(find.text('Shell body'), findsOneWidget);
      // The floating glass pill replaces the Material BottomNavigationBar
      // (2026-08-27 Premium pill port).
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(find.byType(BackdropFilter), findsWidgets);
    });

    testWidgets('renders every tab icon (filled for the selected tab, '
        'outlined for the rest)', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: SizedBox())),
      );

      // U-08: `activeIcon` is wired — the selected tab renders its filled
      // `selectedIcon`, unselected tabs render the outlined `icon`.
      expect(
        find.byIcon(mainShellTabs[0].selectedIcon),
        findsOneWidget,
        reason:
            'missing filled selected icon for tab ${mainShellTabs[0].label}',
      );
      expect(
        find.byIcon(mainShellTabs[0].icon),
        findsNothing,
        reason: 'the selected tab must not render the outlined icon',
      );
      for (var i = 1; i < mainShellTabs.length; i++) {
        expect(
          find.byIcon(mainShellTabs[i].icon),
          findsOneWidget,
          reason: 'missing icon for tab ${mainShellTabs[i].label}',
        );
        expect(
          find.byIcon(mainShellTabs[i].selectedIcon),
          findsNothing,
          reason:
              'unselected tab ${mainShellTabs[i].label} must render its '
              'outlined icon, not the filled one',
        );
      }
    });

    testWidgets('wires each tab selectedIcon to render when that tab is '
        'selected (I-04 deferred item)', (tester) async {
      // For each tab index, the shell must render THAT tab's filled
      // `selectedIcon` and every other tab's outlined `icon`.
      for (var sel = 0; sel < mainShellTabs.length; sel++) {
        await tester.pumpWidget(
          _localized(MainShell(currentIndex: sel, child: const SizedBox())),
        );
        for (var i = 0; i < mainShellTabs.length; i++) {
          final expected = i == sel
              ? mainShellTabs[i].selectedIcon
              : mainShellTabs[i].icon;
          expect(
            find.byIcon(expected),
            findsOneWidget,
            reason: 'tab ${mainShellTabs[i].label} should render $expected '
                'when index $sel is active',
          );
        }
      }
    });

    testWidgets('switches the rendered icon when the selected tab changes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 1, child: SizedBox())),
      );

      expect(
        find.byIcon(mainShellTabs[1].selectedIcon),
        findsOneWidget,
        reason: 'the groups tab is selected — filled group icon must show',
      );
      expect(find.byIcon(mainShellTabs[1].icon), findsNothing);
      expect(find.byIcon(mainShellTabs[0].selectedIcon), findsNothing);
      expect(
        find.byIcon(mainShellTabs[0].icon),
        findsOneWidget,
        reason: 'the feed tab is unselected — outlined icon must show',
      );
    });

    testWidgets('renders every tab icon as a tooltip label', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: SizedBox())),
      );

      // The floating pill exposes each tab's localized label as a Tooltip
      // message (Juega anatomy) — semantics keep the name announced.
      for (final tab in mainShellTabs) {
        expect(
          find.byTooltip(tab.label),
          findsOneWidget,
          reason: 'missing tooltip label for tab ${tab.label}',
        );
      }
    });

    testWidgets('the selected tab is highlighted by its white icon + dot', (
      tester,
    ) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 3, child: SizedBox())),
      );

      // Notis tab (index 3) selected → filled icon present.
      expect(find.byIcon(mainShellTabs[3].selectedIcon), findsOneWidget);
      // The selected indicator dot renders below the active icon.
      final dots = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle &&
            w.constraints is BoxConstraints &&
            (w.constraints as BoxConstraints).maxWidth == 4,
      );
      expect(dots, findsOneWidget, reason: 'exactly one selected dot');    });

    testWidgets('tapping a tab navigates via context.go', (tester) async {
      final router = _stubRouter();
      await tester.pumpWidget(_localizedRouter(router));
      await tester.pumpAndSettle();

      expect(find.text('Feed stub'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.group_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Groups stub'), findsOneWidget);
      expect(find.text('Feed stub'), findsNothing);
      // The pill now highlights the groups tab (filled icon).
      expect(find.byIcon(mainShellTabs[1].selectedIcon), findsOneWidget);
    });

    testWidgets('tapping each remaining tab lands on its screen', (
      tester,
    ) async {
      final router = _stubRouter();
      await tester.pumpWidget(_localizedRouter(router));
      await tester.pumpAndSettle();

      for (final (icon, expected) in [
        (Icons.event_outlined, 'Events stub'),
        (Icons.notifications_outlined, 'Notifications stub'),
        (Icons.person_outline, 'Profile stub'),
        (Icons.explore_outlined, 'Feed stub'),
      ]) {
        await tester.tap(find.byIcon(icon));
        await tester.pumpAndSettle();
        expect(
          find.text(expected),
          findsOneWidget,
          reason: 'tapping $icon should show $expected',
        );
      }
    });

    group('R18 — Grupos-tab pending badge (U-13 §5.4)', () {
      const received = FriendRequestsData(
        requests: [
          FriendRequestSummary(type: 'received', friendshipId: 'f1', userId: 'u1'),
          FriendRequestSummary(type: 'received', friendshipId: 'f2', userId: 'u2'),
        ],
        names: {'u1': 'ana', 'u2': 'lucas'},
      );
      const invite = {
        'id': 'm1',
        'groups': {'name': 'Disco Crew'},
        'role': 'member',
      };

      testWidgets('renders the pending-count badge on the Grupos tab icon '
          'when pending counts exist', (tester) async {
        await tester.pumpWidget(
          _localized(
            const MainShell(currentIndex: 0, child: SizedBox()),
            requests: received,
            invites: const [invite],
          ),
        );
        await tester.pumpAndSettle();

        final badge = tester.widget<VCountBadge>(find.byType(VCountBadge));
        expect(
          badge.count,
          3,
          reason: '2 received friend requests + 1 group invite (R18)',
        );
        final badgeContainer = tester.widget<Container>(
          find.descendant(
            of: find.byType(VCountBadge),
            matching: find.byType(Container),
          ),
        );
        expect(
          (badgeContainer.decoration! as BoxDecoration).color,
          AppColors.badgeRed,
          reason:
              '2026-08-27: the shell badge is a red circle (user directive)',
        );
        final badgeStack = find.ancestor(
          of: find.byType(VCountBadge),
          matching: find.byType(Stack),
        );
        expect(
          find.descendant(
            of: badgeStack,
            matching: find.byIcon(Icons.group_outlined),
          ),
          findsOneWidget,
          reason: 'the badge must ride the Grupos tab icon (R18)',
        );
      });

      testWidgets('hides the badge when the pending counts are zero', (
        tester,
      ) async {
        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 0, child: SizedBox())),
        );
        await tester.pumpAndSettle();

        expect(
          find.byType(VCountBadge),
          findsNothing,
          reason: 'no pending requests/invites → no shell badge (R18)',
        );
      });

      testWidgets('hides the badge while the Grupos tab is active', (
        tester,
      ) async {
        await tester.pumpWidget(
          _localized(
            const MainShell(currentIndex: 1, child: SizedBox()),
            requests: received,
            invites: const [invite],
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byType(VCountBadge),
          findsNothing,
          reason:
              'the badge disappears when the user is on the Grupos '
              'tab (R18 — Juega hides its feed badge the same way)',
        );
      });

      testWidgets('the badge count UPDATES when the pending data changes', (
        tester,
      ) async {
        final requests = _LiveFriendRequestsNotifier(received);
        final invites = _LiveGroupInvitesNotifier(const [invite]);
        final container = ProviderContainer(
          overrides: [
            friendRequestsProvider.overrideWith(() => requests),
            groupInvitesProvider.overrideWith(() => invites),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('es'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: _navTheme(),
              home: const MainShell(currentIndex: 0, child: SizedBox()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<VCountBadge>(find.byType(VCountBadge)).count,
          3,
          reason: '2 received + 1 invite → badge 3',
        );

        // A request gets accepted: the received list drops to 1 and an
        // invite is answered — the badge must re-derive 1 + 0.
        requests.data = const FriendRequestsData(
          requests: [
            FriendRequestSummary(type: 'received', friendshipId: 'f1', userId: 'u1'),
          ],
          names: {'u1': 'ana'},
        );
        invites.data = const [];
        container.refresh(friendRequestsProvider);
        container.refresh(groupInvitesProvider);
        await tester.pumpAndSettle();

        expect(
          tester.widget<VCountBadge>(find.byType(VCountBadge)).count,
          1,
          reason:
              'the badge count must follow the pending data live (U-28 '
              'badges-count-updates pin)',
        );
      });
    });

    group('R19 — shell tab fade honoring reduced motion (U-13 §5.4)', () {
      testWidgets('mounts a fade keyed on the tab index and completes it '
          'at 150ms', (tester) async {
        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 0, child: SizedBox())),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey(0)),
          findsOneWidget,
          reason: 'the fade is keyed on currentIndex (R19)',
        );

        await tester.pump(SamayDurations.fast);
        final fade = tester.widget<FadeTransition>(
          find.descendant(
            of: find.byKey(const ValueKey(0)),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(
          fade.opacity.value,
          1.0,
          reason: 'the fade completes at SamayDurations.fast (R19)',
        );
      });

      testWidgets('restarts the fade from zero when the tab switches', (
        tester,
      ) async {
        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 0, child: SizedBox())),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey(0)), findsOneWidget);

        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 1, child: SizedBox())),
        );
        await tester.pump();

        final fade = tester.widget<FadeTransition>(
          find.descendant(
            of: find.byKey(const ValueKey(1)),
            matching: find.byType(FadeTransition),
          ),
        );
        expect(
          fade.opacity.value,
          lessThan(1.0),
          reason: 'a tab switch restarts the fade from opacity 0 (R19)',
        );

        await tester.pump(SamayDurations.fast);
        expect(
          fade.opacity.value,
          1.0,
          reason: 'and it completes again at 150ms (R19)',
        );
      });

      testWidgets('is static (no fade) under disableAnimations', (
        tester,
      ) async {
        await tester.pumpWidget(
          _localized(
            const MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: MainShell(currentIndex: 0, child: Text('Shell body')),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byType(VTabFade),
          findsOneWidget,
          reason:
              'U-18: VTabFade is always mounted and gates reduced '
              'motion internally (R19)',
        );
        expect(
          tester.binding.transientCallbackCount,
          0,
          reason: 'reduced motion → the fade never ticks (R19/U-18)',
        );
        expect(
          find.text('Shell body'),
          findsOneWidget,
          reason: 'the body still renders statically',
        );
      });
    });

    group('R21 — settings stays pushed (U-13 §5.4 explicit keep)', () {
      test(
        'settings is NOT a shell tab and the tab order stays product-first',
        () {
          expect(
            mainShellTabs.map((t) => t.path).toList(),
            [
              RoutePaths.mainFeed,
              RoutePaths.mainGroups,
              RoutePaths.mainEvents,
              RoutePaths.mainNotifications,
              RoutePaths.mainProfile,
            ],
            reason:
                'product tabs only — settings must stay a pushed screen '
                '(R21, N6: no 6th tab)',
          );
          expect(
            mainShellTabs.map((t) => t.path),
            isNot(contains(RoutePaths.settings)),
          );
          expect(
            shellIndexFor(RoutePaths.settings),
            0,
            reason: 'settings resolves outside the shell — no tab slot (R21)',
          );
        },
      );
    });

    group('LUXE — glass shell restyle (XL-06)', () {
      testWidgets('the floating pill blurs what scrolls beneath it', (
        tester,
      ) async {
        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 0, child: SizedBox())),
        );

        // The pill is a BackdropFilter + translucent fill (Juega Premium
        // card port, 2026-08-27) — it blurs the content under the bar.
        expect(
          find.byType(BackdropFilter),
          findsWidgets,
          reason: 'the floating pill must blur what scrolls beneath it',
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null &&
                (w.decoration as BoxDecoration).color!.a < 1.0,
          ),
          findsWidgets,
          reason: 'the pill carries the translucent glass fill',
        );
      });

      testWidgets('no tab icon carries a glow — chrome is monochrome '
          '(2026-08-26)', (tester) async {
        await tester.pumpWidget(
          _localized(const MainShell(currentIndex: 1, child: SizedBox())),
        );

        List<BoxShadow> shadowsOf(IconData icon) {
          final boxes = tester
              .widgetList<DecoratedBox>(find.ancestor(
                of: find.byIcon(icon),
                matching: find.byType(DecoratedBox),
              ))
              .where(
                (b) =>
                    b.decoration is BoxDecoration &&
                    (b.decoration as BoxDecoration).boxShadow != null,
              )
              .toList();
          return boxes.isEmpty
              ? const []
              : (boxes.first.decoration as BoxDecoration).boxShadow!;
        }

        for (final tab in mainShellTabs) {
          expect(
            shadowsOf(tab.selectedIcon),
            isEmpty,
            reason: 'selected tab icons carry no halo (monochrome)',
          );
          expect(
            shadowsOf(tab.icon),
            isEmpty,
            reason: 'unselected tab icons must NOT glow',
          );
        }
      });
    });
  });
}
