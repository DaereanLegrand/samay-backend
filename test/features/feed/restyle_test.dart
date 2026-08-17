import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/config/feature_flags.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_gradients.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/glass/glass.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_chip.dart';
import 'package:samay/shared/widgets/v_display_text.dart';
import 'package:samay/shared/widgets/v_disco_divider.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/fake_config_provider.dart';

/// Feed-restyle ledger tests (LUXE v2, XL-07 — ORCHESTRATION-LUXE.md).
///
/// The feed is **restyled, not redesigned**: the provider/behavior contract
/// and the interaction tests of `feed_test.dart` stay the authoritative
/// assertions for data + flow (all unchanged and green). This file pins the
/// *deliberate visual changes* from the LUXE ledger only:
///
/// 1. The 'SAMAY' brand hero renders through [VDisplayText] (Playfair
///    Display bold UPPERCASE — directive #6, the MAYUS rule is enforced by
///    the widget, never at call sites; no italics — user directive
///    2026-08-14) with **white glyphs** (the cyan family is banned on
///    glyphs — skyblue text must be white, user directive 2026-08-14).
/// 2. Always-black background (directive #1/#4; the feed's own family
///    from `AppGradients.familyOf('feed')`).
/// 3. Section separators use [VDiscoDivider] with the **cyan vivid end at
///    α0.5** accent (LUXE feed tint — never pink, never violet): header →
///    content always when events exist, plus featured → list when both
///    sections exist.
/// 4. The featured card is liquid glass ([VGlass], sharp, cyan ring +
///    soft glow) and its badge is the `VBadge.accent` **cyan family**
///    variant ('DESTACADO' — NO PINK MAINS directive).
/// 5. Event cards are sharp hairline [VGlassCard]s (cyan ring, no glow —
///    glow is reserved for the featured carousel) with [VNetworkImage]
///    covers, default [VBadge] type badges (§5.5) and `mutedStrong`
///    metadata (§2.4).
/// 6. Radius chips are `VChip.accent` in the cyan family (vivid cyan
///    border/label; vivid fill when selected — the chip row of the LUXE
///    feed).
class _FakeEventService implements EventService {
  _FakeEventService(this.rows);

