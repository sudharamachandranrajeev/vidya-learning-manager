// Assessment polish B2: the topic page's "Resume exam (mm:ss left)", a
// capstone sitting kept on the device and resumed, and the stress-test
// retake wait (`retakeDays`) with practice that is never saved. Made-up
// plans: a pottery exam, an apiary capstone and a library returns desk.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show addDays, today;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart' show dismissAllToasts;
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/capstone.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/exam.dart';
import 'package:vidya/domain/scenario.dart';
import 'package:vidya/ui/quiz_page.dart' show examClockProvider;

import 'app_harness.dart';
import 'exam_page_test.dart' show seedExam;

Map<String, Object?> _scenarioItem({Object? retakeDays}) => {
  'type': 'stress test',
  'id': 'st1',
  'title': 'Returns desk triage',
  'minutes': 5,
  'brief': 'You run the returns desk alone this morning.',
  'columns': ['Item', 'Shelf'],
  'rows': [
    {
      'cells': ['B001', 'Maps'],
      'risk': 'high',
      'expect': 'escalate',
    },
    {
      'cells': ['B002', 'Fiction'],
    },
  ],
  'retakeDays': ?retakeDays,
};

Future<void> _seedScenario(LearningBook b) => b.importCurriculum(
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
              'items': [_scenarioItem(retakeDays: 7)],
            },
          ],
        },
      ],
    }),
  ),
  today: today(),
);

Future<void> _seedCapstone(LearningBook b) => b.importCurriculum(
  parseCurriculum(
    jsonEncode({
      'format': 'vidya-curriculum',
      'version': 3,
      'program': {'title': 'Apiary lead'},
      'courses': [
        {
          'title': 'Hive leadership',
          'topics': [
            {
              'title': 'Inspections',
              'drills': [
                {'id': 'd1', 'question': 'Tell me about a hive inspection you led.'},
                {'id': 'd2', 'question': 'Why did you not report the swarm sooner?'},
              ],
              'capstone': {
                'drills': ['d1', 'd2'],
              },
            },
          ],
        },
      ],
    }),
  ),
  today: today(),
);

