// The stress-test runner (assess plan A5) on a phone: the brief, the
// no-pause countdown that hands in at zero, the checks with untouched
// high-risk rows first, the self-rating, and resuming after the app is
// killed. Made-up plan: a community library's returns desk.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show today;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart' show dismissAllToasts;
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/ui/quiz_page.dart' show examClockProvider;

import 'app_harness.dart';

Future<void> seedScenario(LearningBook b) => b.importCurriculum(
  parseCurriculum(
    jsonEncode({
      'format': 'vidya-curriculum',
      'version': 3,
      'program': {'title': 'Library assistant'},
      'courses': [
        {
          'title': 'Front desk',
          'topics': [
            {
              'title': 'Returns',
              'items': [
                {
                  'type': 'stress test',
                  'id': 'st1',
                  'title': 'Returns desk triage',
                  'minutes': 5,
                  'brief': 'You run the returns desk alone this morning.',
                  'columns': ['Item', 'Shelf', 'Flags'],
                  'rows': [
                    {
                      'cells': ['B001', 'Maps', 'water damage reported'],
                      'risk': 'high',
                      'expect': 'escalate',
                      'why': 'Damage goes to the conservator the same day.',
                    },
                    {
                      'cells': ['B002', 'Fiction', ''],
                      'risk': 'low',
                      'expect': 'act',
                    },
                    {
                      'cells': ['B003', 'Local history', 'only copy, torn cover'],
                      'risk': 'high',
                      'why': 'An only copy needs repair before it goes back.',
                    },
                  ],
                  'rubric': 'Damage and only copies first.',
                },
              ],
            },
          ],
        },
      ],
    }),
  ),
  today: today(),
);

/// The runner's list, for scrolling to a part not built yet.
final _list = find.descendant(of: find.byKey(const Key('scenario-list')), matching: find.byType(Scrollable));

Future<void> reach(WidgetTester tester, Finder f) =>
    tester.scrollUntilVisible(f, 150, scrollable: _list.first);

