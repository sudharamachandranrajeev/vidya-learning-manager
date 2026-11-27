import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show today;
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart' show dismissAllToasts;
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/exam.dart';
import 'package:vidya/ui/quiz_page.dart' show examClockProvider;

import 'app_harness.dart';

/// A made-up plan: a pottery course whose last topic is a one-minute mock
/// exam, not shuffled, so the questions come in the order written.
Future<void> seedExam(LearningBook b) => b.importCurriculum(
  parseCurriculum(
    jsonEncode({
      'format': 'vidya-curriculum',
      'version': 3,
      'program': {'title': 'Pottery certificate'},
      'courses': [
        {
          'title': 'Wheel work',
          'topics': [
            {'title': 'Centering'},
            {'title': 'Trimming'},
            {
              'title': 'Mock exam',
              'quiz': [
                {
                  'question': 'Which hand braces on the knee?',
                  'options': ['Left', 'Right'],
                  'answer': 'Left',
                  'explain': 'The left arm rests on the knee.',
                  'topic': 'Centering',
                },
                {'question': 'What runs true?', 'kind': 'short', 'answer': 'The clay', 'topic': 'Centering'},
                {
                  'question': 'What tool trims a foot ring?',
                  'kind': 'card',
                  'answer': 'A loop tool',
                  'topic': 'Trimming',
                },
              ],
              'exam': {'minutes': 1, 'passPercent': 60, 'retakeDays': 7, 'shuffle': false},
            },
          ],
        },
      ],
    }),
  ),
  today: today(),
);

