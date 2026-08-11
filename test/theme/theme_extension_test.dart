import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/extensions/context_extensions.dart';
import 'package:samay/core/theme/app_theme.dart';

Widget _appWithExtension(Widget child) {
  return MaterialApp(
    theme: ThemeData(extensions: [SamayThemeExtension.dark]),
    home: child,
  );
}

void main() {
  group('SamayThemeExtension', () {
    test('exposes the full palette as const fields', () {
      const ext = SamayThemeExtension.dark;
      expect(ext.discoBlack, AppColors.discoBlack);
      expect(ext.surface, AppColors.surface);
      expect(ext.surfaceAlt, AppColors.surfaceAlt);
      expect(ext.hairline, AppColors.hairline);
      expect(ext.border, AppColors.border);
      expect(ext.muted, AppColors.muted);
      expect(ext.mutedStrong, AppColors.mutedStrong);
      expect(ext.white, AppColors.white);
      expect(ext.glowPink, AppColors.glowPink);
      expect(ext.glowPinkBright, AppColors.glowPinkBright);
      expect(ext.glowPinkDeep, AppColors.glowPinkDeep);
      expect(ext.discoViolet, AppColors.discoViolet);
      expect(ext.discoCyan, AppColors.discoCyan);
      expect(ext.discoGold, AppColors.discoGold);
      expect(ext.discoSilver, AppColors.discoSilver);
      expect(ext.discoBronze, AppColors.discoBronze);
    });

    test('copyWith returns a new instance with only the given fields changed',
        () {
      const ext = SamayThemeExtension.dark;
      final changed = ext.copyWith(glowPink: AppColors.white);
      expect(changed.glowPink, AppColors.white);
      expect(changed.discoBlack, AppColors.discoBlack,
          reason: 'unchanged fields are preserved');
      expect(identical(changed, ext), isFalse);
    });

    test('lerp at t=0 returns this, at t=1 returns other', () {
      const a = SamayThemeExtension.dark;
      const b = SamayThemeExtension.dark;
      expect(a.lerp(b, 0).glowPink, a.glowPink);
      expect(a.lerp(b, 1).glowPink, b.glowPink);
    });

    test('lerp with a null other returns this (ThemeExtension contract)', () {
      const a = SamayThemeExtension.dark;
      expect(identical(a.lerp(null, 0.5), a), isTrue);
    });
  });

  group('Theme.of(context).extension<SamayThemeExtension>()', () {
    testWidgets('resolves the extension registered in ThemeData',
        (tester) async {
      await tester.pumpWidget(
        _appWithExtension(const SizedBox()),
      );
      final context = tester.element(find.byType(SizedBox));
      final ext = Theme.of(context).extension<SamayThemeExtension>();
      expect(ext, isNotNull);
      expect(ext!.glowPink, AppColors.glowPink);
      expect(ext.discoGold, AppColors.discoGold);
    });

    testWidgets('returns null when the extension is not registered',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      expect(Theme.of(context).extension<SamayThemeExtension>(), isNull);
    });
  });

  group('context.samayColors convenience', () {
    // Canonical home for the context resolution pins (U-27 consolidation —
    // the duplicated group in app_colors_test.dart was merged here).
    testWidgets('returns the registered extension', (tester) async {
      await tester.pumpWidget(
        _appWithExtension(const SizedBox()),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(context.samayColors.glowPink, AppColors.glowPink);
      expect(context.samayColors.discoCyan, AppColors.discoCyan);
      expect(context.samayColors.discoViolet, AppColors.discoViolet);
      expect(context.samayColors.discoGold, AppColors.discoGold);
    });

    testWidgets('falls back to the dark palette when unregistered',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      expect(context.samayColors.glowPink, AppColors.glowPink);
      expect(context.samayColors.white, AppColors.white);
    });
  });

  group('context.textTheme / colorScheme / isDark (UI-07)', () {
    testWidgets('textTheme resolves the ambient TextTheme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            textTheme: const TextTheme(
              bodyLarge: TextStyle(fontSize: 20),
            ),
          ),
          home: const SizedBox(),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(context.textTheme.bodyLarge?.fontSize, 20);
    });

    testWidgets('colorScheme resolves the ambient ColorScheme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: AppColors.glowPink),
          ),
          home: const SizedBox(),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(context.colorScheme.primary, isNotNull);
      expect(context.colorScheme.primary, isA<Color>());
    });

    testWidgets('isDark is true under SamayTheme.dark', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SamayTheme.dark,
          home: const SizedBox(),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(context.isDark, isTrue);
    });

    testWidgets('isDark is false under a light theme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: const SizedBox(),
        ),
      );
      final context = tester.element(find.byType(SizedBox));
      expect(context.isDark, isFalse);
    });
  });
}
