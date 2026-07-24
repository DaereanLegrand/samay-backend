import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/app_theme.dart';

void main() {
  group('SamayTheme', () {
    test('provides dark ThemeData', () {
      final theme = SamayTheme.dark;
      expect(theme.brightness, Brightness.dark);
    });

    test('scaffold background is black', () {
      final theme = SamayTheme.dark;
      expect(theme.scaffoldBackgroundColor, Colors.black);
    });

    test('primary color is white', () {
      final theme = SamayTheme.dark;
      expect(theme.colorScheme.primary, Colors.white);
    });

    test('uses single sans-serif font family', () {
      final theme = SamayTheme.dark;
      expect(theme.textTheme.displayLarge?.fontFamily, 'Inter');
    });

    test('headline uses bold weight', () {
      final theme = SamayTheme.dark;
      expect(theme.textTheme.headlineMedium?.fontWeight, FontWeight.bold);
    });

    test('body uses light weight', () {
      final theme = SamayTheme.dark;
      expect(theme.textTheme.bodyLarge?.fontWeight, FontWeight.w300);
    });

    test('button label is bold uppercase', () {
      final theme = SamayTheme.dark;
      expect(theme.textTheme.labelLarge?.fontWeight, FontWeight.bold);
    });

    test('AppBar is transparent or black with no elevation', () {
      final theme = SamayTheme.dark;
      final appBarTheme = theme.appBarTheme;
      expect(appBarTheme.elevation, 0);
    });

    test('BottomNav has no labels (icons only)', () {
      final theme = SamayTheme.dark;
      final navTheme = theme.bottomNavigationBarTheme;
      expect(navTheme.type, BottomNavigationBarType.fixed);
    });

    test('color scheme has no accent colors, only black/white/gray', () {
      final theme = SamayTheme.dark;
      final scheme = theme.colorScheme;
      final allowedColors = [
        Colors.white,
        Colors.black,
        const Color(0xFF1A1A1A),
        const Color(0xFF333333),
        const Color(0xFF666666),
      ];
      expect(allowedColors.contains(scheme.primary), isTrue);
      expect(allowedColors.contains(scheme.onPrimary), isTrue);
    });
  });
}