  final List<Event> rows;

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createEvent(Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<Event> getEvent(String id) =>
      throw UnimplementedError();

  @override
  Future<Event?> getEventByInviteToken(String token) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyQrToken(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> rotateQrToken(String eventId) async => null;

  @override
  Future<List<Map<String, dynamic>>> getEventPromotores(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyEventInvite(String eventId) =>
      throw UnimplementedError();

  @override
  Future<List<Event>> listEvents([
    String? status,
    String? type,
  ]) async {
    return List.of(rows);
  }

  @override
  Future<void> likePhoto(String photoId) => throw UnimplementedError();

  @override
  Future<void> unlikePhoto(String photoId) => throw UnimplementedError();

  @override
  Future<List<String>> getMyPhotoLikes(String eventId) =>
      throw UnimplementedError();

  @override
  Future<void> updateEvent(String id, Map<String, dynamic> patch) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> validateQrToken(String eventId, String token) =>
      throw UnimplementedError();
}

Event _eventRow(
  String id, {
  String name = 'Fiesta',
  String type = 'juerga',
  DateTime? startsAt,
  String? locationName,
  String? coverUrl,
  bool featured = false,
}) {
  final start = startsAt ?? DateTime(2026, 9, 15, 22);
  return Event(
    id: id,
    name: name,
    type: type,
    status: 'upcoming',
    locationName: locationName,
    coverUrl: coverUrl,
    featured: featured,
    startsAt: start,
    endsAt: start.add(const Duration(hours: 4)),
  );
}

/// Pumps the real [FeedScreen] under the Samay disco theme (the app's only
/// theme — `lib/app.dart`), with the in-memory fake service + config.
Future<void> _pumpScreen(WidgetTester tester, _FakeEventService service) async {
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(service),
      appConfigProvider.overrideWith(() => FakeAppConfigNotifier(const {})),
      // Plugged home (2026-08-13): the games/party-finder sections are
      // covered by test/features/plugged_entries_test.dart — this suite
      // pins the feed's event layout, so the quick-access sections are
      // switched off here.
      featureFlagsProvider.overrideWithValue(
        const AppFeatureFlags(minigames: false, partyFinder: false),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SamayTheme.dark,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const FeedScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Feed hero — VDisplayText brand header (LUXE #6/#8)', () {
    testWidgets("the 'Samay' hero renders through VDisplayText — cyan "
        'gradient, glow-strong halo, MAYUS enforced', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      final display = tester.widget<VDisplayText>(find.byType(VDisplayText));
      expect(display.text, 'Samay');
      expect(
        display.gradient,
        AppGradients.cyan,
        reason: 'the feed owns the cyan family — never pink/violet',
      );
      // LUXE directive (2026-08-12): NO external glow behind the glyphs
      // (the no-halo contract is pinned in v_display_text_test).

      // Directive #6: MAYUS is enforced by VDisplayText, not call sites.
      expect(find.text('SAMAY'), findsOneWidget);
      expect(
        find.text('Samay'),
        findsNothing,
        reason: 'the display voice is Playfair ONLY in MAYUS',
      );
      final text = tester.widget<Text>(find.text('SAMAY'));
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontWeight, FontWeight.w700);
      expect(
        text.style?.fontStyle,
        isNull,
        reason: 'no italics — user directive 2026-08-14',
      );
    });
  });

  group('Ambient — always-black Scaffold (LUXE #1/#4)', () {
    testWidgets('the feed renders over a black Scaffold', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        scaffold.backgroundColor,
        AppColors.discoBlack,
        reason: 'black background always (directive #1)',
      );
    });
  });

  group('Section separators — VDiscoDivider with the cyan tint (LUXE)', () {
    testWidgets('renders a divider below the header and another between '
        'featured and the list when both sections exist', (tester) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow('e-feat', featured: true),
          _eventRow('e-plain'),
        ]),
      );

      final dividers = tester
          .widgetList<VDiscoDivider>(find.byType(VDiscoDivider))
          .toList();
      expect(dividers, hasLength(2));
      for (final divider in dividers) {
        expect(
          divider.accentColor,
          AppColors.discoCyan.withValues(alpha: 0.5),
          reason:
              'LUXE feed divider accent: cyan vivid end at α0.5 — '
              'never pink, never the violet default',
        );
      }
    });

    testWidgets('renders a single cyan divider below the header when there '
        'is no featured section', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      final divider = tester.widget<VDiscoDivider>(find.byType(VDiscoDivider));
      expect(divider.accentColor, AppColors.discoCyan.withValues(alpha: 0.5));
    });
  });

  group('Featured card — cyan liquid glass + cyan accent badge (LUXE)', () {
    testWidgets('the featured card is sharp VGlass with the cyan ring and '
        'the soft pastel glow (the event of the night)', (tester) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow('e-feat', name: 'Tono Destacado', featured: true),
        ]),
      );

      final glass = tester.widget<VGlass>(
        find.ancestor(
          of: find.text('Tono Destacado'),
          matching: find.byType(VGlass),
        ),
      );
      expect(glass.gradient, AppGradients.cyan);
      expect(
        glass.glowAlpha,
        0.18,
        reason: 'soft pastel glow on the featured card (LUXE §"soft glow")',
      );
      expect(
        glass.radius,
        BorderRadius.zero,
        reason: 'sharp brutalist geometry — LUXE cards are radius-0',
      );
    });

    testWidgets("renders the 'DESTACADO' badge as the cyan accent VBadge", (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow('e-feat', name: 'Tono Destacado', featured: true),
        ]),
      );

      final badge = tester.widget<VBadge>(
        find.widgetWithText(VBadge, 'DESTACADO'),
      );
      expect(
        badge.gradient,
        AppGradients.cyan,
        reason:
            'LUXE family accent — pale watered cyan fill, cyan mid-stop '
            'border, black label (NO PINK MAINS directive)',
      );
      expect(
        badge.accent,
        isNull,
        reason: 'the legacy flat glowPink accent is gone from the feed',
      );
    });
  });

  group('Event cards — hairline VGlassCard + §5.5 type badge', () {
    testWidgets('cards are sharp hairline VGlassCard with the cyan ring, '
        'VNetworkImage covers and the default VBadge type badge', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow(
            'e-1',
            name: 'Juerga en casa',
            coverUrl: 'https://img.test/c.png',
          ),
        ]),
      );

      final glassCard = tester.widget<VGlassCard>(find.byType(VGlassCard));
      expect(glassCard.gradient, AppGradients.cyan);
      expect(
        glassCard.glowAlpha,
        0,
        reason:
            'hairline list cards — the glow is reserved for the featured '
            'carousel (LUXE "sharp, hairline")',
      );

      expect(find.byType(VNetworkImage), findsOneWidget);

      final typeBadge = tester.widget<VBadge>(
        find.widgetWithText(VBadge, 'JUERGA'),
      );
      expect(
        typeBadge.accent,
        isNull,
        reason:
            'type badges are the §5.5 default variant (border #333333 '
            'fill + white uppercase labelSmall)',
      );
      expect(typeBadge.gradient, isNull);
    });

    testWidgets('date + location metadata render in mutedStrong (§2.4)', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow(
            'e-1',
            name: 'Juerga en casa',
            locationName: 'Barranco, Lima',
          ),
        ]),
      );

      final location = tester.widget<Text>(find.text('Barranco, Lima'));
      expect(
        location.style?.color,
        AppColors.mutedStrong,
        reason:
            'informational text must be mutedStrong ≥ #999999 — muted '
            'fails 1.4.3 at normal size (§2.4)',
      );
    });
  });

  group('Radius chips — VChip.accent in the cyan family (LUXE)', () {
    testWidgets('the radius filter renders cyan accent chips with the same '
        'options', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      final chips = tester.widgetList<VChip>(find.byType(VChip)).toList();
      expect(chips, isNotEmpty);
      for (final chip in chips) {
        expect(
          chip.accent,
          isTrue,
          reason: 'the LUXE chip row uses the accent variant',
        );
        expect(
          chip.gradient,
          AppGradients.cyan,
          reason:
              'selected = cyan border/fill, the feed family — never '
              'pink, never the violet default',
        );
      }
      expect(find.text('20 km'), findsOneWidget);
      expect(find.text('En cualquier lugar'), findsOneWidget);
    });
  });
}
