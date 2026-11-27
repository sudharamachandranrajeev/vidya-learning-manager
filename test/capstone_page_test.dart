// Capstone and cross-examination screens (assess plan A3) with no audio:
// the capstone card on the course page, a sitting rated on the four
// checks, the result with each drill on the 1–5 scale and the passes in a
// row; a drill's plan panel preselected in the interviewer; and a
// challenging round's debrief with its delivery ranges (never a score).
// Made-up plan and answers.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show today;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:interview_engine/testing.dart';
import 'package:vidya/app/interview_providers.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/capstone.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/spoken_interview.dart';
import 'package:vidya/ui/capstone_page.dart';
import 'package:vidya/ui/interview_debrief_page.dart';
import 'package:vidya/ui/spoken_interview_page.dart';

import 'app_harness.dart';

Future<void> _seed(LearningBook b) async {
  await b.importCurriculum(
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
                  {
                    'id': 'd2',
                    'question': 'Why did you not report the swarm sooner?',
                    'persona': 'challenging',
                    'ladder': 2,
                  },
                ],
                'capstone': {
                  'drills': ['d1', 'd2'],
                  'average': 4.0,
                  'minimum': 3,
                  'passesInRow': 2,
                  'minutes': 45,
                },
              },
            ],
          },
        ],
      }),
    ),
    today: today(),
  );
}

List<Override> _noAudio() => [
  spokenEnginesProvider.overrideWith((ref) async => FakeSpokenEngines(missingIds: ie.roundModelIds)),
  modelSharingProvider.overrideWith((ref) async => ie.modelSharingNote(app: 'vidya', shared: false)),
  coachCameraProvider.overrideWith((ref) async => FakeCamera()),
  interviewBrainProvider.overrideWithValue(({required bool offline}) async => null),
];

Future<void> _rate(AppHarness app, String prefix, List<String> answers) async {
  for (final (k, a) in answers.indexed) {
    await app.tap(find.descendant(of: find.byKey(Key('$prefix$k')), matching: find.text(a)));
  }
}

