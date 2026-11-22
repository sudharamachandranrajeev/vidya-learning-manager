import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show StringExpressionOperators, Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart' show dismissAllToasts;
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/ui/interview_pages.dart';

import 'app_harness.dart';

/// A made-up plan with criteria and drills, a Udyoga story card and one
/// story of the learner's own.
Future<void> _seed(LearningBook b) async {
  await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 2,
        'program': {'title': 'Approach: Example Trainer'},
        'role': 'Example Trainer',
        'criteria': [
          {
            'id': 'e1',
            'text': 'Explain a new system to beginners who have never used one',
            'essential': true,
          },
          {'id': 'e2', 'text': 'Keep training records', 'essential': true},
        ],
        'courses': [
          {
            'title': 'Teaching basics',
            'topics': [
              {
                'title': 'Explaining clearly',
                'criteria': ['e1'],
                'drills': [
                  {
                    'question': 'Tell me about a time you taught a new system to a group that did not want to learn it.',
                    'criterion': 'e1',
                    'rubric': 'Who, what you did, what changed',
                  },
                ],
              },
            ],
          },
        ],
      }),
    ),
    today: '2026-11-21',
  );
  await b.db
      .into(b.db.learnCards)
      .insert(
        LearnCardsCompanion.insert(
          id: 'card1',
          front: 'Tell your story: Calm when the training room server failed (Resilience)',
          back:
              'Situation: The server failed ten minutes into a session for twelve new starters.\n'
              'Task: Keep the class learning.\nAction: I switched to the paper walkthrough.\nResult: We finished on time.',
          due: '2026-11-21',
          created: '2026-11-21',
          ref: const Value('udyoga.story.s1'),
        ),
      );
  await b.saveStory(
    title: 'A very long story title about the rota system that has to wrap on a small phone screen',
    situation: 'A ward moved to a new rota system.',
    task: 'I had to train twenty staff in one week.',
    action: 'I ran short sessions at every shift change.',
    result: 'Everyone used it by Friday.',
    today: '2026-11-21',
  );
}

Future<void> _openTopic(AppHarness app) async {
  await app.go('Learn');
  await app.tapText('Approach: Example Trainer');
  await app.tapText('Teaching basics');
  await app.tapText('Explaining clearly');
}

