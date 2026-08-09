import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/shared/widgets/v_network_image.dart';

import '../support/test_network_image_http.dart';

/// The success-path (real HTTP fetch → disk cache → image decode) test of the
/// VNetworkImage suite, split into its OWN FILE by EF-04.
///
/// Why a separate file: image decoding is real engine work that competes for
/// the UI thread. Under a full `flutter test` run (many test isolates sharing
/// the machine's cores) fixed `Future.delayed(...)` sleeps are not enough to
/// guarantee the decoded frame is on screen — the old test flaked exactly
/// like that (I-24 flagged: passes isolated, flaky in full-suite runs).
///
/// Running this single test in its own isolate and waiting POLL-style (not
/// with fixed sleeps) makes it immune to load: it keeps pumping until the
/// decoded [RawImage] appears or the generous deadline passes.
///
///   flutter test test/widgets/v_network_image_disk_cache_test.dart
void main() {
  late CacheManager cacheManager;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() async {
    // A fresh per-test cache manager keeps no state between runs; dispose is
    // best-effort cleanup of the in-memory store.
    await cacheManager.dispose();
  });

  /// Pumps until [condition] holds, giving the real async HTTP/file/decode
  /// work inside the [HttpOverrides] zone real time to complete. Deterministic
  /// under any load — never a fixed-sleep race.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      // Advance the fake clock so the fade-in animation (and any pending
      // transition) completes — `pump()` without a duration would never
      // progress the fade and the placeholder would never unmount.
      await tester.pump(const Duration(milliseconds: 100));
      if (condition()) return;
    }
    fail('Timed out after $timeout waiting for the image to settle');
  }

  testWidgets('renders the decoded image on success (disk-cached flow)',
      (tester) async {
    await tester.runAsync(() {
      return inTestNetworkZone(() async {
        cacheManager = CacheManager(
          Config(
            'k-disk-cache',
            repo: NonStoringObjectProvider(),
            fileSystem: TestNetworkFileSystem(),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: VNetworkImage(
              imageUrl: kTestSuccessUrl,
              cacheManager: cacheManager,
            ),
          ),
        );
      });
    });

    // Wait for the FULL fade-in to settle: CachedNetworkImage keeps the
    // placeholder mounted while the decoded image fades in, so "RawImage
    // present" alone is a mid-transition state.
    await pumpUntil(
      tester,
      () =>
          find.byType(RawImage).evaluate().isNotEmpty &&
          find.byIcon(Icons.photo_outlined).evaluate().isEmpty,
    );

    expect(find.byIcon(Icons.photo_outlined), findsNothing);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  });
}
