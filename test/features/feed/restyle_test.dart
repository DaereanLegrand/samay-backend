import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/design_tokens/app_colors.dart';
import 'package:samay/core/design_tokens/app_typography.dart';
import 'package:samay/core/models/event.dart';
import 'package:samay/core/providers/config_provider.dart';
import 'package:samay/core/providers/service_providers.dart';
import 'package:samay/core/services/event_service.dart';
import 'package:samay/core/theme/app_theme.dart';
import 'package:samay/features/feed/screens/feed_screen.dart';
import 'package:samay/l10n/app_localizations.dart';
import 'package:samay/shared/widgets/v_badge.dart';
import 'package:samay/shared/widgets/v_card.dart';
import 'package:samay/shared/widgets/v_chip.dart';
import 'package:samay/shared/widgets/v_disco_divider.dart';
import 'package:samay/shared/widgets/v_glow_text.dart';
import 'package:samay/shared/widgets/v_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../support/fake_config_provider.dart';

/// Feed-restyle ledger tests (U-08, DISCO-DESIGN-SYSTEM §3.2/§3.4/§5.3/§5.5).
///
/// The feed is **restyled, not redesigned**: the provider/behavior contract
/// and the interaction tests of `feed_test.dart` stay the authoritative
/// assertions for data + flow (all unchanged and green). This file pins the
/// *deliberate visual changes* from the U-08 ledger only:
///
/// 1. The 'Samay' brand header renders through [VGlowText] (Playfair Display
///    italic `displaySmall` + the glow-strong stack — §3.2/§3.4, the doc's
///    fancy moment).
/// 2. Section separators use [VDiscoDivider] (hairline + centered glowPink
///    segment, U-06): header→content always when events exist, plus
///    featured→list when both sections exist.
/// 3. The featured card keeps the §5.3 glowPink hairline border and its
///    badge is the `VBadge.accent` glowPink variant ('DESTACADO' — §5.5
///    accent variant, uppercase §3.3).
/// 4. Event cards keep the §5.3 [VCard] treatment (hairline, sharp) with
///    [VNetworkImage] covers, default [VBadge] type badges (§5.5) and
///    `mutedStrong` metadata (§2.4).
/// 5. Radius chips stay [VChip] (unchanged behavior — §5.4).
class _FakeEventService implements EventService {
  _FakeEventService(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  GoTrueClient get auth => throw UnimplementedError();

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> createEvent(Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> getEvent(String id) =>
      throw UnimplementedError();

  @override
  Future<Event?> getEventByInviteToken(String token) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyQrToken(String eventId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getEventPromotores(String eventId) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>?> getMyEventInvite(String eventId) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> listEvents([
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

Map<String, dynamic> _eventRow(
  String id, {
  String name = 'Fiesta',
  String type = 'juerga',
  DateTime? startsAt,
  String? locationName,
  String? coverUrl,
  bool featured = false,
}) {
  final start = startsAt ?? DateTime(2026, 9, 15, 22);
  return {
    'id': id,
    'name': name,
    'type': type,
    'status': 'upcoming',
    'group_id': null,
    'location_name': locationName,
    'cover_url': coverUrl,
    'featured': featured,
    'starts_at': start.toUtc().toIso8601String(),
    'ends_at': start.add(const Duration(hours: 4)).toUtc().toIso8601String(),
  };
}

/// Pumps the real [FeedScreen] under the Samay disco theme (the app's only
/// theme — `lib/app.dart`), with the in-memory fake service + config.
Future<void> _pumpScreen(WidgetTester tester, _FakeEventService service) async {
  final container = ProviderContainer(
    overrides: [
      eventServiceProvider.overrideWithValue(service),
      appConfigProvider.overrideWith(() => FakeAppConfigNotifier(const {})),
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

/// The feed card Container carrying the §5.3 glowPink hairline border.
Container _featuredCard(WidgetTester tester) {
  return tester.widgetList<Container>(find.byType(Container)).firstWhere((c) {
    final d = c.decoration;
    return d is BoxDecoration &&
        d.border is Border &&
        (d.border as Border).top.color == AppColors.glowPink;
  });
}

void main() {
  group('Feed hero — VGlowText brand header (§3.2/§3.4)', () {
    testWidgets("the 'Samay' header renders through VGlowText with the "
        'glow-strong displaySmall stack', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      final glow = tester.widget<VGlowText>(find.byType(VGlowText));
      expect(glow.text, 'Samay');
      expect(
        glow.soft,
        isFalse,
        reason: 'displaySmall ≥32px uses the 3-layer glow-strong stack (§3.4)',
      );

      final text = tester.widget<Text>(find.text('Samay'));
      expect(text.style?.fontFamily, AppTypography.playfair);
      expect(text.style?.fontSize, AppTypography.displaySmall.fontSize);
      expect(text.style?.fontStyle, FontStyle.italic);
      expect(
        text.style?.shadows,
        AppTypography.fancyTitle(AppTypography.displaySmall).shadows,
        reason:
            'the hero glow must be byte-identical to the canonical '
            'glow-strong stack (§3.4 parity, U-06)',
      );
    });
  });

  group('Section separators — VDiscoDivider (U-06)', () {
    testWidgets('renders a divider below the header and another between '
        'featured and the list when both sections exist', (tester) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow('e-feat', featured: true),
          _eventRow('e-plain'),
        ]),
      );

      expect(find.byType(VDiscoDivider), findsNWidgets(2));
    });

    testWidgets('renders a single divider below the header when there is no '
        'featured section', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      expect(find.byType(VDiscoDivider), findsOneWidget);
    });
  });

  group('Featured card — §5.3 glowPink hairline + §5.5 accent badge', () {
    testWidgets('keeps the glowPink hairline border (the event of the night)', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        _FakeEventService([
          _eventRow('e-feat', name: 'Tono Destacado', featured: true),
        ]),
      );

      final card = _featuredCard(tester);
      final border = ((card.decoration! as BoxDecoration).border! as Border);
      expect(border.top.color, AppColors.glowPink);
      expect(
        border.top.width,
        1,
        reason: 'hairline-thin — §5.3 glowPink 1px border',
      );
    });

    testWidgets("renders the 'DESTACADO' badge as the glowPink accent VBadge", (
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
        badge.accent,
        AppColors.glowPink,
        reason: '§5.5 accent variant: glowPink border + label, black fill',
      );
    });
  });

  group('Event cards — §5.3 VCard treatment + §5.5 type badge', () {
    testWidgets('cards use the hairline VCard, VNetworkImage covers and the '
        'default VBadge type badge', (tester) async {
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

      expect(find.byType(VCard), findsOneWidget);
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

  group('Radius chips — VChip unchanged (§5.4)', () {
    testWidgets('the radius filter still renders VChip chips', (tester) async {
      await _pumpScreen(tester, _FakeEventService([_eventRow('e-1')]));

      expect(find.byType(VChip), findsWidgets);
      expect(find.text('20 km'), findsOneWidget);
      expect(find.text('En cualquier lugar'), findsOneWidget);
    });
  });
}
