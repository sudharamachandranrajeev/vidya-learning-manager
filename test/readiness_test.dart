import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show Value, BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/udyoga_link.dart';

import 'support.dart';

const today = '2026-11-21';

/// A made-up trainer role plan: four essential and two desirable criteria.
/// e4 comes from an AI, is flagged as shown on the CV and even carries
/// `covered`/`status` fields, none of which may cover it.
Map<String, Object?> plan() => {
  'format': 'vidya-curriculum',
  'version': 2,
  'program': {'title': 'Approach: Example Trainer'},
  'role': 'Example Trainer',
  'criteria': [
    {'id': 'e1', 'text': 'Explain a system to beginners', 'essential': true},
    {'id': 'e2', 'text': 'Handle a difficult learner calmly', 'essential': true},
    {'id': 'e3', 'text': 'Keep training records', 'essential': true},
    {
      'id': 'e4',
      'text': 'Teaching qualification',
      'essential': true,
      'source': 'AI',
      'shown': true,
      'covered': true,
      'status': 'covered',
    },
    {'id': 'd1', 'text': 'Write short guides', 'essential': false},
    {'id': 'd2', 'text': 'Spreadsheets', 'essential': false},
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
            {'question': 'Show or tell first?', 'answer': 'Show'},
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
          ],
        },
        {
          'title': 'Records',
          'criteria': ['e3'],
          'items': [
            {'type': 'practice task', 'title': 'Set up a training log', 'doneWhen': 'Ten sessions logged'},
          ],
        },
        {
          'title': 'Qualification',
          'criteria': ['e4'],
          'quiz': [
            {'question': 'What level is the award?', 'answer': '3', 'ai': true},
          ],
        },
        {
          'title': 'Guides',
          'criteria': ['d1'],
        },
      ],
    },
  ],
};

