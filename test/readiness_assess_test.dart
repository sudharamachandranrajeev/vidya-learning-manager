// Assessment polish B3: exams, stress tests and capstones in Job readiness.
// A made-up community-garden coordinator plan; fictional rows only.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/capstone.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/exam.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/scenario.dart';

import 'support.dart';

const day = '2026-11-21';

Map<String, Object?> _scenario(String id, String criterion) => {
  'type': 'scenario',
  'id': id,
  'title': 'Triage $id',
  'columns': ['Request', 'Detail'],
  'rows': [
    {
      'cells': ['R1', 'Broken water tap by the beds'],
      'risk': 'high',
      'expect': 'escalate',
    },
    {
      'cells': ['R2', 'More seed trays'],
      'expect': 'act',
    },
  ],
  'criteria': [criterion],
};

Map<String, Object?> _plan() => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Garden coordinator'},
  'role': 'Garden coordinator',
  'criteria': [
    {'id': 'c1', 'text': 'Run safety checks', 'essential': true},
    {'id': 'c2', 'text': 'Prioritise volunteer requests', 'essential': true},
    {'id': 'c3', 'text': 'Lead a team briefing', 'essential': true},
    {'id': 'c4', 'text': 'Handle complaints', 'essential': false},
  ],
  'courses': [
    {
      'title': 'Coordinating',
      'topics': [
        {
          'title': 'Safety exam',
          'criteria': ['c1'],
          'quiz': [
            {'question': 'Gloves for compost?', 'answer': 'Yes'},
            {'question': 'Tools away at dusk?', 'answer': 'Yes'},
          ],
          'exam': {'minutes': 5, 'passPercent': 50},
        },
        {
          'title': 'Requests',
          'items': [_scenario('st1', 'c2')],
        },
        {
          'title': 'Briefings',
          'drills': [
            {'id': 'b1', 'question': 'Brief the Saturday team on the new rota.', 'criterion': 'c3'},
            {'id': 'b2', 'question': 'Tell me about a briefing that went wrong.', 'criterion': 'c3'},
          ],
          'capstone': {
            'drills': ['b1', 'b2'],
          },
        },
        {
          'title': 'Complaints',
          'items': [_scenario('st2', 'c4')],
        },
      ],
    },
  ],
};

