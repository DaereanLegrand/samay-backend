import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/core/router/route_paths.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/glass/v_glass.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';
import 'package:samay/shared/widgets/v_display_text.dart';

MaterialApp _app({required Widget home}) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

void main() {
  group('VComingSoonScreen', () {
    testWidgets('renders title, headline and description', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      expect(find.text('Eventos'), findsOneWidget);
      expect(find.text('PR\u00d3XIMAMENTE'), findsOneWidget);
      expect(find.text('Descripcion de prueba'), findsOneWidget);
    });

    testWidgets('renders default icon', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      expect(find.byIcon(Icons.construction), findsOneWidget);
    });

    testWidgets('icon is xxl 48 in the family watered mid tone (§5.7 + '
        'XL-19 — pale chrome, never saturated)', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.construction));
      expect(icon.size, AppIconSizes.xxl);
      expect(
        icon.color,
        AppGradients.watered(AppGradients.violet.colors, mix: 0.4)[1],
        reason: 'XL-19: the icon defaults to the family watered mid tone — '
            'no flat saturated pastel',
      );
    });

    testWidgets('AppBar title is the clean theme utility title, not the '
        'Playfair headline (§5.7 — fancy only for "Próximamente")',
        (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Eventos'),
        ),
      );
      expect(title.style, isNull,
          reason: 'no inline style — the AppBar title comes from the theme');
      final themeTitle = Theme.of(
        tester.element(find.byType(AppBar)),
      ).textTheme.titleLarge;
      expect(themeTitle?.fontFamily, isNot('Playfair Display'));
      expect(themeTitle?.shadows, isNull);
    });

    testWidgets('a custom per-feature icon renders at xxl 48 in the family '
        'watered mid tone (§5.7 icon map + XL-19)', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
            icon: Icons.event,
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.event));
      expect(icon.size, AppIconSizes.xxl);
      expect(
        icon.color,
        AppGradients.watered(AppGradients.violet.colors, mix: 0.4)[1],
      );
    });

    testWidgets('iconColor allows the §5.7 faint glowPink hero option', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: VComingSoonScreen(
            title: 'Party Finder',
            description: 'Descripcion de prueba',
            icon: Icons.celebration,
            iconColor: AppColors.glowPink.withValues(alpha: 0.5),
          ),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(Icons.celebration));
      expect(icon.color, AppColors.glowPink.withValues(alpha: 0.5));
    });

    testWidgets('"PRÓXIMAMENTE" is the LUXE display voice — Playfair italic '
        '32 UPPERCASE on the violet family halo (default, never pink)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      final display = tester.widget<VDisplayText>(find.byType(VDisplayText));
      expect(display.text, 'Próximamente',
          reason: 'the MAYUS rule is enforced inside VDisplayText');
      expect(display.gradient, AppGradients.violet,
          reason: 'the default accent family is violet — never pink '
              '(2026-08-12 directive)');
      final text = tester.widget<Text>(find.text('PR\u00d3XIMAMENTE'));
      expect(text.style?.fontSize, 32);
      expect(text.style?.fontFamily, 'Playfair Display');
      expect(text.style?.fontStyle, FontStyle.italic);
      // LUXE directive (2026-08-12): NO external glow behind the glyphs —
      // the no-halo contract is pinned in v_display_text_test.
    });

    testWidgets('the family param re-accents the glass panel and headline', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
            family: AppGradients.cyan,
          ),
        ),
      );
      final display = tester.widget<VDisplayText>(find.byType(VDisplayText));
      // XL-19: the headline keeps the RAW family (the one brand moment) —
      // the glass ring + glow ride the watered run (mix 0.4).
      expect(display.gradient, AppGradients.cyan);
      final glass = tester.widget<VGlass>(find.byType(VGlass));
      expect(
        glass.gradient?.name,
        AppGradients.cyan.name,
        reason: 'the panel keeps the family name so chrome primitives '
            'resolve it unchanged',
      );
      expect(
        glass.gradient?.colors,
        AppGradients.watered(AppGradients.cyan.colors, mix: 0.4),
        reason: 'XL-19: pale chrome — the panel ring + glow ride the '
            'watered run (mix 0.4), not the raw vivid stops',
      );
      expect(
        glass.glowAlpha,
        0.22,
        reason: 'halo intensity unchanged — the muted stops carry the glow',
      );
    });

    testWidgets('description is bodyMedium in mutedStrong (§5.7)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Descripcion de prueba'));
      expect(text.style?.color, AppColors.mutedStrong);
      expect(text.style?.fontSize, 14);
    });

    testWidgets('shows Volver button and pops the navigator', (tester) async {
      await tester.pumpWidget(
        _app(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const VComingSoonScreen(
                    title: 'Eventos',
                    description: 'Descripcion de prueba',
                  ),
                ),
              ),
              child: const Text('Abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Volver'), findsOneWidget);
      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();
      expect(find.text('Abrir'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });

    testWidgets('hides Volver button when showBackButton is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
            showBackButton: false,
          ),
        ),
      );
      expect(find.text('Volver'), findsNothing);
    });

    testWidgets('Volver on a TAB-level coming-soon goes to the feed home '
        'instead of popping the last page (black-screen crash fix)', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: RoutePaths.mainEvents,
        routes: [
          GoRoute(
            path: RoutePaths.mainFeed,
            builder: (_, _) => const Scaffold(body: Text('FEED-LANDING')),
          ),
          // The flag-gated tab shape: /main/events renders a coming-soon
          // with NOTHING to pop (a bare Navigator.pop there throws
          // go_router's "popped the last page off of the stack").
          GoRoute(
            path: RoutePaths.mainEvents,
            builder: (_, _) => const VComingSoonScreen(
              title: 'Eventos',
              description: 'Descripcion de prueba',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(VComingSoonScreen), findsOneWidget);
      expect(find.text('Volver'), findsOneWidget);

      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RoutePaths.mainFeed,
      );
      expect(find.text('FEED-LANDING'), findsOneWidget);
      expect(find.byType(VComingSoonScreen), findsNothing);
    });
  });
}