Evidence ev(EvidenceKind kind, EvidenceWeight weight, {String day = today, bool ai = false}) =>
    Evidence(kind: kind, title: 'x', detail: 'x', weight: weight, day: day, ai: ai);

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  Future<String> importPlan() async =>
      (await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: '2026-11-01')).programId;

  Future<StudyItem> item(String title) async =>
      (await (db.select(db.learnItems)..where((i) => i.title.equals(title))).get()).single;
  Future<StudyItem> drill(String ref) async =>
      (await (db.select(db.learnItems)..where((i) => i.ref.equals(ref))).get()).single;
  Future<StudyItem> quizOf(String topicTitle) async {
    final t = await (db.select(db.learnTopics)..where((t) => t.title.equals(topicTitle))).getSingle();
    return (await (db.select(
      db.learnItems,
    )..where((i) => i.topicId.equals(t.id) & i.type.equals('quiz'))).get()).single;
  }

  Future<Topic> topic(String title) =>
      (db.select(db.learnTopics)..where((t) => t.title.equals(title))).getSingle();
  Future<void> tick(String title, String day) async {
    final t = await topic(title);
    await book.save(db.learnTopics, t.copyWith(done: Value(day)), t.id);
  }

  ReadinessRow row(Readiness r, String ref) => r.rows.firstWhere((x) => x.criterion.ref == ref);

  group('status rules', () {
    test('no evidence is missing; only planned items are weak', () {
      expect(judgeEvidence(const [], today).status, ReadinessStatus.missing);
      final planned = judgeEvidence([ev(EvidenceKind.topic, EvidenceWeight.planned, day: '')], today);
      expect(planned.status, ReadinessStatus.weak);
      expect(planned.reasons, [WeakReason.planned]);
      // The CV flag alone is information, not evidence.
      expect(
        judgeEvidence([ev(EvidenceKind.cv, EvidenceWeight.info)], today).status,
        ReadinessStatus.missing,
      );
    });

    test('old strong evidence, a low quiz and a low drill are weak', () {
      final old = judgeEvidence([ev(EvidenceKind.drill, EvidenceWeight.strong, day: '2026-09-01')], today);
      expect(old.status, ReadinessStatus.weak);
      expect(old.reasons, [WeakReason.old]);
      // Exactly 60 days is still fresh; 61 is old.
      expect(
        judgeEvidence([ev(EvidenceKind.task, EvidenceWeight.strong, day: '2026-09-22')], today).status,
        ReadinessStatus.covered,
      );
      expect(
        judgeEvidence([ev(EvidenceKind.task, EvidenceWeight.strong, day: '2026-09-21')], today).status,
        ReadinessStatus.weak,
      );
      final quiz = judgeEvidence([ev(EvidenceKind.quiz, EvidenceWeight.low)], today);
      expect(quiz.status, ReadinessStatus.weak);
      expect(quiz.reasons, [WeakReason.lowQuiz]);
      final drill = judgeEvidence([ev(EvidenceKind.drill, EvidenceWeight.low)], today);
      expect(drill.status, ReadinessStatus.weak);
      expect(drill.reasons, [WeakReason.lowDrill]);
      final unchecked = judgeEvidence([ev(EvidenceKind.topic, EvidenceWeight.unchecked)], today);
      expect(unchecked.reasons, [WeakReason.unchecked]);
    });

    test('a story with a done topic is strong, dated by the newer of the two', () {
      expect(
        judgeEvidence([
          ev(EvidenceKind.story, EvidenceWeight.unchecked),
          ev(EvidenceKind.topic, EvidenceWeight.unchecked, day: '2026-08-01'),
        ], today).status,
        ReadinessStatus.covered,
      );
      expect(
        judgeEvidence([
          ev(EvidenceKind.story, EvidenceWeight.unchecked, day: '2026-08-01'),
          ev(EvidenceKind.topic, EvidenceWeight.unchecked, day: '2026-08-02'),
        ], today).reasons,
        [WeakReason.old],
      );
      // A story with only an open topic is not enough.
      expect(
        judgeEvidence([
          ev(EvidenceKind.story, EvidenceWeight.unchecked),
          ev(EvidenceKind.topic, EvidenceWeight.planned, day: ''),
        ], today).status,
        ReadinessStatus.weak,
      );
    });

    test('evidence marked as made by an AI never covers a row', () {
      final r = judgeEvidence([
        ev(EvidenceKind.task, EvidenceWeight.strong, ai: true),
        ev(EvidenceKind.drill, EvidenceWeight.strong, ai: true),
        ev(EvidenceKind.story, EvidenceWeight.unchecked, ai: true),
        ev(EvidenceKind.topic, EvidenceWeight.unchecked, ai: true),
      ], today);
      expect(r.status, ReadinessStatus.weak);
    });
  });

  group('rows from real study', () {
    test('a fresh plan: rows in plan order, planned topics weak, nothing linked missing', () async {
      final pid = await importPlan();
      final r = await book.readiness(pid, today: today);
      expect(r.rows.map((x) => x.criterion.ref), ['e1', 'e2', 'e3', 'e4', 'd1', 'd2']);
      expect(row(r, 'e1').status, ReadinessStatus.weak);
      expect(row(r, 'e1').reasons, [WeakReason.planned]);
      expect(row(r, 'd2').status, ReadinessStatus.missing);
      expect(r.summary.text(today), '0 of 4 essential covered, 4 weak · desirable 0 of 2');
    });

    test(
      'each strong path covers its row: quiz on a done topic, task with evidence, drill 5/8, story',
      () async {
        final pid = await importPlan();
        // e1: quiz 2/2 (100%) on a ticked topic.
        await book.recordQuiz(await quizOf('Explaining clearly'), [true, true], today: today);
        await tick('Explaining clearly', today);
        // e2: a drill at 6/8.
        await book.recordDrill(await drill('q2'), const DrillAttempt(checks: [2, 2, 1, 1]), today: today);
        // e3: the practice task done with an evidence link.
        expect(
          await book.completeTask(
            await item('Set up a training log'),
            evidence: 'https://example.org/log',
            today: today,
          ),
          isNull,
        );
        // d1: a story linked to it and its topic done.
        final crit = await book.programCriteria(pid);
        final d1 = crit.firstWhere((c) => c.ref == 'd1');
        await book.saveStory(
          title: 'Quick-start guide',
          action: 'I wrote one page.',
          criteria: [d1.id],
          today: today,
        );
        await tick('Guides', today);

        final r = await book.readiness(pid, today: today);
        for (final ref in ['e1', 'e2', 'e3', 'd1']) {
          expect(row(r, ref).status, ReadinessStatus.covered, reason: ref);
        }
        expect(row(r, 'e1').evidence.map((e) => e.detail), contains(startsWith('Quiz 100% on')));
        expect(row(r, 'e3').evidence.map((e) => e.detail), contains(contains('with evidence')));
        expect(r.summary.text(today), '3 of 4 essential covered, 1 weak · desirable 1 of 2');
      },
    );

    test('a low quiz, a low drill, a task without evidence and old work stay weak', () async {
      final pid = await importPlan();
      await book.recordQuiz(await quizOf('Explaining clearly'), [true, false], today: today); // 50%
      await tick('Explaining clearly', today);
      await book.recordDrill(
        await drill('q2'),
        const DrillAttempt(checks: [2, 1, 1, 0]),
        today: today,
      ); // 4/8
      await book.completeTask(
        await item('Set up a training log'),
        note: '',
        evidence: 'https://example.org/old',
        today: '2026-08-01',
      );
      final r = await book.readiness(pid, today: today);
      expect(row(r, 'e1').status, ReadinessStatus.weak);
      expect(row(r, 'e1').reasons, [WeakReason.lowQuiz]);
      expect(row(r, 'e2').reasons, contains(WeakReason.lowDrill));
      expect(row(r, 'e3').reasons, [WeakReason.old]);

      // Udyoga's newer score lifts the drill.
      final q2 = await drill('q2');
      await db
          .into(db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(
              id: practiseResultsId,
              source: 'udyoga',
              plan: jsonEncode({
                'format': practiseResultsFormat,
                'version': 1,
                'results': [
                  {'id': q2.id, 'day': today, 'score': 0, 'max': 10},
                  {'id': q2.id, 'day': '2026-11-22', 'score': 8, 'max': 10},
                ],
              }),
              updated: 'T1',
            ),
          );
      final r2 = await book.readiness(pid, today: '2026-11-22');
      expect(row(r2, 'e2').status, ReadinessStatus.covered);
      expect(row(r2, 'e2').evidence.map((e) => e.detail), contains(contains('scored in Udyoga')));
    });

    test('AI cannot mark a criterion covered: source, CV flag and plan fields are ignored', () async {
      final pid = await importPlan();
      // Its only quiz question was written by an AI, and never taken.
      final r = await book.readiness(pid, today: today);
      final e4 = row(r, 'e4');
      expect(e4.criterion.source, 'AI');
      expect(e4.criterion.shown, isTrue);
      expect(e4.status, isNot(ReadinessStatus.covered));
      expect(e4.evidence.map((e) => e.kind), contains(EvidenceKind.cv));
      // A skill rated at target and a portfolio item with the same words
      // are claims, not checks: weak, not covered.
      await book.addSkill('Teaching qualification', today: today, level: 5);
      await book.addPortfolio('Award certificate', today: today, skills: 'Teaching qualification');
      final r2 = await book.readiness(pid, today: today);
      expect(row(r2, 'e4').status, ReadinessStatus.weak);
      expect(
        row(r2, 'e4').evidence.map((e) => e.kind),
        containsAll([EvidenceKind.skill, EvidenceKind.portfolio]),
      );
    });

    test('summary counts with the interview day', () async {
      final pid = await importPlan();
      await book.setInterviewDate(pid, '2026-11-27');
      final r = await book.readiness(pid, today: today);
      expect(
        r.summary.text(today),
        '0 of 4 essential covered, 4 weak · desirable 0 of 2 · interview in 6 days',
      );
      const s = ReadinessSummary(
        essential: 12,
        essentialCovered: 9,
        essentialWeak: 2,
        essentialMissing: 1,
        desirable: 5,
        desirableCovered: 3,
        interviewDate: '2026-11-27',
      );
      expect(
        s.text(today),
        '9 of 12 essential covered, 2 weak, 1 missing · desirable 3 of 5 · interview in 6 days',
      );
      expect(const ReadinessSummary().text(today), 'No criteria yet');
    });
  });

  group('next action', () {
    test('picks the weakest essential row, and the right step for it', () async {
      final pid = await importPlan();
      // Everything planned: e1 comes first (plan order); its topic has an
      // untaken quiz.
      var r = await book.readiness(pid, today: today);
      expect(r.next!.criterion.ref, 'e1');
      expect((r.next!.kind, r.next!.label), (ActionKind.quiz, 'Take the quiz on Explaining clearly'));

      // e1 covered; e2 has a drill never practised.
      await book.recordQuiz(await quizOf('Explaining clearly'), [true, true], today: today);
      await tick('Explaining clearly', today);
      r = await book.readiness(pid, today: today);
      expect(r.next!.criterion.ref, 'e2');
      expect(r.next!.label, 'Practise drill: Tell me about a time a learner got angry.');

      // A low drill on e2 is less weak than e3's planned-only task: e3 next.
      await book.recordDrill(await drill('q2'), const DrillAttempt(checks: [1, 1, 1, 0]), today: today);
      r = await book.readiness(pid, today: today);
      expect(r.next!.criterion.ref, 'e3');
      expect((r.next!.kind, r.next!.label), (ActionKind.topic, 'Finish the task: Set up a training log'));

      // A missing essential row beats any weak one, and asks for a story.
      final own = await book.saveOwnCriterion(pid, body: 'Full UK driving licence', essential: true);
      r = await book.readiness(pid, today: today);
      expect(r.next!.criterion.id, own);
      expect((r.next!.kind, r.next!.label), (ActionKind.story, 'Write a story for Full UK driving licence'));
    });

    test('a low drill asks to practise it again; a low quiz to retake it', () {
      Criterion c(String ref) => Criterion(
        id: ref,
        hlc: '',
        deleted: false,
        programId: 'p',
        ref: ref,
        body: ref,
        essential: true,
        kind: '',
        source: '',
        ord: 0,
      );
      final low = ReadinessRow(
        criterion: c('a'),
        status: ReadinessStatus.weak,
        reasons: const [WeakReason.lowDrill],
        evidence: const [
          Evidence(
            kind: EvidenceKind.drill,
            title: 'Q',
            detail: '',
            weight: EvidenceWeight.low,
            day: today,
            id: 'd',
          ),
        ],
      );
      expect(nextActionFor(low, quizzes: const {}, today: today).label, 'Practise drill again: Q');
      expect(weakestRow([low]), low);
      expect(weakestRow(const []), isNull);
    });
  });

  group('criteria typed in by hand', () {
    test('added, linked to topics, edited and deleted; a re-sent plan keeps the links', () async {
      final pid = await importPlan();
      final guides = await topic('Guides');
      final id = await book.saveOwnCriterion(
        pid,
        body: 'Experience of delivering training to adults',
        essential: true,
        topicIds: [guides.id],
      );
      var c = (await book.programCriteria(pid)).firstWhere((x) => x.id == id);
      expect(isOwnCriterion(c), isTrue);
      expect((c.source, c.essential, c.ord), (ownCriterionSource, true, 6));
      expect((await topic('Guides')).criteria, 'd1,${c.ref}');

      // The plan comes again: its own links are updated, the learner's kept.
      await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      expect((await topic('Guides')).criteria, 'd1,${c.ref}');
      expect((await book.programCriteria(pid)).where((x) => x.id == id), hasLength(1));

      await tick('Guides', today);
      await book.saveStory(title: 'Adult class', action: 'I ran it.', criteria: [id], today: today);
      expect(row(await book.readiness(pid, today: today), c.ref).status, ReadinessStatus.covered);

      await book.saveOwnCriterion(pid, id: id, body: 'Training adults', essential: false, topicIds: const []);
      c = (await book.programCriteria(pid)).firstWhere((x) => x.id == id);
      expect((c.body, c.essential), ('Training adults', false));
      expect((await topic('Guides')).criteria, 'd1');

      await book.deleteOwnCriterion(c);
      expect((await book.programCriteria(pid)).where((x) => x.id == id), isEmpty);
    });

    test('a program without plan criteria gets readiness from typed-in rows', () async {
      final pid = await book.addProgram('Data analyst', '', today: today);
      expect((await book.readiness(pid, today: today)).rows, isEmpty);
      await book.saveOwnCriterion(pid, body: 'SQL', essential: true);
      await book.saveOwnCriterion(pid, body: 'Dashboards', essential: false);
      final r = await book.readiness(pid, today: today);
      expect(r.summary.text(today), '0 of 1 essential covered, 1 missing · desirable 0 of 1');
    });
  });

  test('Home picks the nearest interview, else the latest role plan', () {
    Program p(String id, String started, {String role = '', String status = 'active'}) => Program(
      id: id,
      hlc: '',
      deleted: false,
      title: id,
      goal: '',
      status: status,
      started: started,
      role: role,
    );
    final ps = [
      p('a', '2026-10-01', role: 'Trainer'),
      p('b', '2026-11-01', role: 'Analyst'),
      p('c', '2026-11-10'),
      p('d', '2026-11-15', role: 'Done role', status: 'done'),
    ];
    final all = {'a', 'b', 'c', 'd'};
    expect(pickReadinessProgram(ps, withCriteria: all, interviewDates: const {}, today: today)!.id, 'b');
    expect(
      pickReadinessProgram(
        ps,
        withCriteria: all,
        interviewDates: const {'a': '2026-12-01', 'c': '2026-11-01'},
        today: today,
      )!.id,
      'a',
      reason: 'c\'s interview is past',
    );
    expect(pickReadinessProgram(ps, withCriteria: {'c'}, interviewDates: const {}, today: today)!.id, 'c');
    expect(pickReadinessProgram(ps, withCriteria: const {}, interviewDates: const {}, today: today), isNull);
  });

  test('weak and missing rows go back to Udyoga on the plan\'s progress row, the rest unchanged', () async {
    const planId = 'udyoga.study-plan.trainer';
    await db
        .into(db.bridgeStudyPlans)
        .insert(
          BridgeStudyPlansCompanion.insert(
            id: planId,
            source: 'udyoga',
            plan: jsonEncode(plan()),
            updated: 'P1',
          ),
        );
    final offer = (await book.offeredPlans()).single;
    await book.addOfferedPlan(offer, today: today, now: '2026-11-21T09:00:00Z');
    final pid = (await book.planProgram(offer.plan))!.id;

    await book.recordQuiz(await quizOf('Explaining clearly'), [true, true], today: today);
    await tick('Explaining clearly', today);
    await book.saveOwnCriterion(pid, body: 'Full UK driving licence', essential: false);
    await book.addSkill('SystmOne', today: today, category: 'Digital', level: 3);
    await book.reportToUdyoga(now: '2026-11-21T10:00:00Z');

    final row = await (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals(planId))).getSingle();
    final j = jsonDecode(row.progress) as Map<String, Object?>;
    expect(j['readiness'], [
      {'criterionId': 'e2', 'text': 'Handle a difficult learner calmly', 'status': 'weak', 'essential': true},
      {'criterionId': 'e3', 'text': 'Keep training records', 'status': 'weak', 'essential': true},
      {'criterionId': 'e4', 'text': 'Teaching qualification', 'status': 'weak', 'essential': true},
      {'criterionId': 'd1', 'text': 'Write short guides', 'status': 'weak', 'essential': false},
      {'criterionId': 'd2', 'text': 'Spreadsheets', 'status': 'missing', 'essential': false},
      {'criterionId': '', 'text': 'Full UK driving licence', 'status': 'missing', 'essential': false},
    ]);
    // The existing fields read as before.
    final p = StudyProgress.parse(row.progress);
    expect(p.skills.map((k) => (k.name, k.level)), [('SystmOne', 3)]);
    expect(j['drills'], [
      {'course': 'Teaching basics', 'title': 'Explaining clearly', 'done': today},
    ]);
    expect(row.planUpdated, 'P1');

    // Nothing changed: no new write.
    await book.reportToUdyoga(now: '2026-11-21T10:05:00Z');
    final again = await (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals(planId))).getSingle();
    expect(again.hlc, row.hlc);
  });
}
