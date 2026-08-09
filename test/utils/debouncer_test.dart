import 'package:flutter_test/flutter_test.dart';
import 'package:samay/core/utils/debouncer.dart';

/// Unit tests for the shared [Debouncer] (PERF-05 / L-24).
///
/// `testWidgets` + `tester.pump` drive a fake clock, so the timers never wait
/// in real time and the tests are deterministic.
void main() {
  group('Debouncer', () {
    testWidgets('collapses rapid calls into a single firing after the delay',
        (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;
      var lastValue = '';
      for (var i = 1; i <= 5; i++) {
        final value = 'q$i';
        debouncer.run(() {
          fires++;
          lastValue = value;
        });
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(fires, 0, reason: 'still inside the debounce window');
      await tester.pump(const Duration(milliseconds: 250));
      expect(fires, 1, reason: 'exactly one firing after the window closes');
      expect(lastValue, 'q5', reason: 'only the latest action runs');

      await tester.pump(const Duration(milliseconds: 300));
      expect(fires, 1, reason: 'the action never fires a second time');
    });

    testWidgets('delay is respected — nothing fires before it elapses',
        (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;
      debouncer.run(() => fires++);

      await tester.pump(const Duration(milliseconds: 100));
      expect(fires, 0);
      await tester.pump(const Duration(milliseconds: 199));
      expect(fires, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(fires, 1);
    });

    testWidgets('a zero-delay debouncer fires on the next timer tick',
        (tester) async {
      final debouncer = Debouncer(Duration.zero);
      var fires = 0;
      debouncer.run(() => fires++);

      await tester.pump(const Duration(milliseconds: 1));
      expect(fires, 1);
    });

    testWidgets('cancel prevents the pending action from firing', (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;
      debouncer.run(() => fires++);

      debouncer.cancel();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fires, 0);

      debouncer.cancel();
      expect(fires, 0, reason: 'cancel is idempotent');
    });

    testWidgets('flush runs the pending action immediately and cancels the timer',
        (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;
      debouncer.run(() => fires++);

      debouncer.flush();
      expect(fires, 1, reason: 'flush fires synchronously');

      await tester.pump(const Duration(milliseconds: 300));
      expect(fires, 1, reason: 'the scheduled timer was cancelled');
    });

    testWidgets('flush with nothing pending is a no-op', (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;

      debouncer.flush();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fires, 0);
    });

    testWidgets('run after flush schedules a fresh window', (tester) async {
      final debouncer = Debouncer(const Duration(milliseconds: 300));
      var fires = 0;

      debouncer.run(() => fires++);
      debouncer.flush();
      expect(fires, 1);

      debouncer.run(() => fires++);
      await tester.pump(const Duration(milliseconds: 299));
      expect(fires, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(fires, 2);
    });
  });
}
