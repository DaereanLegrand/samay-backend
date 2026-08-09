import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/theme/samay_durations.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

import '../support/test_network_image_http.dart';

/// Builds a real [CacheManager] inside the [HttpOverrides] zone so the
/// [http.Client] it creates deterministically uses the test HttpClient.
///
/// A FRESH manager with a UNIQUE key per test: flutter_cache_manager keeps a
/// per-instance in-memory cache, so reusing keys across tests would leak
/// cached objects between them (the disk-cache decode case lives in
/// `v_network_image_disk_cache_test.dart` and runs in its own isolate).
CacheManager newCacheManager(String key) {
  return CacheManager(
    Config(
      key,
      repo: NonStoringObjectProvider(),
      fileSystem: TestNetworkFileSystem(),
    ),
  );
}

/// Pumps a [VNetworkImage] under the test [HttpOverrides] zone so the real
/// HTTP + cache pipeline runs deterministically.
Future<void> pumpWithNetwork(
  WidgetTester tester, {
  required String url,
  required String cacheKey,
  Widget Function(CacheManager cacheManager)? builder,
}) async {
  await tester.runAsync(() {
    return inTestNetworkZone(() async {
      final cacheManager = newCacheManager(cacheKey);
      await tester.pumpWidget(
        MaterialApp(
          home: builder != null
              ? builder(cacheManager)
              : VNetworkImage(imageUrl: url, cacheManager: cacheManager),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Hygiene: a previous test's decoded frames must never leak into the
    // next test through the (per-isolate) global ImageCache.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('VNetworkImage', () {
    testWidgets('renders the branded placeholder while the image is loading',
        (tester) async {
      await pumpWithNetwork(tester, url: kTestHangingUrl, cacheKey: 'k1');

      expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('placeholder uses the grey[900] surface', (tester) async {
      await pumpWithNetwork(tester, url: kTestHangingUrl, cacheKey: 'k2');

      final placeholder = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.grey[900],
        ),
      );
      expect(placeholder.color, Colors.grey[900]);
    });

    testWidgets('renders the error widget on HTTP failure without crashing',
        (tester) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k3');

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.photo_outlined), findsNothing);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('error widget uses the grey[800] surface', (tester) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k4');

      final errorSurface = tester.widget<ColoredBox>(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == Colors.grey[800],
        ),
      );
      expect(errorSurface.color, Colors.grey[800]);
    });

    testWidgets('passes fit through to CachedNetworkImage', (tester) async {
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k6',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          fit: BoxFit.contain,
          cacheManager: cache,
        ),
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.fit, BoxFit.contain);
    });

    testWidgets('passes width and height through to CachedNetworkImage',
        (tester) async {
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k7',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          width: 40,
          height: 40,
          cacheManager: cache,
        ),
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.width, 40);
      expect(cached.height, 40);
    });

    testWidgets('passes the imageUrl and cacheManager through',
        (tester) async {
      late CacheManager usedCache;
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k8',
        builder: (cache) {
          usedCache = cache;
          return VNetworkImage(
            imageUrl: kTestBrokenUrl,
            cacheManager: cache,
          );
        },
      );

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.imageUrl, kTestBrokenUrl);
      expect(cached.cacheManager, same(usedCache));
    });

    testWidgets('is sharp by default (no borderRadius → no ClipRRect)',
        (tester) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k9');

      expect(find.byType(ClipRRect), findsNothing);
    });

    testWidgets('applies borderRadius via ClipRRect', (tester) async {
      const radius = BorderRadius.all(Radius.circular(12));
      await pumpWithNetwork(
        tester,
        url: kTestBrokenUrl,
        cacheKey: 'k10',
        builder: (cache) => VNetworkImage(
          imageUrl: kTestBrokenUrl,
          borderRadius: radius,
          cacheManager: cache,
        ),
      );

      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius, radius);
    });

    testWidgets('fades in on load using the standard duration', (tester) async {
      await pumpWithNetwork(tester, url: kTestBrokenUrl, cacheKey: 'k11');

      final cached = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cached.fadeInDuration, SamayDurations.standard);
    });

    test('is const-constructible with sane defaults', () {
      const widget = VNetworkImage(imageUrl: 'https://img.test/x.png');
      expect(widget.imageUrl, 'https://img.test/x.png');
      expect(widget.fit, BoxFit.cover);
      expect(widget.borderRadius, isNull);
      expect(widget.fadeInDuration, SamayDurations.standard);
    });
  });
}
