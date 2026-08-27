import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_button.dart';
import 'package:samay/shared/widgets/v_card.dart';
import 'package:samay/shared/widgets/v_chip.dart';
import 'package:samay/shared/widgets/v_display_text.dart';
import 'package:samay/shared/widgets/v_status_dot.dart';

/// Render smoke for the canonical shared widgets.
///
/// Replaces the deleted `*_restyle_test.dart` files (token-budget decision,
/// 2026-08-27): exact visual values (BoxDecoration.shape, color-token
/// equality, fontSize) are pinned once in `test/design_tokens/` +
/// `test/theme/app_theme_test.dart` + each widget's own behavioral test in
/// `test/widgets/`. This file only proves every canonical widget builds
/// through [SamayTheme.dark] without throwing — a cheap canary that keeps
/// the theme contract from silently breaking widget composition.
Widget _wrap(Widget child) {
  return MaterialApp(
    theme: SamayTheme.dark,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('canonical widgets render through SamayTheme.dark', () {
    testWidgets('VCard', (tester) async {
      await tester.pumpWidget(_wrap(const VCard(child: Text('card'))));
      expect(find.text('card'), findsOneWidget);
    });

    testWidgets('VButton', (tester) async {
      await tester.pumpWidget(
        _wrap(VButton(label: 'action', onPressed: () {})),
      );
      expect(find.text('action'), findsOneWidget);
    });

    testWidgets('VButton.loading', (tester) async {
      await tester.pumpWidget(
        _wrap(VButton(label: 'action', onPressed: () {}, loading: true)),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('VBadge', (tester) async {
      await tester.pumpWidget(_wrap(const VBadge(label: 'NEW')));
      expect(find.text('NEW'), findsOneWidget);
    });

    testWidgets('VBadge.emphasized', (tester) async {
      await tester.pumpWidget(_wrap(const VBadge.emphasized(label: 'NEW')));
      expect(find.text('NEW'), findsOneWidget);
    });

    testWidgets('VChip', (tester) async {
      await tester.pumpWidget(_wrap(const VChip(label: 'chip')));
      expect(find.text('chip'), findsOneWidget);
    });

    testWidgets('VDisplayText', (tester) async {
      await tester.pumpWidget(_wrap(const VDisplayText(text: 'samay')));
      expect(find.text('samay'), findsOneWidget);
    });

    testWidgets('VStatusDot', (tester) async {
      await tester.pumpWidget(_wrap(const VStatusDot()));
      expect(find.byType(VStatusDot), findsOneWidget);
    });
  });
}
