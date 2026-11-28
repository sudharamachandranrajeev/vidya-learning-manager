// Readiness calibration (C5): a made-up lighthouse-keeper plan; fictional
// rows only.

import 'dart:async';
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/exam.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/time_fit.dart';
import 'package:vidya/ui/readiness_page.dart';

import 'app_harness.dart';
import 'support.dart';

const day = '2026-11-21';

Map<String, Object?> _plan() => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Lighthouse keeper'},
  'role': 'Lighthouse keeper',
  'criteria': [
    {'id': 'k1', 'text': 'Trim and light the lamp', 'essential': true},
    {'id': 'k2', 'text': 'Log passing ships', 'essential': true},
  ],
  'courses': [
    {
      'title': 'Keeping',
      'topics': [
        {
          'title': 'Lamp exam',
          'criteria': ['k1'],
          'quiz': [
            {'question': 'Trim the wick before dusk?', 'answer': 'Yes'},
            {'question': 'Polish the lens daily?', 'answer': 'Yes'},
          ],
          'exam': {'minutes': 5, 'passPercent': 50},
        },
        {
          'title': 'Ship log',
          'criteria': ['k2'],
        },
      ],
    },
  ],
};

Future<String> _seed(LearningBook book, {String imported = '2026-11-01'}) async =>
    (await book.importCurriculum(parseCurriculum(jsonEncode(_plan())), today: imported)).programId;

/// Sits the plan's exam, answering every question right, asking the whole
/// pool (so a second sitting repeats every question).
Future<void> _sitExam(LearningBook book, {required String on}) async {
  final quiz = (await (book.db.select(book.db.learnItems)..where((i) => i.type.equals('quiz'))).get()).single;
  final shown = quizQuestions(quiz);
  await book.recordExam(
    quiz,
    shown,
    [for (final _ in shown) true],
    ExamResult(
      right: shown.length,
      total: shown.length,
      attempted: shown.length,
      seconds: 60,
      limitSeconds: 300,
      passPercent: 50,
      asked: [for (final q in shown) questionId(q)],
    ),
    today: on,
  );
}

