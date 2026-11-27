import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/ui/readiness_page.dart';
import 'package:vidya/ui/topic_page.dart';

import 'app_harness.dart';

/// A made-up role plan with long criteria (to wrap on a phone), one row
/// covered by a drill, an interview in six days.
Future<void> _seed(LearningBook b) async {
  final day = today();
  final r = await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 2,
        'program': {'title': 'Approach: Example Trainer'},
        'role': 'Example Trainer',
        'criteria': [
          {
            'id': 'e1',
            'text':
                'Explain a new clinical system to beginners who have never used one before, in plain words',
            'essential': true,
          },
          {'id': 'e2', 'text': 'Keep accurate training records', 'essential': true},
          {'id': 'e3', 'text': 'Teaching qualification', 'essential': true, 'source': 'AI', 'shown': true},
          {'id': 'd1', 'text': 'Write short quick-start guides', 'essential': false},
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
                    'id': 'q1',
                    'question': 'Tell me about a time you taught a new system.',
                    'criterion': 'e1',
                  },
                ],
              },
              {
                'title': 'Records',
                'criteria': ['e2', 'e3'],
                'quiz': [
                  {'question': 'Where do records go?', 'answer': 'The log'},
                ],
              },
            ],
          },
        ],
      }),
    ),
    today: day,
  );
  final drill = (await (b.db.select(b.db.learnItems)..where((i) => i.ref.equals('q1'))).get()).single;
  await b.recordDrill(drill, const DrillAttempt(checks: [2, 2, 1, 1]), today: day);
  await b.setInterviewDate(r.programId, addDays(day, 6));
}

void main() {
  testWidgets('the Readiness page on a phone: counts, next action, evidence, a typed-in criterion', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await app.go('Learn');
    await app.tapText('Approach: Example Trainer');
    expect(find.text('Job readiness'), findsOneWidget);
    expect(find.textContaining('1 of 3 essential covered'), findsOneWidget);
    await app.tapText('Job readiness');
    expect(find.byType(ReadinessPage), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('readiness-summary'))).data,
      '1 of 3 essential covered, 2 weak · desirable 0 of 1 · interview in 6 days',
    );
    expect(find.text('Essential'), findsWidgets);
    expect(find.text('Desirable'), findsOneWidget);
    expect(find.text('Covered'), findsOneWidget);
    expect(find.text('Weak'), findsNWidgets(2));
    expect(find.text('Missing'), findsOneWidget);
    // The weakest essential row is Records (planned only): take its quiz.
    expect(find.text('Take the quiz on Records'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Open the covered row: its drill evidence.
    await app.tap(find.textContaining('Explain a new clinical system'));
    expect(find.textContaining('Drill 4/5 (6/8) on'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The AI-sourced row lists the CV flag but stays weak.
    await app.tap(find.text('Teaching qualification'));
    expect(find.text('Your CV shows this'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tap through to the topic from the evidence list.
    await app.tap(find.text('Explaining clearly').first);
    expect(find.byType(TopicPage), findsOneWidget);
    await tester.pageBack();
    await app.settle();

    // Type in a person-spec row and link it to a topic.
    await app.tap(find.byTooltip('Add a criterion'));
    await app.tapText('Save');
    expect(find.text('Type what the job asks for.'), findsOneWidget);
    await app.enter(
      'What the job asks for',
      'Experience of delivering training to adults in a hospital setting',
    );
    await app.tap(find.widgetWithText(FilterChip, 'Records'));
    await app.tapText('Save');
    expect(find.textContaining('Experience of delivering training to adults'), findsOneWidget);
    expect(find.textContaining('1 of 4 essential covered'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final pid = (await tester.runAsync(() => app.book.db.select(app.book.db.learnPrograms).get()))!.single.id;
    final crit = (await tester.runAsync(() => app.book.programCriteria(pid)))!;
    final own = crit.where(isOwnCriterion).single;
    expect(own.essential, isTrue);
    await app.close();
  });

  testWidgets('Home shows the readiness card for the program with the nearest interview', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    expect(find.byType(ReadinessCard), findsOneWidget);
    await tester.ensureVisible(find.byType(ReadinessCard));
    await tester.pump();
    expect(find.text('Ready for Example Trainer?'), findsOneWidget);
    expect(
      find.textContaining('1 of 3 essential covered, 2 weak · desirable 0 of 1 · interview in 6 days'),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(ReadinessCard), matching: find.text('Take the quiz on Records')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await app.tap(find.text('See every criterion'));
    expect(find.byType(ReadinessPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('no card on Home and an empty Readiness page without criteria', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: (b) async => b.addProgram('Data analyst', '', today: today()));
    await app.run();
    expect(find.textContaining('Ready for'), findsNothing);
    await app.go('Learn');
    await app.tapText('Data analyst');
    expect(find.textContaining('Add the job\'s criteria'), findsOneWidget);
    await app.tapText('Job readiness');
    expect(find.text('No criteria yet'), findsWidgets);
    await app.tapText('Add a criterion');
    await app.enter('What the job asks for', 'SQL');
    await app.tapText('Save');
    expect(find.text('0 of 1 essential covered, 1 missing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
