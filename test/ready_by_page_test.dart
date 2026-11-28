import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/time_fit.dart';

import 'app_harness.dart';

/// A plan dated two weeks out that needs more than the default hours, and
/// a course of its own whose exam day has just passed. Fictional.
Future<void> seedDated(LearningBook b) async {
  final day = today();
  final p = await b.addProgram('Lighthouse keeper', '', today: day, target: addDays(day, 14));
  final c = await b.addCourse(
    'Lamp care for long winter nights at the far end of the pier',
    today: day,
    programId: p,
  );
  for (final name in ['Lens cleaning', 'Wick trimming and the long history of every lamp ever made']) {
    final t = await b.addTopic(c, name);
    await b.addItem(t, 'video', 'Core', minutes: 240, required: true);
    await b.addItem(t, 'article', 'Extra reading', minutes: 120);
  }
  await b.addCourse('Foghorn signals exam', today: day, due: addDays(day, -2));
}

void main() {
  testWidgets('ready by on a phone at twice the text size: short, cuts, then the outcome from Home', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedDated);
    await app.run();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.settle();
    expect(tester.takeException(), isNull, reason: 'home');

    // Home: the passed exam asks for its outcome; the plan says it is short.
    expect(find.textContaining('Foghorn signals exam: how did'), findsOneWidget);
    expect(find.text('Ready by'), findsOneWidget);
    // 720 min needed; 210 a week for 14 days gives 420: 300 min short.
    expect(find.bySemanticsLabel(RegExp(r'5 hours short for ')), findsWidgets);

    await app.tap(find.text('Log the outcome').first);
    expect(tester.takeException(), isNull, reason: 'outcome dialog');
    await app.enter('Score in percent (optional)', '120');
    await app.tapText('Save');
    expect(find.text('The score must be a percent from 0 to 100.'), findsOneWidget);
    await app.enter('Score in percent (optional)', '74');
    await app.tapText('Save');
    expect(find.textContaining('Foghorn signals exam: how did'), findsNothing);
    final outcomes = await tester.runAsync(() => app.book.readyByOutcomes());
    expect(outcomes!.single.percent, 74);
    expect(outcomes.single.result, OutcomeResult.passed);

    // The plan page lists what to cut, lowest weight first.
    await app.tap(find.text('See what to cut'));
    expect(tester.takeException(), isNull, reason: 'program page');
    expect(find.text('To make it fit, lowest weight first:'), findsOneWidget);
    expect(find.textContaining('Drop Wick trimming'), findsOneWidget);
    expect(find.textContaining('Skim Lens cleaning'), findsOneWidget);
    expect(find.textContaining('(the default: no weekly target is set)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    semantics.dispose();
    await app.close();
  });
}
