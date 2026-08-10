import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/providers/connectivity_provider.dart';
import 'package:samay/core/services/connectivity_service.dart';

/// I-67: [connectivityProvider] must surface the service's stream as an
/// `AsyncValue<bool>`, start optimistic (loading — the banner treats
/// `valueOrNull ?? true` as connected), and follow every event of the
/// underlying stream (true/false transitions, errors).
void main() {
  ProviderContainer makeContainer(Stream<bool> stream) {
    final container = ProviderContainer(
      overrides: [
        connectivityServiceProvider.overrideWithValue(
          ConnectivityService(onConnectivityChanged: () => stream),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('starts in the loading state (initial optimistic)', () {
    final container = makeContainer(Stream<bool>.multi((_) {}));
    expect(container.read(connectivityProvider), const AsyncLoading<bool>());
  });

  test('emits true when the service stream emits true', () async {
    final container = makeContainer(Stream.value(true));
    expect(await container.read(connectivityProvider.future), isTrue);
  });

  test('emits false when the service stream emits false', () async {
    final container = makeContainer(Stream.value(false));
    expect(await container.read(connectivityProvider.future), isFalse);
  });

  test('follows a sequence of connectivity changes', () async {
    final controller = StreamController<bool>();
    addTearDown(controller.close);
    final container = makeContainer(controller.stream);

    final values = <bool?>[];
    final sub = container.listen<AsyncValue<bool>>(
      connectivityProvider,
      (_, next) => values.add(next.value),
    );
    addTearDown(sub.close);

    controller.add(true);
    await pumpEventQueue();
    controller.add(false);
    await pumpEventQueue();
    controller.add(true);
    await pumpEventQueue();

    expect(values, [true, false, true]);
  });

  test('a stream error surfaces as AsyncError (consumers fall back to '
      'optimistic)', () async {
    final controller = StreamController<bool>();
    addTearDown(controller.close);
    final container = makeContainer(controller.stream);

    final errors = <Object>[];
    final sub = container.listen<AsyncValue<bool>>(
      connectivityProvider,
      (_, next) {
        if (next.hasError) errors.add(next.error!);
      },
    );
    addTearDown(sub.close);

    controller.addError(Exception('plugin unavailable'));
    await pumpEventQueue();

    expect(errors, hasLength(1));
  });

  test('autoDispose releases the provider and re-creates it with a fresh '
      'subscription when re-watched', () async {
    var creates = 0;
    final container = ProviderContainer(
      overrides: [
        connectivityServiceProvider.overrideWithValue(
          ConnectivityService(onConnectivityChanged: () {
            creates++;
            return Stream.value(true);
          }),
        ),
      ],
    );
    addTearDown(container.dispose);

    final first = container.listen<AsyncValue<bool>>(
      connectivityProvider,
      (_, _) {},
    );
    await pumpEventQueue();
    expect(creates, 1);
    first.close();
    await container.pump();

    // Re-listening must re-create the provider (fresh subscription) — the
    // autoDispose lifecycle, not a cached element.
    final second = container.listen<AsyncValue<bool>>(
      connectivityProvider,
      (_, _) {},
    );
    await pumpEventQueue();
    expect(
      creates,
      2,
      reason: 'autoDispose must release the provider once the last listener '
          'leaves',
    );
    second.close();
  });
}
