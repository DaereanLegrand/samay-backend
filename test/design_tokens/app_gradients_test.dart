import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';

/// Contract tests for the LUXE pastel-gradient token layer
/// (ORCHESTRATION-LUXE.md §"Gradient family → screen map" +
/// §"Foundation API contract (XL-01 implements EXACTLY this)").
///
/// Every family is a 3-stop `pastel → mid → vivid` run ("watered down with
/// white"), the `familyOf` map mirrors the doc table 1:1, and the glow/text
/// helpers are the primitives XL-02..XL-13 compose (VGlass, VGradientText,
/// VAurora, ...).
void main() {
  // ── Doc table (ORCHESTRATION-LUXE.md, verbatim) ────────────────────────
  const roseColors = <Color>[
    Color(0xFFFFD6E8),
    Color(0xFFFF8AC2),
    Color(0xFFFF2E88),
  ];
  const violetColors = <Color>[
    Color(0xFFE3D9FF),
    Color(0xFFB79CFF),
    Color(0xFF8B5CF6),
  ];
  const cyanColors = <Color>[
    Color(0xFFD6F7FF),
    Color(0xFF7FE9FF),
    Color(0xFF00E5FF),
  ];
  const goldColors = <Color>[
    Color(0xFFFFF3D6),
    Color(0xFFFFDF99),
    Color(0xFFFFC94D),
  ];
  const mintColors = <Color>[
    Color(0xFFD8FFEE),
    Color(0xFF8BFFD9),
    Color(0xFF37E6A5),
  ];
  const peachColors = <Color>[
    Color(0xFFFFE6D9),
    Color(0xFFFFC09E),
    Color(0xFFFF8A65),
  ];
  const families = <(String, AppGradient, List<Color>)>[
    ('rose', AppGradients.rose, roseColors),
    ('violet', AppGradients.violet, violetColors),
    ('cyan', AppGradients.cyan, cyanColors),
    ('gold', AppGradients.gold, goldColors),
    ('mint', AppGradients.mint, mintColors),
    ('peach', AppGradients.peach, peachColors),
  ];

  group('AppGradient families (ORCHESTRATION-LUXE family map)', () {
    for (final (name, gradient, expected) in families) {
      test('$name carries its name, exact 3 pastel→vivid stops', () {
        expect(gradient.name, name, reason: '$name family name');
        expect(gradient.colors, hasLength(3), reason: '$name stop count');
        expect(gradient.stops, hasLength(3), reason: '$name stop count');
        expect(gradient.stops, [0.0, 0.5, 1.0], reason: '$name stops');
        for (var i = 0; i < expected.length; i++) {
          expect(gradient.colors[i], expected[i],
              reason: '$name stop $i must be ${expected[i]}');
        }
      });
    }
  });

  group('AppGradients.all registry', () {
    test('registers exactly the 6 families by name', () {
      expect(AppGradients.all.keys.toSet(), {
        'rose',
        'violet',
        'cyan',
        'gold',
        'mint',
        'peach',
      });
    });

    test('every entry is the canonical const family instance', () {
      for (final (name, gradient, _) in families) {
        expect(AppGradients.all[name], gradient,
            reason: 'all["$name"] must be the $name const');
        expect(identical(AppGradients.all[name], gradient), isTrue,
            reason: 'all["$name"] must be canonical (identical instance)');
      }
    });

    test('families are const-constructible and canonical', () {
      const rose = AppGradients.rose;
      const mint = AppGradients.mint;
      expect(identical(rose, AppGradients.rose), isTrue);
      expect(identical(mint, AppGradients.mint), isTrue);
      expect(rose.name, 'rose');
      expect(mint.name, 'mint');
    });

    test('vivid ends that exist in the palette alias the AppColors tokens',
        () {
      expect(AppGradients.rose.colors[2], AppColors.glowPink);
      expect(AppGradients.violet.colors[2], AppColors.discoViolet);
      expect(AppGradients.cyan.colors[2], AppColors.discoCyan);
      expect(AppGradients.gold.colors[2], AppColors.discoGold);
      expect(AppGradients.mint.colors[2], AppColors.mint);
      expect(AppGradients.peach.colors[2], AppColors.peach);
      expect(AppGradients.rose.colors[0], AppColors.pastelRose);
      expect(AppGradients.mint.colors[0], AppColors.pastelMint);
      expect(AppGradients.peach.colors[0], AppColors.pastelPeach);
    });
  });

  group('AppGradients.familyOf (screen → family map)', () {
    const screenMap = <String, AppGradient>{
      'welcome': AppGradients.violet,
      'signup': AppGradients.violet,
      'profile_setup': AppGradients.violet,
      'qr': AppGradients.violet,
      'login': AppGradients.cyan,
      'feed': AppGradients.cyan,
      'party_finder': AppGradients.cyan,
      'age_gate': AppGradients.violet,
      'groups': AppGradients.violet,
      'cosmetics': AppGradients.violet,
      'minigames': AppGradients.peach,
      'banned': AppGradients.mint,
      'otp': AppGradients.gold,
      'notifications': AppGradients.gold,
      'profile': AppGradients.gold,
      'shards': AppGradients.gold,
      'paywall': AppGradients.gold,
      'privacy_terms': AppGradients.mint,
      'friends': AppGradients.mint,
      'photos': AppGradients.mint,
      'forgot_password': AppGradients.peach,
      'chat': AppGradients.peach,
      'events': AppGradients.peach,
    };

    test('every screen key maps to its documented family', () {
      for (final entry in screenMap.entries) {
        expect(AppGradients.familyOf(entry.key), entry.value,
            reason: '${entry.key} must map to ${entry.value.name}');
      }
    });

    test('no screen key maps to rose — pink is NOT a main color', () {
      for (final entry in screenMap.entries) {
        expect(entry.value, isNot(AppGradients.rose),
            reason: '${entry.key} must not be pink (user directive)');
      }
    });

    test('unknown or empty keys fall back to violet (default family)', () {
      expect(AppGradients.familyOf('unknown_screen'), AppGradients.violet);
      expect(AppGradients.familyOf(''), AppGradients.violet);
      expect(AppGradients.familyOf('Feed'), AppGradients.violet,
          reason: 'keys are case-sensitive doc slugs — no silent coercion');
    });
  });

  group('AppGradient.linear / .radial (gradient primitives)', () {
    test('linear exposes the family colors/stops with doc default direction',
        () {
      final linear = AppGradients.rose.linear();
      expect(linear.colors, AppGradients.rose.colors);
      expect(linear.stops, [0.0, 0.5, 1.0]);
      expect(linear.begin, Alignment.topLeft);
      expect(linear.end, Alignment.bottomRight);
    });

    test('linear accepts a rotated begin/end pair', () {
      final linear = AppGradients.cyan.linear(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
      );
      expect(linear.begin, Alignment.bottomLeft);
      expect(linear.end, Alignment.topRight);
    });

    test('radial exposes the family colors/stops centered by default', () {
      final radial = AppGradients.violet.radial();
      expect(radial.colors, AppGradients.violet.colors);
      expect(radial.stops, [0.0, 0.5, 1.0]);
      expect(radial.center, Alignment.center);
    });

    test('radial accepts an off-center alignment (aurora blob anchors)', () {
      final radial = AppGradients.gold.radial(center: Alignment.topLeft);
      expect(radial.center, Alignment.topLeft);
    });
  });

  group('AppGradients.glowShadows (3-layer halo stack)', () {
    test('returns 3 zero-offset shadows with increasing blur, decreasing '
        'alpha', () {
      final shadows = AppGradients.glowShadows(AppGradients.rose);
      expect(shadows, hasLength(3));

      expect(shadows[0].color,
          AppGradients.rose.colors[1].withValues(alpha: 0.35));
      expect(shadows[0].blurRadius, 48);
      expect(shadows[0].offset, Offset.zero);

      expect(shadows[1].color,
          AppGradients.rose.colors[2].withValues(alpha: 0.35 * 0.6));
      expect(shadows[1].blurRadius, 48 * 2);

      expect(shadows[2].color,
          AppGradients.rose.colors[2].withValues(alpha: 0.35 * 0.3));
      expect(shadows[2].blurRadius, closeTo(48 * 3.5, 0.001));

      for (var i = 0; i < 3; i++) {
        expect(shadows[i].offset, Offset.zero, reason: 'layer $i offset');
        if (i > 0) {
          expect(shadows[i].blurRadius, greaterThan(shadows[i - 1].blurRadius),
              reason: 'blur must grow outward');
          expect(shadows[i].color.a, lessThan(shadows[i - 1].color.a),
              reason: 'alpha must fade outward');
        }
      }
    });

    test('alpha and blur parameters scale the whole stack', () {
      final shadows = AppGradients.glowShadows(
        AppGradients.peach,
        alpha: 0.5,
        blur: 24,
      );
      expect(shadows[0].color,
          AppGradients.peach.colors[1].withValues(alpha: 0.5));
      expect(shadows[0].blurRadius, 24);
      expect(shadows[1].color,
          AppGradients.peach.colors[2].withValues(alpha: 0.5 * 0.6));
      expect(shadows[1].blurRadius, 48);
      expect(shadows[2].blurRadius, closeTo(24 * 3.5, 0.001));
    });

    test('works for every family (mid/vivid colors per family)', () {
      for (final (name, gradient, _) in families) {
        final shadows = AppGradients.glowShadows(gradient);
        expect(shadows[0].color, gradient.colors[1].withValues(alpha: 0.35),
            reason: '$name halo = mid stop');
        expect(shadows[2].color,
            gradient.colors[2].withValues(alpha: 0.35 * 0.3),
            reason: '$name outer halo = vivid stop');
      }
    });
  });

  group('AppGradients.textShader (ShaderMask fill)', () {
    test('returns a usable Shader for a text bounds rect', () {
      const bounds = Rect.fromLTWH(0, 0, 200, 48);
      final shader = AppGradients.textShader(AppGradients.rose, bounds);
      expect(shader, isNotNull);
      expect(shader, isA<Shader>());
    });

    test('shader bounds come from the caller-provided rect', () {
      const wide = Rect.fromLTWH(0, 0, 320, 64);
      const tall = Rect.fromLTWH(0, 0, 64, 320);
      final wideShader = AppGradients.textShader(AppGradients.cyan, wide);
      final tallShader = AppGradients.textShader(AppGradients.cyan, tall);
      expect(wideShader, isNotNull);
      expect(tallShader, isNotNull);
    });
  });

  group('AppGradients.watered (white-mix toward pastel)', () {
    const vividBase = <Color>[
      Color(0xFFFF2E88),
      Color(0xFF00E5FF),
      Color(0xFF8B5CF6),
    ];

    test('default mix 0.6 lerps every color toward white', () {
      final watered = AppGradients.watered(vividBase);
      expect(watered, hasLength(vividBase.length));
      for (var i = 0; i < vividBase.length; i++) {
        expect(watered[i], Color.lerp(vividBase[i], AppColors.white, 0.6),
            reason: 'stop $i must equal lerp(base, white, 0.6)');
      }
    });

    test('result differs from the base and is closer to white', () {
      double distanceToWhite(Color c) =>
          (1.0 - c.r).abs() + (1.0 - c.g).abs() + (1.0 - c.b).abs();
      final watered = AppGradients.watered(vividBase);
      for (var i = 0; i < vividBase.length; i++) {
        final base = vividBase[i];
        final result = watered[i];
        expect(result, isNot(base), reason: 'stop $i must change');
        for (final channel in [result.r, result.g, result.b]) {
          expect(channel, greaterThanOrEqualTo(0.6),
              reason: 'stop $i: a 0.6 white-mix keeps every channel >= 0.6');
        }
        // Every channel either stays at 1.0 or moves toward it, and at least
        // one moves — so the summed distance to white strictly shrinks.
        expect(distanceToWhite(result), lessThan(distanceToWhite(base)),
            reason: 'stop $i must be closer to white');
      }
    });

    test('mix 0 keeps the base, mix 1 yields pure white', () {
      expect(AppGradients.watered(vividBase, mix: 0.0), vividBase);
      for (final color in AppGradients.watered(vividBase, mix: 1.0)) {
        expect(color, AppColors.white);
      }
    });
  });
}