void main() {
  testWidgets('a capstone sitting: each drill on its panel, the result on 1–5, passes in a row', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    await app.open(seed: _seed);
    await app.run(overrides: _noAudio());
    await app.go('Learn');
    await app.tapText('Apiary lead');
    await app.tapText('Hive leadership');
    expect(find.text('Capstone'), findsOneWidget);
    expect(find.textContaining('2 drills in one sitting'), findsOneWidget);
    expect(find.textContaining('0 of 2 passes in a row'), findsOneWidget);
    await app.tapText('Start capstone');
    expect(find.byType(CapstonePage), findsOneWidget);
    expect(find.text('Challenging panel, level 2'), findsOneWidget);
    expect(find.textContaining(challengingAbout), findsOneWidget);
    await app.tap(find.widgetWithText(FilledButton, 'Start capstone'));

    // Drill 1: the learner's usual panel; rated all Yes, 8/8 is 5/5.
    expect(find.byKey(const Key('capstone-clock')), findsOneWidget);
    expect(find.textContaining('of 45:00'), findsOneWidget);
    expect(find.text('Drill 1 of 2'), findsOneWidget);
    expect(find.text('Your usual panel'), findsOneWidget);
    await app.tapText('Next drill');
    expect(find.text('Drill 1 of 2'), findsOneWidget, reason: 'not rated yet');
    await _rate(app, 'cap-check-', ['Yes', 'Yes', 'Yes', 'Yes']);
    expect(find.text('Score: 5/5 (8/8)'), findsOneWidget);
    await app.tapText('Next drill');

    // Drill 2: the challenging panel the plan set; 6/8 is 4/5.
    expect(find.text('Drill 2 of 2'), findsOneWidget);
    expect(find.text('Challenging panel, level 2'), findsOneWidget);
    expect(find.text(challengingAbout), findsOneWidget);
    await _rate(app, 'cap-check-', ['Yes', 'Yes', 'Partly', 'Partly']);
    await app.tapText('Finish');
    expect(find.text('Passed'), findsWidgets);
    expect(find.text('5/5'), findsOneWidget);
    expect(find.text('4/5'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('capstone-verdict'))).data,
      'Average 4.5/5 (needs 4.0) · lowest 4/5 (needs 3)',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('capstone-result-streak'))).data,
      '1 of 2 passes in a row',
    );

    final db = app.book.db;
    final rows = (await tester.runAsync(() => db.select(db.learnAssessments).get()))!;
    expect(
      rows.where((a) => DrillAttempt.parse(a.detail) != null),
      hasLength(2),
      reason: 'on the drills too',
    );
    final sitting = CapstoneSitting.parse(rows.singleWhere((a) => a.max == 5).detail)!;
    expect([for (final d in sitting.drills) d.of5], [5, 4]);
    expect(sitting.drills.last.persona, 'challenging');

    // A second sitting with a skipped drill fails and resets the count.
    await app.tapText('Back to the capstone');
    expect(find.text('1 of 2 passes in a row'), findsOneWidget);
    await app.tap(find.widgetWithText(FilledButton, 'Start capstone'));
    await app.tapText('Skip this drill');
    await app.tapText('Skip this drill');
    expect(find.text('Not passed'), findsWidgets);
    expect(find.text('skipped'), findsNWidgets(2));
    expect(
      tester.widget<Text>(find.byKey(const Key('capstone-result-streak'))).data,
      '0 of 2 passes in a row',
    );
    expect(find.text('A sitting that does not pass starts the count again.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('the interviewer opens on the panel and level the plan set; the learner can change them', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run(overrides: _noAudio());
    await app.go('Learn');
    await app.tapText('Apiary lead');
    await app.tapText('Hive leadership');
    await app.tapText('Inspections');
    // The capstone card is on the topic page too.
    expect(find.textContaining('2 drills in one sitting'), findsOneWidget);
    await app.tap(find.textContaining('Why did you not report the swarm'));
    expect(find.textContaining('Last here').evaluate().isEmpty, isTrue);
    await app.tap(find.widgetWithText(FilledButton, 'Practise with the interviewer'));
    expect(find.byType(SpokenInterviewPage), findsOneWidget);
    expect(find.text(challengingAbout), findsOneWidget);
    expect(find.byKey(const Key('safe-rehearsal')), findsOneWidget);
    expect(find.text('Set by the plan for this drill. You can change it.'), findsOneWidget);
    expect(find.text(ie.Ladder.of(2).about), findsOneWidget);
    // Nothing from the plan is saved as the learner's own settings.
    final saved = await tester.runAsync(() => app.book.db.localSetting(roundSettingsKey));
    expect(saved ?? '', isNot(contains('challenging')));
    // The learner changes the panel: their choice is used and saved.
    await app.tap(find.text('Challenging').first);
    await app.tapText('Neutral');
    expect(find.text(challengingAbout), findsNothing);
    expect(find.text(ie.Persona.of(ie.PersonaKind.neutral).about), findsOneWidget);
    final after = await tester.runAsync(() => app.book.db.localSetting(roundSettingsKey));
    expect(jsonDecode(after!)['round']['persona'], 'neutral');
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a challenging round\'s debrief: rating on 1–5 and delivery ranges, never a score', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    late String roundId;
    await app.open(
      seed: (b) async {
        await _seed(b);
        roundId = await b.startRound(
          title: 'Apiary lead',
          framework: 'private',
          settings: const ie.RoundSettings(persona: ie.PersonaKind.challenging, level: 2),
          questions: [
            ie.EngineQuestion({'question': 'Why did you not report the swarm sooner?'}),
          ],
          criteria: const [],
          today: today(),
        );
        await b.saveRoundAnswer(roundId, 0, 'I checked the hive on Monday and reported it the same day.');
        await b.saveRoundDeliveries(roundId, 0, [
          [
            const RoundDelivery(
              label: 'Pace',
              value: '190 words a minute',
              usual: 'Usual: 120 to 170 words a minute',
              place: 'above',
            ),
          ],
          [const RoundDelivery(label: 'Pauses', value: 'No pauses of a second or more')],
        ]);
      },
    );
    await app.run(overrides: _noAudio());
    openInterviewDebrief(tester.element(find.byType(Scaffold).first), roundId);
    await app.settle();
    expect(find.byType(InterviewDebriefPage), findsOneWidget);
    await app.tapText('How you held up (delivery)');
    expect(find.text('Pace: 190 words a minute · above the usual range'), findsOneWidget);
    expect(find.text('Reply to follow-up 1'), findsOneWidget);
    expect(find.textContaining('not a score'), findsOneWidget);
    for (final k in [0, 1, 2, 3]) {
      await app.tap(find.descendant(of: find.byKey(Key('round-check-0-$k')), matching: find.text('Partly')));
    }
    expect(tester.widget<Text>(find.byKey(const Key('rubric-0'))).data, 'Your rating: 3/5 (4/8)');
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
