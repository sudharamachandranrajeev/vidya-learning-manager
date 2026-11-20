import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/udyoga_link.dart';

/// A timer the test fires by hand.
class _Timer implements Timer {
  _Timer(this.after, this.run);
  final Duration after;
  final void Function() run;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

void main() {
  late DateTime now;
  late List<String> sent;
  late List<_Timer> timers;
  late ProgressReporter reporter;

  setUp(() {
    now = DateTime.utc(2026, 11, 19, 9);
    sent = [];
    timers = [];
    reporter = ProgressReporter(
      (at) async => sent.add(at),
      clock: () => now,
      timer: (d, f) {
        final t = _Timer(d, f);
        timers.add(t);
        return t;
      },
    );
  });

  test('the first request reports at once', () async {
    await reporter.request();
    expect(sent, ['2026-11-19T09:00:00.000Z']);
    expect(reporter.pending, isFalse);
  });

  test('requests inside ten minutes wait for the gap, then report once', () async {
    await reporter.request(); // app opened
    now = now.add(const Duration(minutes: 3));
    await reporter.request(); // a review session ended
    now = now.add(const Duration(minutes: 2));
    await reporter.request(); // the app came back to the front
    expect(sent, hasLength(1), reason: 'at most once per ten minutes');
    expect(reporter.pending, isTrue);
    expect(timers, hasLength(1), reason: 'one wait, however many requests');
    expect(timers.single.after, const Duration(minutes: 7));

    now = DateTime.utc(2026, 11, 19, 9, 10);
    timers.single.run();
    await Future<void>.delayed(Duration.zero);
    expect(sent, ['2026-11-19T09:00:00.000Z', '2026-11-19T09:10:00.000Z']);
    expect(reporter.pending, isFalse);
  });

  test('a request after the gap reports at once and drops any wait', () async {
    await reporter.request();
    now = now.add(const Duration(minutes: 1));
    await reporter.request();
    now = now.add(const Duration(minutes: 30)); // the timer never fired: the app was closed
    await reporter.request();
    expect(sent, hasLength(2));
    expect(timers.single.cancelled, isTrue);
    expect(reporter.pending, isFalse);
  });

  test('dispose cancels a waiting report', () async {
    await reporter.request();
    now = now.add(const Duration(minutes: 1));
    await reporter.request();
    reporter.dispose();
    expect(timers.single.cancelled, isTrue);
    expect(reporter.pending, isFalse);
  });
}