void main() {
  group('rules', () {
    test('a stress test keeps retakeDays from the plan, held to 0–60', () {
      expect(Scenario.fromJson(_scenarioItem())!.retakeDays, 0);
      expect(Scenario.fromJson(_scenarioItem(retakeDays: 7))!.retakeDays, 7);
      expect(Scenario.fromJson(_scenarioItem(retakeDays: '3'))!.retakeDays, 3);
      expect(Scenario.fromJson(_scenarioItem(retakeDays: 90))!.retakeDays, 60);
      expect(Scenario.fromJson(_scenarioItem(retakeDays: -4))!.retakeDays, 0);
      expect(Scenario.fromJson(_scenarioItem(retakeDays: 'soon'))!.retakeDays, 0);
      final s = Scenario.fromJson(_scenarioItem(retakeDays: 7))!;
      expect(s.toJson()['retakeDays'], 7);
      expect(Scenario.fromJson(s.toJson())!.retakeDays, 7, reason: 'stored and read back');
      expect(Scenario.fromJson(_scenarioItem())!.toJson().containsKey('retakeDays'), isFalse);
    });

    test('the next counted attempt: last day plus the wait, or none', () {
      expect(nextAttemptDay(const [], 7), isNull);
      expect(nextAttemptDay(const ['2026-11-01'], 0), isNull);
      expect(nextAttemptDay(const ['2026-11-03', '2026-11-01'], 7), '2026-11-10');
      expect(examLocked(nextAttemptDay(const ['2026-11-03'], 7), '2026-11-09'), isTrue);
      expect(examLocked(nextAttemptDay(const ['2026-11-03'], 7), '2026-11-10'), isFalse);
    });

    test('resume text: time left, time up, or marking left', () {
      const rules = ExamRules(minutes: 20);
      final start = DateTime(2026, 11, 27, 9);
      final p = ExamProgress(start: start, asked: const ['a'], given: const ['']);
      expect(
        resumeExamText(p, rules, start.add(const Duration(minutes: 7, seconds: 30))),
        'Resume exam (12:30 left)',
      );
      expect(resumeExamText(p, rules, start.add(const Duration(minutes: 25))), 'Resume exam (time is up)');
      final marking = ExamProgress(start: start, asked: const ['a'], given: const [''], handedIn: 300);
      expect(resumeExamText(marking, rules, start), 'Finish marking the exam');
      expect(examSecondsLeft(marking, rules, start), 0);
    });

    test('an unfinished capstone sitting round-trips; bad input reads as none', () {
      final p = CapstoneProgress(
        start: DateTime.utc(2026, 11, 27, 9),
        drills: const ['x1', 'x2', 'x3'],
        index: 1,
        results: const [CapstoneDrill(id: 'x1', title: 'Q1', outOf8: 6, attempt: 'a1')],
        before: const {
          'x1': ['old'],
        },
      );
      final back = CapstoneProgress.parse(p.encode())!;
      expect(back.start.toUtc(), p.start);
      expect(back.drills, p.drills);
      expect(back.index, 1);
      expect(back.results.single.outOf8, 6);
      expect(back.before['x1'], ['old']);
      expect(CapstoneProgress.parse(null), isNull);
      expect(CapstoneProgress.parse(''), isNull);
      expect(CapstoneProgress.parse('{not json'), isNull);
      expect(CapstoneProgress.parse(jsonEncode({'start': 'x', 'drills': []})), isNull);
      expect(
        CapstoneProgress.parse(
          jsonEncode({
            'start': '2026-11-27T09:00:00Z',
            'drills': ['a'],
            'index': 9,
          }),
        )!.index,
        0,
        reason: 'held to the drills',
      );
      expect(capstoneProgressKey('i1'), 'capstone.progress.i1');
    });
  });

  testWidgets('the topic page offers "Resume exam (mm:ss left)" for an exam under way', (tester) async {
    var now = DateTime(2026, 11, 27, 9);
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedExam);
    Future<void> openTopic() async {
      await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
      await app.go('Learn');
      await app.tapText('Pottery certificate');
      await app.tap(find.text('Wheel work').last);
      await app.tap(find.text('Mock exam').last);
    }

    await openTopic();
    expect(find.byKey(const Key('resume-exam')), findsNothing);
    await app.tapText('Start the exam');
    await app.tapText('Start the exam');
    await app.tapText('Left');
    await app.tapText('Next');

    // The app is killed; 20 seconds pass; the topic page now offers resume.
    await tester.pumpWidget(const SizedBox());
    now = now.add(const Duration(seconds: 20));
    await openTopic();
    expect(find.text('Resume exam (00:40 left)'), findsOneWidget);
    expect(find.text('Start the exam'), findsNothing);
    expect(tester.takeException(), isNull);
    await app.tap(find.byKey(const Key('resume-exam')));
    expect(find.text('Question 2 of 3'), findsOneWidget);
    await app.close();
  });

  testWidgets('an unfinished capstone sitting is kept and resumed where it was', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open(seed: _seedCapstone);
    Future<void> openCourse() async {
      await app.run();
      await app.go('Learn');
      await app.tapText('Apiary lead');
      await app.tapText('Hive leadership');
    }

    await openCourse();
    await app.tapText('Start capstone');
    await app.tap(find.widgetWithText(FilledButton, 'Start capstone'));
    for (var k = 0; k < 4; k++) {
      await app.tap(find.descendant(of: find.byKey(Key('cap-check-$k')), matching: find.text('Yes')));
    }
    await app.tapText('Next drill');
    expect(find.text('Drill 2 of 2'), findsOneWidget);

    // The app is killed mid-sitting and opened again.
    await tester.pumpWidget(const SizedBox());
    await openCourse();
    expect(find.text('Resume capstone'), findsOneWidget);
    expect(find.textContaining('a sitting is under way, drill 2 of 2'), findsOneWidget);
    await app.tapText('Resume capstone');
    expect(find.byKey(const Key('capstone-resume-note')), findsOneWidget);
    await app.tapText('Resume sitting');
    expect(find.text('Drill 2 of 2'), findsOneWidget);
    for (var k = 0; k < 4; k++) {
      await app.tap(find.descendant(of: find.byKey(Key('cap-check-$k')), matching: find.text('Partly')));
    }
    await app.tapText('Finish');
    expect(
      tester.widget<Text>(find.byKey(const Key('capstone-verdict'))).data,
      'Average 4.0/5 (needs 4.0) · lowest 3/5 (needs 3)',
      reason: 'drill 1 (5/5) from before the restart counts',
    );
    await tester.runAsync(() async {
      final db = app.book.db;
      final cap = (await db.select(db.learnItems).get()).singleWhere((i) => i.type == capstoneType);
      expect(await db.localSetting(capstoneProgressKey(cap.id)), '', reason: 'cleared once saved');
      final sittings = await app.book.capstoneSittings(cap.id);
      expect(sittings, hasLength(1));
      expect([for (final d in sittings.single.$2.drills) d.of5], [5, 3]);
    });
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a stress test with retakeDays locks the next counted attempt; practice is not saved', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seedScenario);
    await tester.runAsync(() async {
      final db = app.book.db;
      final item = (await db.select(db.learnItems).get()).singleWhere((i) => i.type == scenarioType);
      final s = scenarioOf(item)!;
      await app.book.recordScenario(
        item,
        ScenarioAttempt(
          scenario: s,
          picks: const ['escalate', 'act'],
          reasons: const ['', ''],
          checks: const [2, 2, 2, 2],
        ),
        today: today(),
      );
    });
    await app.run();
    await app.go('Learn');
    await app.tapText('Library assistant');
    await app.tap(find.text('Front desk').last);
    await app.tap(find.text('Returns').last);
    final next = addDays(today(), 7);
    expect(find.textContaining('Next counted attempt from'), findsOneWidget);
    await app.tapText('Open stress test');
    expect(find.textContaining('the next one counts from 7 days later'), findsOneWidget);
    expect(find.byKey(const Key('scenario-locked')), findsOneWidget);
    expect(find.text('Start the stress test'), findsNothing);
    expect(next.compareTo(today()), greaterThan(0));

    await app.tapText('Practise anyway (not counted)');
    await app.tap(find.byKey(const Key('scenario-pick-0-escalate')));
    await app.tap(find.text('Hand in').first);
    await app.tap(find.text('Hand in').last);
    final list = find.descendant(
      of: find.byKey(const Key('scenario-list')),
      matching: find.byType(Scrollable),
    );
    for (var k = 0; k < 4; k++) {
      await tester.scrollUntilVisible(find.byKey(Key('scenario-check-$k')), 150, scrollable: list.first);
      await app.tap(find.descendant(of: find.byKey(Key('scenario-check-$k')), matching: find.text('Yes')));
    }
    await tester.scrollUntilVisible(find.text('Save my rating'), 150, scrollable: list.first);
    await app.tapText('Save my rating');
    expect(find.byKey(const Key('scenario-practice')), findsOneWidget);
    await tester.runAsync(() async {
      final db = app.book.db;
      expect(await db.select(db.learnAssessments).get(), hasLength(1), reason: 'practice is never saved');
    });
    expect(tester.takeException(), isNull);
    dismissAllToasts();
    await app.close();
  });
}
