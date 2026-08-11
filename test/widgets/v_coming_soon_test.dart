import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_icon_sizes.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_coming_soon.dart';

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
      expect(find.text('Pr\u00f3ximamente'), findsOneWidget);
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

    testWidgets('icon is xxl 48 in border #333333 (§5.7)', (tester) async {
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
      expect(icon.color, AppColors.border);
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

    testWidgets('a custom per-feature icon renders at xxl 48 in border '
        '#333333 (§5.7 icon map)', (tester) async {
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
      expect(icon.color, AppColors.border);
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

    testWidgets('"Próximamente" is Playfair Display italic 32 with the soft '
        'glow stack (§5.7)', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const VComingSoonScreen(
            title: 'Eventos',
            description: 'Descripcion de prueba',
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('Pr\u00f3ximamente'));
      expect(text.style?.fontSize, 32);
      expect(text.style?.fontFamily, 'Playfair Display');
      expect(text.style?.fontStyle, FontStyle.italic);
      expect(text.style?.shadows, isNotEmpty);
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
  });
}
