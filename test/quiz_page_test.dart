import 'dart:convert';

import 'package:brahma_core/brahma_core.dart'
    show HelpAi, HelpAiSetup, HelpAsker, HelpTurn, helpAskerProvider, today;
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/study_items.dart';

import 'app_harness.dart';

/// A made-up plan with long titles, so a phone screen has to wrap them.
Future<void> seedPlan(LearningBook b) => b.importCurriculum(
  parseCurriculum(
    jsonEncode({
      'format': 'vidya-curriculum',
      'version': 2,
      'program': {'title': 'Pottery teacher'},
      'courses': [
        {
          'title': 'Wheel basics for complete beginners who have never touched clay before',
          'topics': [
            {
              'title': 'Centering the clay on a fast wheel without it wobbling off',
              'items': [
                {
                  'type': 'video',
                  'title':
                      'A very long video title about centering that goes on and on so it must wrap twice',
                  'url': 'https://example.org/centering',
                  'minutes': 25,
                  'required': true,
                },
              ],
              'quiz': [
                {
                  'question': 'Which hand braces against the knee while centering on the wheel?',
                  'options': ['Left', 'Right'],
                  'answer': 'Left',
                  'explain': 'The left arm rests on the knee.',
                },
                {'question': 'What runs true?', 'answer': 'The clay', 'kind': 'short'},
                {'question': 'Name the removable wheel head', 'answer': 'A bat', 'kind': 'card'},
              ],
            },
          ],
        },
      ],
    }),
  ),
  today: today(),
);

void main() {
  testWidgets('the quiz runner on a phone: choice, short and card, then the score and review cards', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedPlan);
    await app.run();
    await app.go('Learn');
    await app.tapText('Pottery teacher');
    await app.tap(find.textContaining('Wheel basics for complete').last);
    await app.tap(find.text('Centering the clay on a fast wheel without it wobbling off').last);
    expect(find.text('Last quiz: not taken'), findsOneWidget);
    await app.tapText('Take the quiz');

    expect(find.text('Question 1 of 3'), findsOneWidget);
    await app.tapText('Left');
    expect(find.text('Right.'), findsOneWidget);
    expect(find.text('The left arm rests on the knee.'), findsOneWidget);
    await app.tapText('Next');

    await app.enter('Your answer', '  clay ');
    await app.tapText('Check');
    expect(find.text('Right.'), findsOneWidget, reason: 'a lenient match is marked by itself');
    await app.tapText('Next');

    await app.tapText('Show answer');
    expect(find.text('Answer: A bat'), findsOneWidget);
    await app.tapText('I did not');

    expect(find.text('2 of 3 right (67%)'), findsOneWidget);
    expect(find.textContaining('1 missed question is now review cards'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final cards = await (app.book.db.select(app.book.db.learnCards)..where((c) => c.deleted.not())).get();
      expect(cards.single.front, 'Name the removable wheel head');
    });

    await app.tapText('Back to the topic');
    expect(find.text('Last quiz: 67%'), findsOneWidget);
    expect(find.text('Take it again'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('Home on a phone: the next-up card resumes a video, and the weekly target shows progress', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        await seedPlan(b);
        final video = (await b.db.select(b.db.learnItems).get()).firstWhere((i) => i.type == 'video');
        await b.saveItem(video.copyWith(stoppedAt: '12:30'));
        await b.setWeekTarget(120);
        await b.logSession(40, today: today());
      },
    );
    await app.run();
    expect(find.text('Next up'), findsOneWidget);
    expect(find.textContaining('A very long video title about centering'), findsOneWidget);
    expect(find.textContaining('Resume at 12:30'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
    expect(find.text('Topic'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('of 120 min this week'));
    expect(find.textContaining('of 120 min this week'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // One tap on Topic opens the topic page.
    await app.tapText('Topic');
    expect(find.text('Why it matters'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('Home is calm when nothing is waiting', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open();
    await app.run();
    expect(find.text('Next up'), findsOneWidget);
    expect(find.textContaining('Nothing is waiting'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('questions on a phone: one typed by hand, then AI-written ones labelled AI', (tester) async {
    final asked = <String>[];
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        final cid = await b.addCourse('Glazes', today: today());
        await b.addTopic(cid, 'Mixing glazes safely');
        await b.db.setLocalSetting('ai.help', jsonEncode(const HelpAiSetup(via: HelpAi.openai).toJson()));
      },
    );
    await app.run(
      overrides: [
        helpAskerProvider.overrideWithValue(
          (setup) async => _FakeAsker(setup, (turns) {
            asked.add(turns.single.text);
            return '{"quiz": [{"question": "What do you wear when mixing dry glaze?", "kind": "short", '
                '"answer": "A mask", "explain": "Silica dust harms the lungs."}]}';
          }),
        ),
      ],
    );
    await app.go('Learn');
    await app.tapText('Glazes');
    await app.tapText('Mixing glazes safely');
    await app.tapText('Add questions');
    await app.tapText('Question');
    await app.enter('Question', 'What cone is mid-fire?');
    await app.enter('Answer', 'Cone 6');
    await app.tapText('Save');
    expect(find.textContaining('answer: Cone 6 · yours'), findsOneWidget);

    await app.tapText('Write questions with AI');
    expect(asked.single, contains('"Mixing glazes safely"'));
    expect(asked.single, contains('What cone is mid-fire?'), reason: 'asked not to repeat');
    expect(find.textContaining('answer: A mask · AI'), findsOneWidget);
    await tester.runAsync(() async {
      final quiz = (await app.book.db.select(app.book.db.learnItems).get()).single;
      expect(quizQuestions(quiz).map((q) => (q.own, q.ai)), [(true, false), (false, true)]);
      expect(topicQuiz([quiz]), isNotNull);
    });
    expect(tester.takeException(), isNull);
    await app.close();
  });
}

class _FakeAsker extends HelpAsker {
  _FakeAsker(super.setup, this.reply);
  final String Function(List<HelpTurn> turns) reply;

  @override
  Future<String> ask(String system, List<HelpTurn> turns) async => reply(turns);
}
