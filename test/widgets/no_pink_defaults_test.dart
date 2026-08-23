import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the "NO PINK MAINS" directive: pink is NOT the main color.
/// Shared widgets' accent defaults are the violet family (or the caller's
/// own `AppGradient` family); the pink tokens (glowPink) survive ONLY as the
/// error semantics inside the error widgets (AppColors.error aliases
/// glowPink) and as the rose family's vivid end inside app_gradients.dart.
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
              'pink must not appear in $path — the default accent '
              'family is violet (or the caller\'s AppGradient); error '
              'semantics keep glowPink only through AppColors.error in the '
              'error widgets',
        );
      });
    }
  });
}
