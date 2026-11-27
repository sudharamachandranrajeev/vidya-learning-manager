import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';
import 'quiz_page_test.dart' show seedPlan;

void main() {
  testWidgets('Home, Learn, a program and a course fit on a phone at twice the text size', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedPlan);
    await app.run();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.settle();
    expect(tester.takeException(), isNull, reason: 'home');
    await app.go('Learn');
    expect(tester.takeException(), isNull, reason: 'learn');
    await app.tapText('Pottery teacher');
    expect(tester.takeException(), isNull, reason: 'program');
    await app.tap(find.textContaining('Wheel basics for complete').last);
    expect(find.byType(Scaffold), findsWidgets);
    expect(tester.takeException(), isNull, reason: 'course: a meter\'s label row overflowed');
    await app.close();
  });
}