void main() {
  testWidgets(
    'an exam on a phone: no feedback, the timer runs out and hands it in, then the report and lock',
    (tester) async {
      var now = DateTime(2026, 11, 27, 9);
      final app = AppHarness(tester)..phone();
      await app.open(seed: seedExam);
      await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
      await app.go('Learn');
      await app.tapText('Pottery certificate');
      await app.tap(find.text('Wheel work').last);
      await app.tap(find.text('Mock exam').last);
      expect(find.textContaining('3 questions in'), findsOneWidget);
      expect(find.text('Practise (not counted)'), findsOneWidget);
      await app.tapText('Start the exam');

      // The rules first; without a count there is no seen-before warning.
      expect(find.text('Timed exam'), findsOneWidget);
      expect(find.textContaining('small question pool'), findsNothing, reason: 'every question is asked');
      await app.tapText('Start the exam');

      expect(find.text('Question 1 of 3'), findsOneWidget);
      expect(find.text('01:00'), findsOneWidget);
      await app.tapText('Left');
      expect(find.text('Right.'), findsNothing, reason: 'no feedback until the end');
      expect(find.text('The left arm rests on the knee.'), findsNothing);
      await app.tapText('Next');
      await app.enter('Your answer', ' the clay ');
      await app.tapText('Next');
      expect(find.text('Question 3 of 3'), findsOneWidget);

      // Time runs out with the card unanswered: handed in by itself.
      now = now.add(const Duration(seconds: 61));
      await app.settle();

      expect(find.text('67% · Passed'), findsOneWidget);
      expect(find.textContaining('Time taken 01:00 of 01:00 (time ran out)'), findsOneWidget);
      expect(find.textContaining('Answered 2 of 3'), findsOneWidget);
      expect(find.text('Study these first'), findsOneWidget);
      expect(find.text('1. Trimming'), findsOneWidget);
      expect(find.text('No answer'), findsOneWidget);
      expect(find.text('The left arm rests on the knee.'), findsOneWidget, reason: 'explanations at the end');
      expect(find.textContaining('1 missed question is now review cards'), findsOneWidget);
      expect(find.textContaining('Next attempt from'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final db = app.book.db;
        expect(
          (await (db.select(db.learnCards)..where((c) => c.deleted.not())).get()).single.front,
          'What tool trims a foot ring?',
        );
        final attempt = ExamResult.of((await db.select(db.learnAssessments).get()).single)!;
        expect((attempt.right, attempt.total, attempt.timedOut, attempt.seconds), (2, 3, true, 60));
      });

      // Back on the topic: locked for a week, practice still open, history drawn.
      // The first test earns an achievement; its toast covers the button.
      dismissAllToasts();
      await app.settle();
      await app.tapText('Back to the topic');
      expect(find.textContaining('Next exam attempt from'), findsOneWidget);
      expect(find.text('Take the exam again'), findsNothing);
      expect(find.text('Exam history'), findsOneWidget);
      await app.tapText('Practise anyway (not counted)');
      expect(find.textContaining('Practice, not counted'), findsOneWidget);
      await app.tapText('Left');
      expect(find.text('Right.'), findsOneWidget, reason: 'practice gives feedback as before');
      expect(tester.takeException(), isNull);
      await app.close();
    },
  );

  testWidgets('handing in early: typed answers that do not match are marked by the learner', (tester) async {
    final now = DateTime(2026, 11, 27, 9);
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedExam);
    await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
    await app.go('Learn');
    await app.tapText('Pottery certificate');
    await app.tap(find.text('Wheel work').last);
    await app.tap(find.text('Mock exam').last);
    await app.tapText('Start the exam');
    await app.tapText('Start the exam');

    await app.tapText('Right');
    await app.tapText('Next');
    await app.enter('Your answer', 'the wheel');
    await app.tapText('Next');
    await app.enter('Your answer', 'loop tool');
    await app.tap(find.widgetWithText(FilledButton, 'Hand in'));
    expect(find.text('Hand in now?'), findsOneWidget);
    await app.tap(find.widgetWithText(FilledButton, 'Hand in').last);

    expect(find.text('Mark your answers'), findsOneWidget);
    expect(find.text('You wrote: the wheel'), findsOneWidget);
    expect(find.text('You wrote: loop tool'), findsOneWidget);
    await app.tap(find.text('I was wrong').first);
    await app.tap(find.text('I was right').last);
    await app.tapText('See my report');

    expect(find.text('33% · Not passed'), findsOneWidget);
    expect(find.textContaining('Time taken 00:00 of 01:00.'), findsOneWidget);
    expect(find.text('1. Centering'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('large text on a phone: the exam card, the rules, the timer and a question fit', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 27, 9);
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedExam);
    await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
    await app.go('Learn');
    await app.tapText('Pottery certificate');
    await app.tap(find.text('Wheel work').last);
    await app.tap(find.text('Mock exam').last);
    // Large text from the topic page on (the exam's own screens).
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.settle();
    expect(tester.takeException(), isNull, reason: 'the topic page and its exam card');
    await app.tapText('Start the exam');
    expect(tester.takeException(), isNull, reason: 'the rules');
    await app.tapText('Start the exam');
    expect(find.text('Question 1 of 3'), findsOneWidget);
    expect(find.bySemanticsLabel('Time left: 1 minute left'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('closing the app mid-exam keeps the attempt: it resumes with the time still running', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 27, 9);
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedExam);
    Future<void> openExam() async {
      await app.run(overrides: [examClockProvider.overrideWithValue(() => now)]);
      await app.go('Learn');
      await app.tapText('Pottery certificate');
      await app.tap(find.text('Wheel work').last);
      await app.tap(find.text('Mock exam').last);
      // With an attempt under way, the topic page offers to resume it.
      final resume = find.byKey(const Key('resume-exam'));
      await (resume.evaluate().isEmpty ? app.tapText('Start the exam') : app.tap(resume));
    }

    await openExam();
    await app.tapText('Start the exam');
    await app.tapText('Left');
    await app.tapText('Next');
    await app.enter('Your answer', 'the clay');
    await app.settle(); // the typed answer is saved after a short pause

    // The app is killed; 20 seconds pass; it is opened again.
    await tester.pumpWidget(const SizedBox());
    now = now.add(const Duration(seconds: 20));
    await openExam();
    expect(find.text('Question 2 of 3'), findsOneWidget, reason: 'straight back to where it was');
    expect(find.widgetWithText(TextField, 'the clay'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Time left: (39|40) seconds left')), findsOneWidget);

    // Killed again, and away past the end: handed in on reopening.
    await tester.pumpWidget(const SizedBox());
    now = now.add(const Duration(minutes: 5));
    await openExam();
    expect(find.text('67% · Passed'), findsOneWidget);
    expect(find.textContaining('(time ran out)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      expect(await app.book.db.select(app.book.db.learnAssessments).get(), hasLength(1));
      expect(
        await app.book.db.localSetting(
          'exam.progress.${(await app.book.db.select(app.book.db.learnItems).get()).firstWhere((i) => i.type == 'quiz').id}',
        ),
        '',
      );
    });
    await app.close();
  });
}
