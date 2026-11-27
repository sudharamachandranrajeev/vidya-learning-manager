import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/udyoga_link.dart';

import 'support.dart';

const today = '2026-11-21';

/// A made-up care-trainer plan: four criteria, three topics (one with a
/// quiz), and drills, one of them a scenario question.
Map<String, Object?> plan() => {
  'format': 'vidya-curriculum',
  'version': 2,
  'program': {'title': 'Approach: Example Trainer'},
  'role': 'Example Trainer',
  'criteria': [
    {'id': 'e1', 'text': 'Explain a system to beginners', 'essential': true},
    {'id': 'e2', 'text': 'Handle a difficult learner calmly', 'essential': true},
    {'id': 'e3', 'text': 'Keep training records', 'essential': true},
    {'id': 'd1', 'text': 'Write short guides', 'essential': false},
  ],
  'courses': [
    {
      'title': 'Teaching basics',
      'topics': [
        {
          'title': 'Explaining clearly',
          'criteria': ['e1'],
          'quiz': [
            {'question': 'Plain words or jargon?', 'answer': 'Plain words'},
          ],
          'drills': [
            {'id': 'q1', 'question': 'Tell me about a time you taught a new system.', 'criterion': 'e1'},
          ],
        },
        {
          'title': 'Difficult moments',
          'criteria': ['e2'],
          'drills': [
            {'id': 'q2', 'question': 'Tell me about a time a learner got angry.', 'criterion': 'e2'},
            {
              'id': 'q3',
              'question': 'What would you do if a learner shared a password in class?',
              'criterion': 'e2',
            },
          ],
        },
        {
          'title': 'Guides',
          'criteria': ['d1'],
          'drills': [
            {'id': 'q4', 'question': 'How do you write a quick-start guide?', 'criterion': 'd1'},
          ],
        },
      ],
    },
  ],
};

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  Future<String> importPlan() async =>
      (await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today)).programId;

  Future<StudyItem> drill(String ref) async =>
      (await (db.select(db.learnItems)..where((i) => i.ref.equals(ref))).get()).single;

  group('scoring', () {
    test('four checks of 0-2 make a score out of 8; under 5 is weak', () {
      expect(drillScore([2, 2, 2, 2]), 8);
      expect(drillScore([2, 1, 1, 0]), 4);
      expect(drillWeak(4), isTrue);
      expect(drillScore([2, 2, 1, 0]), 5);
      expect(drillWeak(5), isFalse);
      expect(drillScore([5, -1, 2, 2, 2]), 6, reason: 'each kept to 0-2; a fifth is ignored');
      expect(const DrillAttempt(checks: [1, 1, 1, 1]).weak, isTrue);
    });

    test('a saved attempt is a result on the topic and the drill; weak drills are flagged', () async {
      await importPlan();
      final d = await drill('q1');
      final id = await book.recordDrill(
        d,
        const DrillAttempt(checks: [2, 1, 1, 0], seconds: 95, note: 'Say the result sooner'),
        today: today,
      );
      final a = await (db.select(db.learnAssessments)..where((x) => x.id.equals(id))).getSingle();
      expect((a.itemId, a.topicId, a.score, a.max), (d.id, d.topicId, 4.0, 8.0));
      expect(a.title, startsWith('Drill: Tell me about a time'));
      final back = DrillAttempt.parse(a.detail)!;
      expect(back.checks, [2, 1, 1, 0]);
      expect((back.seconds, back.note), (95, 'Say the result sooner'));
      expect((await drill('q1')).done, today);
      // A drill attempt is not a quiz score.
      expect(lastQuizPercents(await db.select(db.learnAssessments).get())[d.topicId], isNull);

      var e = (await book.drillEvidence([d.id]))[d.id]!;
      expect((e.own, e.attempts, e.weak), (4, 1, true));
      await book.recordDrill(d, const DrillAttempt(checks: [2, 2, 1, 1]), today: '2026-11-22');
      e = (await book.drillEvidence([d.id]))[d.id]!;
      expect((e.own, e.attempts, e.weak), (6, 2, false));
      expect((await book.drillAttempts(d.id)).map((a) => a.score), [6.0, 4.0]);
    });
  });

  group('scenario frame', () {
    test('scenario questions are recognised and the frame is saved with the attempt', () async {
      expect(isScenarioQuestion('What would you do if a learner shared a password?'), isTrue);
      expect(isScenarioQuestion('Imagine the system goes down during training.'), isTrue);
      expect(isScenarioQuestion('How would you handle a complaint?'), isTrue);
      expect(isScenarioQuestion('Tell me about a time you taught a new system.'), isFalse);

      await importPlan();
      final d = await drill('q3');
      expect(isScenarioDrill(d), isTrue);
      expect(isScenarioDrill(await drill('q2')), isFalse);
      final id = await book.recordDrill(
        d,
        const DrillAttempt(
          checks: [2, 2, 2, 1],
          frame: ScenarioFrame(
            check: 'Whether the account was used',
            scope: 'I do not reset passwords myself',
            escalate: 'Tell the IT service desk at once',
            handover: 'Note it in the session log',
          ),
        ),
        today: today,
      );
      final a = await (db.select(db.learnAssessments)..where((x) => x.id.equals(id))).getSingle();
      final f = DrillAttempt.parse(a.detail)!.frame;
      expect(
        [for (final (k, _) in ScenarioFrame.parts) f.part(k)],
        [
          'Whether the account was used',
          'I do not reset passwords myself',
          'Tell the IT service desk at once',
          'Note it in the session log',
        ],
      );
      expect(jsonDecode(a.detail)['frame'], hasLength(4));
      // A drill can say it is a scenario itself.
      final topic = d.topicId;
      await book.addDrill(topic, 'Tell me about your week', scenario: true);
      final own = (await (db.select(
        db.learnItems,
      )..where((i) => i.title.equals('Tell me about your week'))).getSingle());
      expect(isScenarioDrill(own), isTrue);
    });
  });

  group('stories', () {
    test('one story, stored once, shows as STAR and as CAR', () async {
      final id = await book.saveStory(
        title: 'The new rota system',
        situation: 'A ward moved to a new rota system.',
        task: 'I had to train 20 staff in a week.',
        action: 'I ran short sessions at shift change.',
        result: 'Everyone used it by Friday.',
        today: today,
      );
      final s = (await book.storyBank()).single;
      expect(s.id, id);
      expect(s.star.map((p) => p.$1), ['Situation', 'Task', 'Action', 'Result']);
      expect(s.car.map((p) => p.$1), ['Context', 'Action', 'Result']);
      expect(s.car.first.$2, 'A ward moved to a new rota system. I had to train 20 staff in a week.');
      expect(s.car[1].$2, s.star[2].$2);
      expect(s.car[2].$2, s.star[3].$2);
      // Editing the text changes both views.
      await book.saveStory(id: id, title: s.title, situation: 'Changed.', action: 'Did it.', today: today);
      final e = (await book.storyBank()).single;
      expect(e.star.map((p) => p.$1), ['Situation', 'Action']);
      expect(e.car.first, ('Context', 'Changed.'));
    });

    test('a Udyoga story card reads as a story, and links go in its own row', () async {
      await db
          .into(db.learnCards)
          .insert(
            LearnCardsCompanion.insert(
              id: 'card1',
              front: 'Tell your story: Calm in a crisis (Teamwork; Resilience)',
              back: 'Situation: The server failed.\nTask: Keep the class going.\nAction: I switched to paper.\nResult: No lost time.',
              due: today,
              created: today,
              ref: const Value('udyoga.story.s1'),
              plan: const Value('interview ready'),
            ),
          );
      await importPlan();
      var s = (await book.storyBank()).single;
      expect((s.title, s.fromUdyoga, s.udyogaId), ('Calm in a crisis', true, 's1'));
      expect(s.car.first.$2, 'The server failed. Keep the class going.');
      expect(s.id, udyogaStoryRowId('udyoga.story.s1'));

      final pid = (await db.select(db.learnPrograms).get()).single.id;
      final e2 = (await book.programCriteria(pid)).firstWhere((c) => c.ref == 'e2');
      final q2 = await drill('q2');
      await book.linkStory(s, criteria: [e2.id], drills: [q2.id], today: today);
      s = (await book.storyBank()).single;
      expect(s.criteria, [e2.id]);
      expect(s.drills, [q2.id]);
      final row = await (db.select(db.learnStories)..where((r) => r.id.equals(s.id))).getSingle();
      expect((row.ref, row.action), ('udyoga.story.s1', ''), reason: 'the text stays on the card');
      // Removing the links keeps the story (it is Udyoga's).
      await book.deleteStory(s);
      s = (await book.storyBank()).single;
      expect(s.criteria, isEmpty);
      expect(s.drills, isEmpty);
    });
  });

  group('before the interview', () {
    test('weak criteria first (essential, no evidence, low), then their stories, then drills', () async {
      final pid = await importPlan();
      final criteria = await book.programCriteria(pid);
      String cid(String ref) => criteria.firstWhere((c) => c.ref == ref).id;

      // e1: quiz passed, so covered.
      final quiz = (await (db.select(db.learnItems)..where((i) => i.type.equals('quiz'))).get()).single;
      await book.recordQuiz(quiz, [true], today: today);
      // e2: one drill tried and weak; the scenario drill not practised.
      await book.recordDrill(await drill('q2'), const DrillAttempt(checks: [1, 1, 1, 0]), today: today);
      // d1: its drill scored well, but desirable criteria come after essential ones anyway.
      await book.recordDrill(await drill('q4'), const DrillAttempt(checks: [2, 2, 2, 2]), today: today);
      final story = await book.saveStory(
        title: 'Angry learner',
        action: 'I listened, then paused the session.',
        criteria: [cid('e2')],
        today: today,
      );
      await book.saveStory(title: 'Unlinked story', action: 'Something else.', today: today);
      await book.setInterviewDate(pid, '2026-11-27');

      final b = await book.beforeInterview(pid, day: today);
      expect([for (final c in b.weak) c.criterion.ref], ['e3', 'e2']);
      expect([for (final c in b.weak) c.state], [CriterionState.missing, CriterionState.weak]);
      expect(b.weak[1].evidence.single, startsWith('Drill 3/5 (3/8):'));
      expect({for (final c in b.covered) c.criterion.ref}, {'e1', 'd1'});
      expect(b.stories.map((s) => s.id), [story]);
      expect(
        [for (final d in b.drills) d.item.ref],
        ['q2', 'q3', 'q1', 'q4'],
        reason: 'weak first, then unpractised on a weak criterion, then unpractised, then the rest',
      );
      expect(b.drills.first.evidence.weak, isTrue);
      expect(b.interviewDate, '2026-11-27');
      expect(interviewCountdown(b.interviewDate!, today), 'Interview in 6 days');
      expect(interviewCountdown('2026-11-22', today), 'Interview tomorrow');
      expect(interviewCountdown('2026-11-18', today), 'Interview was 3 days ago');
      await book.setInterviewDate(pid, null);
      expect(await book.interviewDate(pid), isNull);
    });
    test('it agrees with Job readiness: the same status for each criterion, weakest first', () async {
      final pid = await importPlan();
      final guides = (await db.select(db.learnTopics).get()).firstWhere((t) => t.title == 'Guides');
      // Only an open topic works towards it: Job readiness calls that weak
      // (only planned), not missing, and so must this page.
      final own = await book.saveOwnCriterion(
        pid,
        body: 'Use the booking system',
        essential: true,
        topicIds: [guides.id],
      );
      await book.recordDrill(await drill('q4'), const DrillAttempt(checks: [2, 2, 2, 2]), today: today);
      await book.recordDrill(await drill('q2'), const DrillAttempt(checks: [1, 1, 1, 0]), today: today);

      final b = await book.beforeInterview(pid, day: today);
      final r = await book.readiness(pid, today: today);
      final status = {for (final row in r.rows) row.criterion.id: row.status};
      for (final c in [...b.weak, ...b.covered]) {
        expect(c.state, status[c.criterion.id], reason: c.criterion.body);
      }
      expect(b.weak.length + b.covered.length, r.rows.length);
      final ownCheck = b.weak.firstWhere((c) => c.criterion.id == own);
      expect(ownCheck.state, ReadinessStatus.weak);
      expect(ownCheck.reasons, [WeakReason.planned]);
      // Essential first, then weakest first by Job readiness's rank: e3 has
      // nothing (missing), then the two only planned (plan order), then the
      // low drill on e2.
      final expected = [
        for (final row in r.rows)
          if (row.status != ReadinessStatus.covered) row,
      ]..sort((a, b) => a.essential != b.essential ? (a.essential ? -1 : 1) : a.rank.compareTo(b.rank));
      expect([for (final c in b.weak) c.criterion.id], [for (final row in expected) row.criterion.id]);
      expect([for (final c in b.weak) c.criterion.ref], ['e3', 'e1', 'own.$own', 'e2']);
    });
  });

  group('after a real interview', () {
    test('the feedback log is a note and each weak spot becomes a drill on a linked topic', () async {
      final pid = await importPlan();
      final criteria = await book.programCriteria(pid);
      String cid(String ref) => criteria.firstWhere((c) => c.ref == ref).id;
      final r = await book.logInterviewFeedback(
        pid,
        InterviewFeedback(
          day: '2026-11-20',
          role: 'Example Health Board, trainer',
          criteria: [cid('e2'), cid('e3')],
          questions: ['Why this role?', '  '],
          notes: 'Too long on the first answer.',
        ),
        today: today,
      );
      final note = await (db.select(db.learnNotes)..where((n) => n.id.equals(r.noteId))).getSingle();
      expect(note.tags, feedbackTag);
      expect(note.title, 'Interview feedback: Example Health Board, trainer (20 Nov 2026)');
      expect(note.body, contains('- Criterion: Handle a difficult learner calmly'));
      expect(note.body, contains('- Question: Why this role?'));
      expect(note.body, contains('Too long on the first answer.'));
      expect(r.items, hasLength(3));

      final items = await (db.select(db.learnItems)..where((i) => i.id.isIn(r.items))).get();
      final topics = {for (final t in await db.select(db.learnTopics).get()) t.id: t};
      final byQuestion = {for (final i in items) i.title: i};
      // e2 has a topic: the drill goes there.
      final e2Drill = byQuestion['Tell me about a time you showed: Handle a difficult learner calmly']!;
      expect(topics[e2Drill.topicId]!.title, 'Difficult moments');
      expect(e2Drill.type, 'interview drill');
      // e3 has none: an "Interview follow-ups" topic is made and linked to it.
      final e3Drill = byQuestion['Tell me about a time you showed: Keep training records']!;
      final followUps = topics[e3Drill.topicId]!;
      expect(followUps.title, followUpsTitle);
      expect(followUps.criteria, 'e3');
      expect(topics[byQuestion['Why this role?']!.topicId]!.id, followUps.id);

      // A second log reuses the same follow-ups topic.
      final r2 = await book.logInterviewFeedback(
        pid,
        InterviewFeedback(day: today, criteria: [cid('e3')]),
        today: today,
      );
      final again = await (db.select(db.learnItems)..where((i) => i.id.isIn(r2.items))).getSingle();
      expect(again.topicId, followUps.id);
      expect((await db.select(db.learnTopics).get()).where((t) => t.title == followUpsTitle), hasLength(1));
    });
  });

  group('Udyoga hand-off', () {
    Future<StudyProgressRow?> requests() =>
        (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals(practiseRequestsId))).getSingleOrNull();

    test('a drill handed to Udyoga is a request row of this exact shape', () async {
      await importPlan();
      final q2 = await drill('q2');
      await book.askUdyogaToPractise(q2, now: '2026-11-21T09:00:00.000Z');
      final row = (await requests())!;
      expect(row.planUpdated, '');
      expect(jsonDecode(row.progress), {
        'learning': <Object>[],
        'skills': <Object>[],
        'format': 'vidya-practise-requests',
        'version': 1,
        'requests': [
          {
            'id': q2.id,
            'ref': 'q2',
            'question': 'Tell me about a time a learner got angry.',
            'criterion': 'Handle a difficult learner calmly',
            'role': 'Example Trainer',
            'topic': 'Difficult moments',
            'asked': '2026-11-21T09:00:00.000Z',
          },
        ],
      });
      // Any reader of study progress sees an empty progress.
      final p = StudyProgress.parse(row.progress);
      expect(p.learning, isEmpty);
      expect(p.skills, isEmpty);

      // Asking again moves it to the top without a twin; others stay.
      final q1 = await drill('q1');
      await book.askUdyogaToPractise(q1, now: '2026-11-21T10:00:00.000Z');
      await book.askUdyogaToPractise(q2, now: '2026-11-21T11:00:00.000Z');
      expect((await book.practiseRequests()).map((r) => r.id), [q2.id, q1.id]);
      expect((await book.drillEvidence([q2.id]))[q2.id]!.asked, isTrue);

      // Reporting progress to Udyoga leaves the request row alone.
      final before = (await requests())!.progress;
      await book.reportToUdyoga(now: '2026-11-21T12:00:00Z');
      expect((await requests())!.progress, before);
    });

    test('the requests fixture shared with Udyoga is current', () async {
      await importPlan();
      await db
          .into(db.learnCards)
          .insert(
            LearnCardsCompanion.insert(
              id: 'card1',
              front: 'Tell your story: Clinic diary clash',
              back: 'Action: I rang each patient on the list.',
              due: today,
              created: today,
              ref: const Value('udyoga.story.fixture-story'),
            ),
          );
      final q1 = await drill('q1'), q2 = await drill('q2');
      await book.linkStory((await book.storyBank()).single, drills: [q2.id], today: today);
      await book.askUdyogaToPractise(q1, now: '2026-11-21T09:00:00.000Z');
      await book.askUdyogaToPractise(q2, now: '2026-11-21T10:00:00.000Z');
      // Drill row ids are random: the fixture names them, and Udyoga's
      // results fixture (udyoga-practise-results.json) answers to those names.
      final text = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode((await requests())!.progress))
          .replaceAll(q1.id, 'vidya-drill-q1')
          .replaceAll(q2.id, 'vidya-drill-q2');
      final fixture = File('test/fixtures/vidya-practise-requests.json');
      if (!fixture.existsSync() || Platform.environment['UPDATE_FIXTURES'] == '1') {
        await fixture.writeAsString('$text\n');
      }
      expect(await fixture.readAsString(), '$text\n');
    });

    test('Udyoga\'s results fixture reads back as the score on its drill', () async {
      await importPlan();
      final q2 = await drill('q2');
      // Written by Udyoga's tests (test/fixtures/udyoga-practise-results.json
      // there), for the drill named vidya-drill-q2 in the requests fixture.
      final plan = File('test/fixtures/udyoga-practise-results.json').readAsStringSync();
      await db
          .into(db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(
              id: practiseResultsId,
              source: 'udyoga',
              plan: plan.replaceAll('vidya-drill-q2', q2.id),
              updated: '2026-11-21T12:00:00Z',
            ),
          );
      expect(await book.offeredPlans(), isEmpty);
      final scores = parsePractiseResults(plan);
      expect(scores.keys, contains('vidya-drill-q2'));
      final e = (await book.drillEvidence([q2.id]))[q2.id]!;
      expect(e.udyoga, isNotNull);
      expect(e.udyoga!.day, '2026-11-21');
      expect(e.udyoga!.max, greaterThan(0));
      expect(e.latest, e.udyoga!.outOf8);
    });

    test('a linked Udyoga story goes as its id only', () async {
      await importPlan();
      await db
          .into(db.learnCards)
          .insert(
            LearnCardsCompanion.insert(
              id: 'card1',
              front: 'Tell your story: Calm',
              back: 'Action: I stayed calm.',
              due: today,
              created: today,
              ref: const Value('udyoga.story.s9'),
            ),
          );
      final q2 = await drill('q2');
      await book.linkStory((await book.storyBank()).single, drills: [q2.id], today: today);
      final r = await book.askUdyogaToPractise(q2, now: 'T');
      expect(r.story, 's9');
      expect(r.toJson().containsKey('story'), isTrue);
      expect(jsonEncode(r.toJson()), isNot(contains('stayed calm')));
    });

    test('Udyoga\'s score comes back on the drill; the results row is never offered as a plan', () async {
      await importPlan();
      final q2 = await drill('q2');
      await db
          .into(db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(
              id: practiseResultsId,
              source: 'udyoga',
              plan: jsonEncode({
                'format': 'udyoga-practise-results',
                'version': 1,
                'results': [
                  {'id': q2.id, 'day': '2026-11-20', 'score': 3, 'max': 10, 'summary': 'No result given'},
                  {'id': q2.id, 'day': '2026-11-21', 'score': 7, 'max': 10},
                  {'id': '', 'day': '2026-11-21', 'score': 1, 'max': 2},
                  'junk',
                ],
              }),
              updated: '2026-11-21T08:00:00Z',
            ),
          );
      expect(await book.offeredPlans(), isEmpty);
      final e = (await book.drillEvidence([q2.id]))[q2.id]!;
      expect((e.udyoga!.text, e.udyoga!.day, e.latest), ('7/10', '2026-11-21', 5.6));
      expect(e.weak, isFalse);
      // A newer attempt here wins over an older Udyoga score.
      await book.recordDrill(q2, const DrillAttempt(checks: [1, 1, 1, 0]), today: '2026-11-22');
      expect((await book.drillEvidence([q2.id]))[q2.id]!.weak, isTrue);
      expect(parsePractiseResults('{"format":"other","results":[]}'), isEmpty);
      expect(parsePractiseResults('not json'), isEmpty);
    });
  });

  test('a version 8 database gains the story bank and drill links, and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v8.db');
    var db8 = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db8));
    await b.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
    final cid = (await db8.select(db8.learnCourses).get()).single.id;
    await b.addAssessment('Mock', 8, 10, today: today, courseId: cid);
    final quiz = (await (db8.select(db8.learnItems)..where((i) => i.type.equals('quiz'))).get()).single;
    await b.recordQuiz(quiz, [true], today: today);
    final before = (await db8.select(db8.learnAssessments).get())
        .map((a) => (a.id, a.title, a.score, a.topicId))
        .toList();
    final items = (await db8.select(db8.learnItems).get()).map((i) => (i.id, i.content)).toList();
    // Turn it back into version 8: none of the new columns, no story table.
    await db8.customStatement('DROP INDEX IF EXISTS learn_assessments_item');
    await db8.customStatement('ALTER TABLE learn_assessments DROP COLUMN item_id');
    await db8.customStatement('ALTER TABLE learn_assessments DROP COLUMN detail');
    await db8.customStatement('DROP TABLE learn_stories');
    await db8.customStatement('PRAGMA user_version = 8');
    await db8.close();

    db8 = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db8));
    final tests = await db8.select(db8.learnAssessments).get();
    expect(tests.map((a) => (a.id, a.title, a.score, a.topicId)).toList(), before);
    expect(tests.every((a) => a.itemId == null && a.detail == ''), isTrue);
    expect((await db8.select(db8.learnItems).get()).map((i) => (i.id, i.content)).toList(), items);
    expect(lastQuizPercents(tests).values.single, 100);
    // The new parts work.
    final d = (await (db8.select(db8.learnItems)..where((i) => i.ref.equals('q1'))).get()).single;
    await b.recordDrill(d, const DrillAttempt(checks: [2, 2, 2, 2]), today: today);
    await b.saveStory(title: 'Story', action: 'Did it.', today: today);
    expect((await b.storyBank()).single.title, 'Story');
    expect((await b.drillEvidence([d.id]))[d.id]!.own, 8);
    await db8.close();
    await dir.delete(recursive: true);
  });
}