void main() {
  testWidgets('the drill runner on a phone: timer, scenario frame, self-rating, saved, sent to Udyoga', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await _openTopic(app);
    expect(find.textContaining('not practised yet'), findsOneWidget);
    await app.tap(find.textContaining('Tell me about a time you taught'));
    expect(find.byType(DrillPage), findsOneWidget);
    expect(find.text('Tests: Explain a new system to beginners who have never used one'), findsOneWidget);
    expect(find.textContaining('What a good answer covers'), findsOneWidget);
    expect(find.textContaining('does not record sound'), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await app.tap(find.byTooltip('30 seconds more'));
    expect(find.text('2:30'), findsOneWidget);
    await app.tapText('Start');
    await tester.pump(const Duration(seconds: 3));
    final shown = (tester.widget<Text>(find.byKey(const Key('drill-timer')))).data!;
    expect(shown, isNot('2:30'));
    await app.tapText('Pause');

    // Not a scenario question, but the frame can be switched on.
    expect(find.text('What I\'d check first'), findsNothing);
    await app.tap(find.text('Use the scenario frame'));
    await app.enter('What I\'d check first', 'Who has used the old system');
    await app.enter('When I\'d escalate', 'If a ward cannot work safely');

    await app.tapText('Save this attempt');
    expect(find.text('Rate all four checks first.'), findsOneWidget);
    for (final (k, pick) in [(0, 'Yes'), (1, 'Partly'), (2, 'Partly'), (3, 'No')]) {
      await app.tap(find.descendant(of: find.byKey(Key('check-$k')), matching: find.text(pick)));
    }
    expect(find.text('Score: 4/8 (weak, under 5)'), findsOneWidget);
    await app.tapText('Save this attempt');
    // The confirmation may queue behind an achievement toast; the attempt itself shows at once.
    expect(find.text('Past attempts'), findsOneWidget);
    expect(find.textContaining('What I\'d check first: Who has used the old system'), findsOneWidget);
    expect(find.textContaining('weak: comes first before the interview'), findsWidgets);

    final a = (await tester.runAsync(() => app.book.db.select(app.book.db.learnAssessments).get()))!.single;
    final attempt = DrillAttempt.parse(a.detail)!;
    expect(attempt.frame.check, 'Who has used the old system');
    expect(attempt.frame.escalate, 'If a ward cannot work safely');
    expect(attempt.score, 4);

    await app.tapText('Practise in Udyoga');
    final requests = (await tester.runAsync(() => app.book.practiseRequests()))!;
    expect(requests.single.question, startsWith('Tell me about a time you taught'));
    expect(find.text('Send to Udyoga again'), findsOneWidget);

    // Delete the attempt: the score goes. The toasts float over the foot of
    // the page, where the button is; swipe them away first.
    dismissAllToasts();
    await tester.pump(const Duration(seconds: 1));
    await app.tap(find.byTooltip('Delete attempt'));
    await app.tapText('Delete');
    expect(find.text('Past attempts'), findsNothing);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a score Udyoga wrote (its results fixture) shows on the drill, in the list and on the page', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        await _seed(b);
        final drill = (await (b.db.select(
          b.db.learnItems,
        )..where((i) => i.title.like('Tell me about a time you taught%'))).get()).single;
        // Written by Udyoga's tests for the drill named vidya-drill-q2.
        final plan = File('test/fixtures/udyoga-practise-results.json').readAsStringSync();
        await b.db
            .into(b.db.bridgeStudyPlans)
            .insert(
              BridgeStudyPlansCompanion.insert(
                id: practiseResultsId,
                source: 'udyoga',
                plan: plan.replaceAll('vidya-drill-q2', drill.id),
                updated: '2026-11-21T12:00:00Z',
              ),
            );
      },
    );
    await app.run();
    await _openTopic(app);
    expect(find.textContaining('Udyoga 2/2'), findsOneWidget);
    expect(find.textContaining('not practised yet'), findsNothing);
    await app.tap(find.textContaining('Tell me about a time you taught'));
    expect(find.byType(DrillPage), findsOneWidget);
    expect(find.textContaining('Udyoga 2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('the story bank on a phone: STAR and CAR views, link a story to a criterion and a drill', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await _openTopic(app);
    await app.tapText('Story bank');
    expect(find.byType(StoryBankPage), findsOneWidget);
    expect(find.text('From Udyoga (edit it there)'), findsOneWidget);
    expect(find.text('Yours'), findsOneWidget);
    expect(find.textContaining('Situation: A ward moved'), findsOneWidget);
    expect(find.textContaining('Context:'), findsNothing);
    expect(tester.takeException(), isNull);

    await app.tapText('CAR');
    expect(find.textContaining('Situation:'), findsNothing);
    expect(
      find.textContaining(
        'Context: A ward moved to a new rota system. I had to train twenty staff in one week.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Context: The server failed'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Link the Udyoga story to a criterion and the drill.
    final calm = find.ancestor(
      of: find.text('Calm when the training room server failed'),
      matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_StoryCard'),
    );
    await app.tap(find.descendant(of: calm, matching: find.text('Link to criteria and drills')));
    await app.tap(
      find.widgetWithText(FilterChip, 'Explain a new system to beginners who have never used one'),
    );
    await app.tap(find.byType(FilterChip).last);
    await app.tapText('Save');
    expect(
      find.descendant(of: calm, matching: find.textContaining('Shows: Explain a new system')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: calm, matching: find.textContaining('Answers: Tell me about')),
      findsOneWidget,
    );

    // A new story of your own.
    await app.tap(find.text('Story').last);
    await app.enter('Title', 'Records audit');
    await app.tapText('Save');
    expect(find.text('Say what you did (the Action).'), findsOneWidget);
    await app.enter('Action', 'I rebuilt the training log.');
    await app.tapText('Save');
    expect(find.text('Records audit'), findsOneWidget);
    expect(find.textContaining('Action: I rebuilt the training log.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final bank = (await tester.runAsync(() => app.book.storyBank()))!;
    final s = bank.firstWhere((s) => s.fromUdyoga);
    expect(s.criteria, hasLength(1));
    expect(s.drills, hasLength(1));
    await app.close();
  });

  testWidgets('before the interview and the feedback log on a phone', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await app.go('Learn');
    await app.tapText('Approach: Example Trainer');
    await app.tap(find.byTooltip('Interview training'));
    expect(find.byType(BeforeInterviewPage), findsOneWidget);
    expect(find.text('1. Weak criteria'), findsOneWidget);
    expect(find.text('Explain a new system to beginners who have never used one'), findsOneWidget);
    // The same status and reason Job readiness gives each criterion.
    expect(find.textContaining('Essential · Missing'), findsOneWidget);
    expect(find.textContaining('Essential · Weak · Only planned so far'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await app.tapText('Log a real interview');
    expect(find.byType(FeedbackPage), findsOneWidget);
    await app.enter('Employer and role', 'Example Trust, trainer');
    await app.tap(find.widgetWithText(FilterChip, 'Keep training records'));
    await app.enter('Questions that went badly (one per line)', 'Why do you want this job?');
    expect(tester.takeException(), isNull);
    await app.tapText('Save the log');
    expect(find.byType(BeforeInterviewPage), findsOneWidget);
    expect(find.text('Tell me about a time you showed: Keep training records'), findsOneWidget);
    final notes = (await tester.runAsync(() => app.book.db.select(app.book.db.learnNotes).get()))!;
    expect(notes.where((n) => n.tags == feedbackTag), hasLength(1));
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
