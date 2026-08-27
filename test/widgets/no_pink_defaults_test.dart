import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the monochrome directive (2026-08-26): pink is NOT a UI color.
/// Shared widgets never reference the glowPink tokens; pink survives ONLY as
/// the error semantics (`AppColors.error` aliases glowPink) inside the error
/// widgets and error-text call sites.
void main() {
  final root = Directory.current.path;

  group('no pink mains in shared-widget defaults', () {
    for (final path in const [
      'lib/shared/widgets/v_button.dart',
      'lib/shared/widgets/v_badge.dart',
      'lib/shared/widgets/v_chip.dart',
      'lib/shared/widgets/v_count_badge.dart',
      'lib/shared/widgets/v_disco_divider.dart',
    ]) {
      test('$path never references the pink tokens', () {
        final source = File('$root/$path').readAsStringSync();
        expect(
          source,
          isNot(contains('glowPink')),
          reason:
              'pink must not appear in $path — shared widgets are '
              'monochrome (white/black/grey); error semantics keep '
              'glowPink only through AppColors.error in the error widgets',
        );
      });
    }
  });
}