void main() {
  late LearningBook book;
  late AppDatabase db;
  late String programId;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
    programId = (await book.importCurriculum(
      parseCurriculum(jsonEncode(_plan())),
      today: '2026-11-01',
    )).programId;
  });
  tearDown(() => db.close());

  Future<StudyItem> byRef(String ref) async =>
      (await (db.select(db.learnItems)..where((i) => i.ref.equals(ref))).get()).single;
  Future<StudyItem> ofType(String type) async =>
      (await (db.select(db.learnItems)..where((i) => i.type.equals(type))).get()).single;
  ReadinessRow row(Readiness r, String ref) => r.rows.firstWhere((x) => x.criterion.ref == ref);
  Evidence piece(ReadinessRow r, EvidenceKind k) => r.evidence.firstWhere((e) => e.kind == k);

  Future<void> sitExam(int right) async {
    final quiz = await ofType('quiz');
    final shown = quizQuestions(quiz);
    final marks = [for (var k = 0; k < shown.length; k++) k < right];
    await book.recordExam(
      quiz,
      shown,
      marks,
      ExamResult(
        right: right,
        total: shown.length,
        attempted: shown.length,
        seconds: 120,
        limitSeconds: 300,
        passPercent: 50,
      ),
      today: day,
    );
  }

  Future<void> tryScenario(String ref, List<String> picks) async {
    final item = await byRef(ref);
    await book.recordScenario(
      item,
      ScenarioAttempt(
        scenario: scenarioOf(item)!,
        picks: picks,
        reasons: const ['', ''],
        checks: const [2, 2, 2, 2],
      ),
      today: day,
    );
  }

  test('untried stress tests and capstones are listed as planned', () async {
    final r = await book.readiness(programId, today: day);
    final c2 = row(r, 'c2');
    expect(piece(c2, EvidenceKind.scenario).detail, 'Stress test not tried yet');
    expect(piece(c2, EvidenceKind.scenario).weight, EvidenceWeight.planned);
    expect(c2.status, ReadinessStatus.weak);
    expect(c2.reasons, [WeakReason.planned]);
    final c3 = row(r, 'c3');
    expect(piece(c3, EvidenceKind.capstone).detail, 'Capstone not sat yet');
    expect(row(r, 'c1').evidence.where((e) => e.kind == EvidenceKind.scenario), isEmpty);
  });

  test('an exam result shows as an exam with its own pass mark and date', () async {
    await sitExam(1); // 50%: passes this exam's 50% mark, under a quiz's 70%
    var c1 = row(await book.readiness(programId, today: day), 'c1');
    final e = piece(c1, EvidenceKind.exam);
    expect(e.detail, startsWith('Exam 50% (passed) on ${niceDate(day)}'));
    expect(e.day, day);
    expect(e.weight, isNot(EvidenceWeight.low));
    expect(c1.evidence.where((x) => x.kind == EvidenceKind.quiz), isEmpty);

    await sitExam(0);
    c1 = row(await book.readiness(programId, today: day), 'c1');
    expect(piece(c1, EvidenceKind.exam).detail, startsWith('Exam 0% (not passed)'));
    expect(piece(c1, EvidenceKind.exam).weight, EvidenceWeight.low);
    expect(c1.reasons, contains(WeakReason.lowQuiz));
  });

  test('a passed stress test is medium evidence: weak, never covered on its own', () async {
    await tryScenario('st1', ['escalate', 'act']);
    final c2 = row(await book.readiness(programId, today: day), 'c2');
    final e = piece(c2, EvidenceKind.scenario);
    expect(e.weight, EvidenceWeight.medium);
    expect(e.detail, 'Stress test passed on ${niceDate(day)} · rating 5/5');
    expect(e.day, day);
    expect(c2.status, ReadinessStatus.weak);
    expect(c2.reasons, [WeakReason.selfRated]);
  });

  test('a high-risk row left untouched makes the stress test low', () async {
    await tryScenario('st2', ['', 'act']);
    final c4 = row(await book.readiness(programId, today: day), 'c4');
    final e = piece(c4, EvidenceKind.scenario);
    expect(e.weight, EvidenceWeight.low);
    expect(e.detail, contains('1 high-risk row untouched'));
    expect(c4.reasons, [WeakReason.lowTest]);
    expect(row(await book.readiness(programId, today: day), 'c2').reasons, [WeakReason.planned]);
  });

  test('a capstone sitting shows on the rows its drills test, with its date', () async {
    final cap = await ofType(capstoneType);
    final rules = capstoneRules(cap)!;
    final b1 = await byRef('b1'), b2 = await byRef('b2');
    await book.recordCapstone(
      cap,
      CapstoneSitting(
        drills: [
          CapstoneDrill(id: b1.id, title: 'b1', outOf8: 8),
          CapstoneDrill(id: b2.id, title: 'b2', outOf8: 6),
        ],
        rules: rules,
      ),
      today: day,
    );
    var c3 = row(await book.readiness(programId, today: day), 'c3');
    var e = piece(c3, EvidenceKind.capstone);
    expect(e.weight, EvidenceWeight.medium);
    expect(e.detail, 'Capstone passed on ${niceDate(day)} · average 4.5/5, lowest 4/5');
    expect(e.day, day);
    expect(c3.status, ReadinessStatus.weak, reason: 'self-rated; the drills count on their own');

    await book.recordCapstone(
      cap,
      CapstoneSitting(
        drills: [
          CapstoneDrill(id: b1.id, title: 'b1', outOf8: 2),
          CapstoneDrill(id: b2.id, title: 'b2'),
        ],
        rules: rules,
      ),
      today: '2026-11-22',
    );
    c3 = row(await book.readiness(programId, today: '2026-11-22'), 'c3');
    e = piece(c3, EvidenceKind.capstone);
    expect(e.weight, EvidenceWeight.low);
    expect(e.detail, startsWith('Capstone not passed on ${niceDate('2026-11-22')}'));
    expect(c3.reasons, contains(WeakReason.lowTest));
  });

  test('drill scores read out of 5 with the out-of-8 detail kept', () async {
    final b1 = await byRef('b1');
    await book.recordDrill(b1, const DrillAttempt(checks: [2, 2, 1, 1]), today: day);
    final r = await book.readiness(programId, today: day);
    final drill = row(r, 'c3').evidence.firstWhere((e) => e.kind == EvidenceKind.drill && e.id == b1.id);
    expect(drill.detail, startsWith('Drill 4/5 (6/8) on'));
    expect(WeakReason.lowDrill.label, 'Latest drill under 4/5');
    final before = planBeforeInterview(
      criteria: [for (final x in r.rows) x.criterion],
      topics: const [],
      drills: [b1],
      evidence: await book.drillEvidence([b1.id]),
      quizPercents: const {},
      stories: const [],
      readiness: r.rows,
    );
    final c3 = [...before.weak, ...before.covered].firstWhere((c) => c.criterion.ref == 'c3');
    expect(c3.evidence.single, startsWith('Drill 4/5 (6/8):'));
  });
}
