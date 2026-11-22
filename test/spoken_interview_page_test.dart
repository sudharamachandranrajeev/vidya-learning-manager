// The spoken interviewer's screens with a fake voice, microphone and AI:
// models downloaded only on request, a spoken round with follow-ups, the
// debrief scored twice with quotes and anchors, a dispute that leaves the
// score alone, a typed round with no models and no AI, and the results on
// the drill. Made-up plan and answers.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:interview_engine/testing.dart';
import 'package:vidya/app/interview_providers.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/ui/interview_debrief_page.dart';
import 'package:vidya/ui/spoken_interview_page.dart';

import 'app_harness.dart';

const said =
    'Last spring I trained twelve new starters on the booking system. I wrote a one-page guide and ran short '
    'practice sessions, and every starter booked an appointment on their own by Friday.';
const quote = 'I wrote a one-page guide and ran short practice sessions';

Future<void> _seed(LearningBook b, {bool ai = false}) async {
  await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 2,
        'program': {'title': 'Approach: Example Trainer'},
        'role': 'Example Trainer',
        'criteria': [
          {'id': 'e1', 'text': 'Explain a new system to beginners', 'essential': true},
        ],
        'courses': [
          {
            'title': 'Teaching basics',
            'topics': [
              {
                'title': 'Explaining clearly',
                'criteria': ['e1'],
                'drills': [
                  {'question': 'Tell me about a time you taught a new system.', 'criterion': 'e1'},
                ],
              },
            ],
          },
        ],
      }),
    ),
    today: '2026-11-22',
  );
  await b.db.setLocalSetting(
    roundSettingsKey,
    jsonEncode({
      'round': const ie.RoundSettings(level: 2, aiPlan: false).toJson(),
      'framework': 'nhs_values',
    }),
  );
  if (ai) await b.db.setLocalSetting('ai.help', jsonEncode({'via': 'anthropic'}));
}

/// Scores every criterion the request lists at level 3, quoting [quote].
Map<String, Object?> _judge(ie.BrainRequest r) => {
  'answers': [
    {
      'question': 1,
      'scores': [
        for (final m in RegExp(r'<criterion id="([^"]+)"').allMatches(r.texts.first))
          {'criterion': m[1], 'level': '3', 'quote': quote},
      ],
      'strength': 'You said what you did yourself.',
      'fix': 'Say how you checked it worked.',
    },
  ],
};

Future<void> _openInterviewer(AppHarness app) async {
  await app.go('Learn');
  await app.tapText('Approach: Example Trainer');
  await app.tapText('Teaching basics');
  await app.tapText('Explaining clearly');
  await app.tap(find.textContaining('Tell me about a time you taught'));
  await app.tap(find.widgetWithText(FilledButton, 'Practise with the interviewer'));
  expect(find.byType(SpokenInterviewPage), findsOneWidget);
}

