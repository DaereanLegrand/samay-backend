import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/router/main_shell.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/l10n/app_localizations.dart';

ThemeData _navTheme() {
  return ThemeData(
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      type: BottomNavigationBarType.fixed,
      showSelectedLabels: true,
      showUnselectedLabels: true,
    ),
  );
}

Widget _localized(Widget child) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: _navTheme(),
    home: child,
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
          GoRoute(path: RoutePaths.mainFeed, builder: (_, _) => const _StubScreen('Feed stub')),
          GoRoute(path: RoutePaths.mainGroups, builder: (_, _) => const _StubScreen('Groups stub')),
          GoRoute(path: RoutePaths.mainEvents, builder: (_, _) => const _StubScreen('Events stub')),
          GoRoute(path: RoutePaths.mainNotifications, builder: (_, _) => const _StubScreen('Notifications stub')),
          GoRoute(path: RoutePaths.mainProfile, builder: (_, _) => const _StubScreen('Profile stub')),
        ],
      ),
    ],
  );
}

MaterialApp _localizedRouter(GoRouter router) {
  return MaterialApp.router(
    routerConfig: router,
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
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
      expect(
        mainShellTabs.map((t) => t.label).toList(),
        ['Feed', 'Grupos', 'Eventos', 'Notis', 'Perfil'],
      );
    });

    test('keeps icons identical to the original shell', () {
      expect(
        mainShellTabs.map((t) => t.icon).toList(),
        [
          Icons.explore_outlined,
          Icons.group_outlined,
          Icons.event_outlined,
          Icons.notifications_outlined,
          Icons.person_outline,
        ],
      );
    });

    test('provides a distinct selected icon per tab', () {
      for (final tab in mainShellTabs) {
        expect(tab.selectedIcon, isNot(tab.icon));
      }
    });

    test('maps tabs to their RoutePaths in order', () {
      expect(
        mainShellTabs.map((t) => t.path).toList(),
        [
          RoutePaths.mainFeed,
          RoutePaths.mainGroups,
          RoutePaths.mainEvents,
          RoutePaths.mainNotifications,
          RoutePaths.mainProfile,
        ],
      );
    });
  });

  group('MainShell', () {
    testWidgets('renders the child and a BottomNavigationBar', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: Text('Shell body'))),
      );

      expect(find.text('Shell body'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });

    testWidgets('renders every tab icon', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: SizedBox())),
      );

      for (final tab in mainShellTabs) {
        expect(find.byIcon(tab.icon), findsOneWidget,
            reason: 'missing icon for tab ${tab.label}');
      }
    });

    testWidgets('renders every tab label', (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 0, child: SizedBox())),
      );

      for (final tab in mainShellTabs) {
        expect(find.text(tab.label), findsOneWidget,
            reason: 'missing label for tab ${tab.label}');
      }
    });

    testWidgets('exposes the current index to the BottomNavigationBar',
        (tester) async {
      await tester.pumpWidget(
        _localized(const MainShell(currentIndex: 3, child: SizedBox())),
      );

      final navBar =
          tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar));
      expect(navBar.currentIndex, 3);
    });

    testWidgets('tapping a tab navigates via context.go', (tester) async {
      final router = _stubRouter();
      await tester.pumpWidget(_localizedRouter(router));
      await tester.pumpAndSettle();

      expect(find.text('Feed stub'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.group_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Groups stub'), findsOneWidget);
      expect(find.text('Feed stub'), findsNothing);
      final navBar =
          tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar));
      expect(navBar.currentIndex, 1);
    });

    testWidgets('tapping each remaining tab lands on its screen',
        (tester) async {
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
        expect(find.text(expected), findsOneWidget,
            reason: 'tapping $icon should show $expected');
      }
    });
  });
}