void main() {
  Future<AppHarness> openTopic(WidgetTester tester, DateTime Function() now) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedScenario);
    await app.run(overrides: [examClockProvider.overrideWithValue(now)]);
    await app.go('Learn');
    await app.tapText('Library assistant');
    await app.tap(find.text('Front desk').last);
    await app.tap(find.text('Returns').last);
    return app;
  }

  testWidgets('large text on a phone: the brief, the table, auto hand-in at zero and the result', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 27, 9);
    final app = await openTopic(tester, () => now);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.settle();
    expect(find.text('Not tried yet'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the topic page and its stress-test card');
    await app.tapText('Start stress test');

    expect(find.text('You run the returns desk alone this morning.'), findsOneWidget);
    final list = find.descendant(
      of: find.byKey(const Key('scenario-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('Damage and only copies first.'), 200, scrollable: list.first);
    await tester.scrollUntilVisible(find.text('Start the stress test'), 200, scrollable: list.first);
    expect(tester.takeException(), isNull, reason: 'the brief');
    await app.tapText('Start the stress test');

    expect(find.bySemanticsLabel('Time left: 5 minutes left'), findsOneWidget);
    expect(find.text('water damage reported'), findsNothing, reason: 'cells are in one line with the column');
    expect(find.textContaining('water damage reported'), findsOneWidget);
    expect(find.textContaining('high'), findsNothing, reason: 'risk is hidden while the clock runs');
    expect(find.bySemanticsLabel(RegExp('Row 1 of 3')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the table at large text');

    await app.tap(find.byKey(const Key('scenario-pick-0-escalate')));
    await tester.enterText(find.byKey(const Key('scenario-reason-0')), 'conservator today');
    await tester.pump();
    await app.tap(find.byKey(const Key('scenario-pick-1-leave')));

    // Time runs out with row 3 (high risk) untouched: handed in by itself.
    now = now.add(const Duration(minutes: 5, seconds: 1));
    await app.settle();
    expect(find.text('High-risk rows left untouched: 1'), findsOneWidget);
    expect(find.text('Row 3 (B003)'), findsOneWidget);
    expect(find.textContaining('An only copy needs repair'), findsOneWidget);
    expect(find.text('Matched the expected action on 1 of 2 rows'), findsOneWidget);
    expect(find.text('Act 0 · Escalate 1 · Leave 1 · Note 0 · No action 1'), findsOneWidget);
    expect(find.text('Time used 05:00 of 05:00 (time ran out)'), findsOneWidget);
    // Untouched high-risk rows come before the expected-action list.
    expect(
      tester.getTopLeft(find.byKey(const Key('scenario-untouched'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('scenario-matched'))).dy),
    );
    expect(tester.takeException(), isNull, reason: 'the checks at large text');

    for (var k = 0; k < 4; k++) {
      await reach(tester, find.byKey(Key('scenario-check-$k')));
      await app.tap(find.descendant(of: find.byKey(Key('scenario-check-$k')), matching: find.text('Yes')));
    }
    expect(find.text('Score: 5/5 (8/8)'), findsOneWidget);
    await reach(tester, find.text('Save my rating'));
    await app.tapText('Save my rating');
    expect(find.text('Not done yet'), findsOneWidget, reason: 'a high-risk row was left untouched');
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final db = app.book.db;
      final a = (await db.select(db.learnAssessments).get()).single;
      expect(jsonDecode(a.detail)['kind'], 'scenario');
      expect((a.score, a.max), (5.0, 5.0));
      final item = (await db.select(db.learnItems).get()).singleWhere((i) => i.type == 'scenario');
      expect(item.done, isNull);
    });

    dismissAllToasts();
    await app.settle();
    await reach(tester, find.text('Back to the stress test'));
    await app.tapText('Back to the stress test');
    expect(find.text('Past attempts'), findsOneWidget);
    await tester.pageBack();
    await app.settle();
    expect(find.textContaining('Last attempt: 1 high-risk row untouched'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('closing the app mid-test keeps the work: it resumes with the time still running', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 27, 9);
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedScenario);
    Future<void> openRunner() async {
      await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
      await app.go('Learn');
      await app.tapText('Library assistant');
      await app.tap(find.text('Front desk').last);
      await app.tap(find.text('Returns').last);
      await app.tapText('Start stress test');
    }

    await openRunner();
    await app.tapText('Start the stress test');
    await app.tap(find.byKey(const Key('scenario-pick-0-escalate')));
    await tester.enterText(find.byKey(const Key('scenario-reason-0')), 'conservator today');
    await app.settle(); // the reason is saved after a short pause

    // The app is killed; a minute passes; it is opened again.
    await tester.pumpWidget(const SizedBox());
    now = now.add(const Duration(minutes: 1));
    await openRunner();
    expect(find.bySemanticsLabel('Time left: 4 minutes left'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('scenario-pick-0-escalate'))).selected, isTrue);
    expect(find.widgetWithText(TextField, 'conservator today'), findsOneWidget);

    // Killed again, and away past the end: handed in on reopening.
    await tester.pumpWidget(const SizedBox());
    now = now.add(const Duration(minutes: 10));
    await openRunner();
    expect(find.text('Time used 05:00 of 05:00 (time ran out)'), findsOneWidget);
    expect(find.text('High-risk rows left untouched: 1'), findsOneWidget);
    for (final (k, v) in ['Yes', 'Yes', 'Partly', 'Partly'].indexed) {
      await reach(tester, find.byKey(Key('scenario-check-$k')));
      await app.tap(find.descendant(of: find.byKey(Key('scenario-check-$k')), matching: find.text(v)));
    }
    await reach(tester, find.text('Save my rating'));
    await app.tapText('Save my rating');
    expect(find.text('Not done yet'), findsOneWidget);
    await tester.runAsync(() async {
      final db = app.book.db;
      expect(await db.select(db.learnAssessments).get(), hasLength(1));
      final item = (await db.select(db.learnItems).get()).singleWhere((i) => i.type == 'scenario');
      expect(await db.localSetting('scenario.progress.${item.id}'), '');
    });
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