void main() {
  testWidgets(
    'a spoken round: download on request, follow-ups, scored twice, dispute, results on the drill',
    (tester) async {
      final engines = FakeSpokenEngines(missingIds: [ie.roundModelIds.first], answers: [spokenAnswer(said)]);
      final brain = ScriptedBrain(_judge);
      final app = AppHarness(tester)..desktop();
      await app.open(seed: (b) => _seed(b, ai: true));
      await app.run(
        overrides: [
          spokenEnginesProvider.overrideWith((ref) async => engines),
          modelSharingProvider.overrideWith(
            (ref) async => ie.modelSharingNote(app: 'vidya', shared: true, users: ['udyoga', 'vidya']),
          ),
          coachCameraProvider.overrideWith((ref) async => FakeCamera()),
          interviewBrainProvider.overrideWithValue(({required bool offline}) async => brain),
        ],
      );
      await _openInterviewer(app);
      expect(find.textContaining('shared with Udyoga'), findsWidgets);
      expect(find.textContaining('Camera setup check'), findsOneWidget);
      final model = ie.speechModel(ie.roundModelIds.first);
      // Nothing downloads until asked, and the size is shown first.
      expect(engines.downloads, isEmpty);
      await app.tap(find.text('Download ${ie.formatBytes(model.bytes)}').first);
      expect(find.text('Download ${model.label}?'), findsOneWidget);
      await app.tap(find.widgetWithText(FilledButton, 'Download ${ie.formatBytes(model.bytes)}'));
      expect(engines.downloads, [model.id]);

      await app.tapText('Start speaking');
      expect(engines.opened, hasLength(1));
      await app.tapText('Ask me');
      expect(engines.voice.said, anyElement(contains('Tell me about a time you taught a new system.')));
      for (var i = 0; i < 6 && find.text('Finish').evaluate().isEmpty; i++) {
        if (find.text('Done').evaluate().isNotEmpty) await app.tapText('Done');
        await app.settle();
      }
      expect(find.text('What you said (take 1)'), findsOneWidget);
      expect(find.text(said), findsWidgets, reason: 'the fake answers the follow-up with the same words');
      await app.tapText('Finish');
      expect(find.text('Round finished'), findsOneWidget);
      await app.tapText('See the debrief');
      expect(find.byType(InterviewDebriefPage), findsOneWidget);
      expect(engines.store.kept, isEmpty, reason: 'recordings go when the round screen closes');

      // Not scored yet: coverage from the words, and the button for the AI.
      expect(find.text('Read from your words on this device'), findsOneWidget);
      await app.tap(find.textContaining('Score on the scale with'));
      expect(brain.requests, hasLength(2), reason: 'scored twice');
      expect(find.text('Scored by your AI, twice'), findsOneWidget);
      expect(find.textContaining('This level:'), findsOneWidget);
      expect(find.textContaining('Next level (4):'), findsOneWidget);
      expect(find.text('"$quote"'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing, reason: 'no readiness percentage');

      await app.tapText('Dispute this score');
      await app.enter('What do you think it missed? (optional)', 'It deserves a 4.');
      await app.tapText('Check again');
      expect(find.text('The score stands'), findsOneWidget);
      await app.tapText('OK');

      final attempts = (await tester.runAsync(() async {
        final items = await app.book.db.select(app.book.db.learnItems).get();
        return app.book.drillAttempts(items.firstWhere((i) => i.type == 'interview drill').id);
      }))!;
      final a = DrillAttempt.parse(attempts.single.detail)!;
      expect((a.aiScored, a.levels.values.single, a.score), (true, '3', 6));

      await app.tapText('Add the fix to review');
      final cards = (await tester.runAsync(() => app.book.db.select(app.book.db.learnCards).get()))!;
      expect(cards.single.back, contains('Say how you checked it worked.'));
      expect(tester.takeException(), isNull);
      await app.close();
    },
  );

  testWidgets('a typed round with no models and no AI: self-rating saved on the drill', (tester) async {
    final engines = FakeSpokenEngines(missingIds: ie.roundModelIds);
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run(
      overrides: [
        spokenEnginesProvider.overrideWith((ref) async => engines),
        modelSharingProvider.overrideWith((ref) async => ie.modelSharingNote(app: 'vidya', shared: false)),
        coachCameraProvider.overrideWith((ref) async => FakeCamera()),
        interviewBrainProvider.overrideWithValue(({required bool offline}) async => null),
      ],
    );
    await _openInterviewer(app);
    expect(find.textContaining('Scoring on the scale needs an AI'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start speaking')).onPressed,
      isNull,
    );
    await app.tapText('Type my answers');
    expect(engines.opened, isEmpty, reason: 'no speech engine is opened for a typed round');
    await app.enter('Your answer', said);
    await app.tapText('Save answer');
    for (var i = 0; i < 4 && find.text('Finish').evaluate().isEmpty; i++) {
      // A follow-up is answered in the box too.
      if (find.widgetWithText(TextField, 'Your answer').evaluate().isNotEmpty) {
        await app.enter('Your answer', 'I checked every booking on Friday afternoon.');
        await app.tapText('Save answer');
      }
      await app.settle();
    }
    expect(find.text('Your answer (typed)'), findsOneWidget);
    await app.tapText('Finish');
    await app.tapText('See the debrief');
    expect(find.text('Read from your words on this device'), findsOneWidget);
    expect(find.textContaining('Score on the scale with'), findsNothing);
    for (final k in [0, 1, 2, 3]) {
      await app.tap(find.descendant(of: find.byKey(Key('round-check-0-$k')), matching: find.text('Yes')));
    }
    await app.tapText('Save my ratings on the drills');
    final a = (await tester.runAsync(() => app.book.db.select(app.book.db.learnAssessments).get()))!.single;
    final attempt = DrillAttempt.parse(a.detail)!;
    expect((attempt.aiScored, attempt.score), (false, 8));
    await app.tapText('Save as a story');
    expect((await tester.runAsync(() => app.book.storyBank()))!, hasLength(1));
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