void main() {
  group('calibration text', () {
    const snap = ReadinessSnapshot(covered: 9, total: 12, essential: true);
    ReadyByOutcome outcome(OutcomeResult r, {int? percent, ReadinessSnapshot? readiness = snap}) =>
        ReadyByOutcome(goalId: 'g', target: '2026-11-10', result: r, percent: percent, readiness: readiness);

    test('says what readiness showed, the result and the gap, either way', () {
      expect(snap.percent, 75);
      expect(
        calibrationText(outcome(OutcomeResult.notPassed, percent: 68)),
        'Readiness said 75% (9 of 12 essential criteria covered), result 68% (gap -7 points).',
      );
      expect(
        calibrationText(outcome(OutcomeResult.passed, percent: 80)),
        'Readiness said 75% (9 of 12 essential criteria covered), result 80% (gap +5 points).',
      );
      expect(calibrationText(outcome(OutcomeResult.passed, percent: 75)), endsWith('(gap 0 points).'));
      expect(
        calibrationText(
          outcome(
            OutcomeResult.passed,
            percent: 90,
            readiness: const ReadinessSnapshot(covered: 1, total: 3, essential: false),
          ),
        ),
        'Readiness said 33% (1 of 3 criteria covered), result 90% (gap +57 points).',
      );
    });

    test('with no score, no result yet or no day, nothing is made up', () {
      expect(
        calibrationText(outcome(OutcomeResult.passed)),
        'Readiness said 75% (9 of 12 essential criteria covered); outcome: passed, or got the job, '
        'with no score to compare.',
      );
      expect(calibrationText(outcome(OutcomeResult.waiting)), endsWith('; the result is not in yet.'));
      expect(
        calibrationText(outcome(OutcomeResult.didNotHappen, percent: 40)),
        endsWith('the day did not happen, so there is nothing to compare.'),
      );
    });

    test('an outcome logged before snapshots were kept shows no snapshot', () {
      // As C1 wrote it: no readiness in the detail.
      const old =
          '{"kind":"readyby-outcome","goal":"g","target":"2026-11-10","result":"notPassed","percent":55}';
      final o = ReadyByOutcome.parse(old)!;
      expect(o.readiness, isNull);
      expect(
        calibrationText(o),
        'No snapshot: readiness was not recorded when this outcome was logged, so the 55% result has '
        'nothing to compare with.',
      );
      expect(calibrationText(outcome(OutcomeResult.passed, readiness: null)), endsWith('was logged.'));
    });

    test('a snapshot survives the detail and bad ones are dropped', () {
      final o = outcome(
        OutcomeResult.passed,
        percent: 70,
        readiness: const ReadinessSnapshot(covered: 2, total: 4, essential: true, repeats: 3, asked: 4),
      );
      final back = ReadyByOutcome.parse(o.encode())!;
      final r = back.readiness!;
      expect((r.covered, r.total, r.essential, r.repeats, r.asked), (2, 4, true, 3, 4));
      expect(ReadinessSnapshot.fromJson({'covered': 5, 'total': 4}), isNull);
      expect(ReadinessSnapshot.fromJson({'covered': 1, 'total': 0}), isNull);
      expect(ReadinessSnapshot.fromJson('75%'), isNull);
    });
  });

  group('stored with the outcome', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    test('logging a plan outcome keeps what readiness showed', () async {
      final p = await _seed(book);
      await _sitExam(book, on: '2026-11-05');
      await book.setProgramTarget(p, '2026-11-10');
      final r = await book.readiness(p, today: '2026-11-10');
      final covered = r.summary.essentialCovered;
      final goal = (await book.readyByGoals()).single;
      await book.logOutcome(goal, OutcomeResult.passed, today: day, percent: 64);
      final o = (await book.readyByOutcomes()).single;
      final s = o.readiness!;
      expect((s.covered, s.total, s.essential), (covered, 2, true));
      expect(s.asked, 2, reason: 'one exam sitting, two questions');
      expect(s.repeats, 0);
      expect(
        calibrationText(o),
        'Readiness said ${s.percent}% ($covered of 2 essential criteria covered), result 64% '
        '(gap ${64 - s.percent > 0 ? '+' : ''}${64 - s.percent} points).',
      );
      expect(possiblyInflated(s.seen), isFalse);
    });

    test('a course with no criteria logs no snapshot', () async {
      await book.addCourse('Fog signals exam', today: '2026-11-01', due: '2026-11-10');
      await book.logOutcome(
        (await book.readyByGoals()).single,
        OutcomeResult.passed,
        today: day,
        percent: 90,
      );
      final o = (await book.readyByOutcomes()).single;
      expect(o.readiness, isNull);
      expect(calibrationText(o), startsWith('No snapshot'));
    });

    test('readiness resting on exam questions seen before is flagged as possibly inflated', () async {
      final p = await _seed(book);
      await _sitExam(book, on: '2026-11-03');
      expect(possiblyInflated(await book.readinessRepeats(p)), isFalse, reason: 'first sitting: all new');
      await _sitExam(book, on: '2026-11-06');
      final seen = await book.readinessRepeats(p);
      expect(seen, (repeats: 2, asked: 2));
      expect(possiblyInflated(seen), isTrue);
      expect(inflationText(seen), startsWith('Possibly inflated: 2 of 2 exam questions'));
      await book.setProgramTarget(p, '2026-11-10');
      await book.logOutcome(
        (await book.readyByGoals()).single,
        OutcomeResult.notPassed,
        today: day,
        percent: 40,
      );
      final o = (await book.readyByOutcomes()).single;
      expect(o.readiness!.seen, (repeats: 2, asked: 2));
      expect(calibrationText(o), contains('Possibly inflated'));
    });

    test('a practice quiz after the exams is not counted as seen before', () {
      Assessment row(String id, String day, String detail) => Assessment(
        id: id,
        hlc: id,
        deleted: false,
        courseId: null,
        topicId: 't',
        itemId: 'q',
        title: 'x',
        day: day,
        score: 2,
        max: 2,
        detail: detail,
      );
      const exam = ExamResult(
        right: 2,
        total: 2,
        attempted: 2,
        seconds: 1,
        limitSeconds: 60,
        passPercent: 50,
        asked: ['a', 'b'],
      );
      final two = [row('1', '2026-11-01', exam.encode()), row('2', '2026-11-02', exam.encode())];
      expect(examRepeats(two), (repeats: 2, asked: 2));
      expect(examRepeats([...two, row('3', '2026-11-03', '')]), (repeats: 0, asked: 0));
    });
  });

  testWidgets('the Readiness page shows each outcome against readiness and the seen-before warning', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    late String p;
    await app.open(
      seed: (book) async {
        final now = today();
        p = await _seed(book, imported: addDays(now, -30));
        await _sitExam(book, on: addDays(now, -20));
        await _sitExam(book, on: addDays(now, -15));
        await book.setProgramTarget(p, addDays(now, -10));
        await book.logOutcome(
          (await book.readyByGoals()).single,
          OutcomeResult.notPassed,
          today: now,
          percent: 40,
        );
      },
    );
    await app.run();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ReadinessPage(p))));
    await app.settle();
    expect(find.byKey(const Key('readiness-inflated')), findsOneWidget);
    expect(find.text('Against real results'), findsOneWidget);
    expect(find.textContaining('result 40% (gap'), findsOneWidget);
    expect(find.textContaining('Possibly inflated: 2 of 2'), findsWidgets);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
