import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:yaml/yaml.dart';

/// Contract tests for the bundled font strategy (findings UI-08 / UI-10 /
/// DEP-10 / L-19).
///
/// The theme sets `fontFamily: 'Inter'` and the design system
/// (DESIGN.md §3) requires a second display family
/// ('Playfair Display'). Both must be declared in `pubspec.yaml` under
/// `flutter: fonts:` and their asset files must actually exist and be
/// non-trivial — otherwise devices fall back silently to system fonts.
void main() {
  const minFontBytes = 10240; // 10KB — real fonts are far larger; stubs are not.
  const expectedFamilies = <String>{'Inter', 'Playfair Display'};

  late YamlMap pubspec;

  setUpAll(() {
    final content = File('pubspec.yaml').readAsStringSync();
    pubspec = loadYaml(content) as YamlMap;
  });

  List<YamlMap> declaredFamilies() {
    final flutter = pubspec['flutter'] as YamlMap?;
    final fonts = flutter?['fonts'] as YamlList?;
    if (fonts == null) return const [];
    return fonts.whereType<YamlMap>().toList();
  }

  Set<String> declaredFamilyNames() =>
      declaredFamilies().map((f) => f['family'] as String).toSet();

  group('pubspec font declarations (UI-08 / DEP-10 / L-19)', () {
    test('declares both brand families under flutter: fonts:', () {
      expect(
        declaredFamilyNames(),
        containsAll(expectedFamilies),
        reason: 'Theme sets fontFamily Inter; the design doc requires '
            'Playfair Display for display titles. Missing families prevent '
            'deterministic rendering.',
      );
    });

    test('Inter family ships a normal-style asset', () {
      final inter = declaredFamilies().firstWhere(
        (f) => f['family'] == 'Inter',
      );
      final assets = (inter['fonts'] as YamlList).whereType<YamlMap>();
      expect(
        assets.any((a) => a['style'] == null),
        isTrue,
        reason: 'Inter needs a regular (non-italic) asset so the default '
            'theme fontFamily resolves.',
      );
    });

    test('Playfair Display family ships normal and italic assets', () {
      final playfair = declaredFamilies().firstWhere(
        (f) => f['family'] == 'Playfair Display',
      );
      final assets = (playfair['fonts'] as YamlList).whereType<YamlMap>().toList();
      expect(
        assets.any((a) => a['style'] == null),
        isTrue,
        reason: 'Playfair Display needs a regular asset.',
      );
      expect(
        assets.any((a) => a['style'] == 'italic'),
        isTrue,
        reason: 'DESIGN.md §3.2 requires Playfair Display '
            'italic 700 for display titles — an italic asset must exist.',
      );
    });

    test('every declared font asset exists on disk', () {
      for (final family in declaredFamilies()) {
        final assets = (family['fonts'] as YamlList).whereType<YamlMap>();
        for (final asset in assets) {
          final path = asset['asset'] as String;
          expect(
            File(path).existsSync(),
            isTrue,
            reason: 'Family ${family['family']} declares "$path" but the '
                'file is missing.',
          );
        }
      }
    });

    test('every declared font asset is non-trivial (>10KB)', () {
      for (final family in declaredFamilies()) {
        final assets = (family['fonts'] as YamlList).whereType<YamlMap>();
        for (final asset in assets) {
          final path = asset['asset'] as String;
          final size = File(path).lengthSync();
          expect(
            size,
            greaterThan(minFontBytes),
            reason: 'Family ${family['family']} asset "$path" is only '
                '$size bytes — a real TrueType font is far larger.',
          );
        }
      }
    });
  });

  group('theme resolves fontFamily strings to declared families', () {
    test('the default theme family (Inter) is a declared family', () {
      final families = declaredFamilyNames();
      final theme = SamayTheme.dark;
      // ThemeData applies its fontFamily into every textTheme style at
      // construction, so bodyMedium is a reliable probe of the theme's
      // default family (there is no ThemeData.fontFamily getter).
      final defaultFamily = theme.textTheme.bodyMedium?.fontFamily;
      expect(defaultFamily, isNotNull);
      expect(
        families,
        contains(defaultFamily),
        reason: 'Theme default family "$defaultFamily" is not declared in '
            'pubspec.yaml — devices would fall back to a system font.',
      );
    });

    test('every non-null TextTheme fontFamily is a declared family', () {
      final theme = SamayTheme.dark;
      final families = declaredFamilyNames();
      final styles = <TextStyle?>[
        theme.textTheme.displayLarge,
        theme.textTheme.displayMedium,
        theme.textTheme.displaySmall,
        theme.textTheme.headlineLarge,
        theme.textTheme.headlineMedium,
        theme.textTheme.headlineSmall,
        theme.textTheme.titleLarge,
        theme.textTheme.titleMedium,
        theme.textTheme.titleSmall,
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.textTheme.labelMedium,
        theme.textTheme.labelSmall,
      ];
      for (final style in styles) {
        final family = style?.fontFamily;
        if (family == null) continue;
        expect(
          families,
          contains(family),
          reason: 'TextStyle family "$family" is not declared in pubspec.yaml.',
        );
      }
    });

    test('displayLarge resolves to Playfair Display, body to Inter', () {
      final theme = SamayTheme.dark;
      expect(theme.textTheme.displayLarge?.fontFamily, 'Playfair Display');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
    });
  });

  group('bundled fonts render in widget tests', () {
    testWidgets('Inter and Playfair Display texts render without errors',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SamayTheme.dark,
          home: const Scaffold(
            body: Column(
              children: [
                Text(
                  'Inter',
                  style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w300),
                ),
                Text(
                  'Playfair',
                  style: TextStyle(
                    fontFamily: 'Playfair Display',
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Inter'), findsOneWidget);
      expect(find.text('Playfair'), findsOneWidget);
    });
  });
}
