// Framework self-assessment (assess plan A6): the plan's `framework` block
// and its limits, dated ratings with a trend, gaps, evidence from Udyoga's
// tagged story cards, and readiness that a self-rating never covers.
// Made-up plan: a community clinic's team lead, no real people.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show Store;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/framework.dart';
import 'package:vidya/domain/readiness.dart';

import 'support.dart';

const today = '2026-11-27';

Map<String, Object?> standard(String id, {Object? criteria, Object? topics, Object? descriptors}) => {
  'id': id,
  'area': 'self',
  'title': 'Standard $id',
  'descriptors': descriptors ?? {'1': 'At stage one for $id', '2': 'At stage two for $id'},
  'criteria': ?criteria,
  'topics': ?topics,
};

Map<String, Object?> lmf({Object? standards, Object? stages, Object? status, Object? target = '1'}) => {
  'id': 'nhs-lmf',
  'name': 'Leadership framework (made-up wording)',
  'status': ?status,
  'stages':
      stages ??
      [
        {'id': '1', 'name': 'New and first-line'},
        {'id': '2', 'name': 'Middle'},
      ],
  'targetStage': target,
  'areas': [
    {'id': 'self', 'title': 'Self effectiveness'},
  ],
  'standards':
      standards ??
      [
        standard('self_safety', criteria: ['c1'], topics: ['Safe rotas']),
        standard('self_communicating', criteria: ['c2']),
        standard('care_collaboration'),
      ],
};

Map<String, Object?> plan({Object? framework, bool onCourse = false}) => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Clinic team lead'},
  'criteria': [
    {'id': 'c1', 'text': 'Keeps the rota safe', 'essential': true},
    {'id': 'c2', 'text': 'Listens to the team', 'essential': true},
  ],
  if (!onCourse) 'framework': framework ?? lmf(),
  'courses': [
    {
      'title': 'Leading a small team',
      if (onCourse) 'framework': framework ?? lmf(),
      'topics': [
        {
          'title': 'Safe rotas',
          'minutes': 30,
          'criteria': ['c1'],
        },
      ],
    },
  ],
};

/// Udyoga's plan with one tagged story card (as its A4 bridge sends it).
String udyogaPlan({String framework = 'nhs_lmf', String item = 'self_communicating', String title = ''}) =>
    jsonEncode({
      'format': 'vidya-curriculum',
      'version': 1,
      'program': {'title': 'Interview ready'},
      'cards': [
        {
          'id': 'udyoga.story.s1',
          'deck': 'Interview stories',
          'front': 'Tell your story: Rota swap at the made-up clinic (Teamwork)',
          'back': 'Action: Talked it through with each nurse.',
          'tags': [
            {'framework': framework, 'item': item, 'title': title},
          ],
          'happened': '2026-03-01',
        },
        {'id': 'udyoga.story.s2', 'front': 'Tell your story: Untagged', 'back': 'Action: x'},
      ],
    });

Assessment row(String id, String day, FrameworkRating r, {String hlc = ''}) => Assessment(
  id: id,
  hlc: hlc.isEmpty ? '$day-$id' : hlc,
  deleted: false,
  title: r.standard,
  day: day,
  score: r.rating.toDouble(),
  max: 4,
  detail: r.encode(),
);

FrameworkRating rating(String standard, int r, {String stage = '1', String fw = 'nhs_lmf'}) =>
    FrameworkRating(framework: fw, standard: standard, stage: stage, rating: r);

void main() {
  group('the plan block', () {
    test('reads stages, areas, standards and descriptors; draft unless final', () {
      final p = parseCurriculum(jsonEncode(plan()));
      final f = p.framework!;
      expect(f.id, 'nhs-lmf');
      expect(f.isDraft, isTrue);
      expect(f.stages.map((s) => s.name), ['New and first-line', 'Middle']);
      expect(f.targetStage, '1');
      expect(f.areaTitle('self'), 'Self effectiveness');
      expect(f.standards.map((s) => s.id), ['self_safety', 'self_communicating', 'care_collaboration']);
      expect(f.standards.first.descriptors['2'], 'At stage two for self_safety');
      expect(f.standards.first.criteria, ['c1']);
      expect(f.standards.first.topics, ['Safe rotas']);
      expect(Framework.fromJson(lmf(status: 'final'))!.isDraft, isFalse);
      expect(Framework.fromJson(lmf(status: 'FINAL'))!.status, 'final');
      expect(Framework.fromJson(lmf(status: 'whatever'))!.status, 'draft');
      // Survives a round trip through storage.
      expect(Framework.decode(f.encode())!.encode(), f.encode());
    });

    test('a course-level framework is used when the program has none', () {
      final f = parseCurriculum(jsonEncode(plan(onCourse: true))).framework;
      expect(f?.name, 'Leadership framework (made-up wording)');
    });

    test('limits: 40 standards, 6 stages; descriptors clipped to 1000', () {
      expect(
        () => Framework.fromJson(lmf(standards: [for (var i = 0; i < 41; i++) standard('s$i')])),
        throwsFormatException,
      );
      expect(Framework.fromJson(lmf(standards: [for (var i = 0; i < 40; i++) standard('s$i')])), isNotNull);
      expect(
        () => Framework.fromJson(
          lmf(
            stages: [
              for (var i = 1; i <= 7; i++) {'id': '$i', 'name': 'S$i'},
            ],
          ),
        ),
        throwsFormatException,
      );
      final long = Framework.fromJson(
        lmf(
          standards: [
            standard('a', descriptors: {'1': 'x' * 1500}),
          ],
        ),
      )!;
      expect(long.standards.single.descriptors['1']!.length, maxDescriptor);
    });

    test('drops what it cannot use', () {
      final f = Framework.fromJson(
        lmf(
          target: '9',
          standards: [
            standard('a', descriptors: {'1': 'one', '7': 'no such stage', '2': ''}),
            {'id': 'A', 'title': 'Same id, other case'},
            {'id': 'b'},
            {'title': 'No id'},
            'not a map',
            {
              'id': 'c',
              'title': 'C',
              'criteria': 'not a list',
              'topics': [1, '', 'T'],
            },
          ],
        ),
      )!;
      expect(f.targetStage, '1', reason: 'an unknown target falls back to the first stage');
      expect(f.standards.map((s) => s.id), ['a', 'c']);
      expect(f.standards.first.descriptors, {'1': 'one'});
      expect(f.standards.last.criteria, isEmpty);
      expect(f.standards.last.topics, ['1', 'T']);
      expect(Framework.fromJson(lmf(standards: [])), isNull);
      expect(
        Framework.fromJson({
          'name': 'no id',
          'standards': [standard('a')],
        }),
        isNull,
      );
      expect(Framework.fromJson('nope'), isNull);
      // No stages: the descriptors' stages.
      final noStages = Framework.fromJson({...lmf(), 'stages': null})!;
      expect(noStages.stages.map((s) => s.id), ['1', '2']);
    });

    test('the AI prompt asks for the block with Udyoga\'s ids', () {
      expect(curriculumPrompt, contains('"framework"'));
      expect(curriculumPrompt, contains('"nhs_lmf"'));
      expect(curriculumPrompt, contains('self_communicating'));
      expect(curriculumPrompt, contains('"nhs_hlm"'));
      expect(curriculumPrompt, contains('"nhs_values"'));
    });
  });

  group('ratings, trend and gaps', () {
    final f = Framework.fromJson(lmf())!;

    test('history is dated, per stage, oldest first, with a trend', () {
      final v = buildFrameworkView(
        f,
        stage: '1',
        ratings: [
          row('b', '2026-11-20', rating('self_safety', 3)),
          row('a', '2026-10-01', rating('self_safety', 1)),
          row('c', '2026-11-25', rating('self_safety', 4, stage: '2')),
          row('d', '2026-11-25', rating('self-safety', 2, fw: 'other')),
        ],
        stories: const [],
      );
      final s = v.standards.first;
      expect([for (final h in s.history) h.rating.rating], [1, 3]);
      expect(ratingTrend(s.history), 2);
      expect(trendText(s.history), startsWith('Up 2 since'));
      expect(ratingTrend(s.history.take(1).toList()), isNull);
      expect(
        trendText([...s.history, (day: '2026-11-26', rating: rating('self_safety', 2))]),
        startsWith('Down 1'),
      );
    });

    test('a gap is a latest rating of 1 or less, or no story', () {
      final stories = taggedStoriesInPlan(udyogaPlan());
      final v = buildFrameworkView(
        f,
        stage: '1',
        ratings: [
          row('a', '2026-11-01', rating('self_communicating', 1)),
          row('b', '2026-11-02', rating('self_safety', 4)),
        ],
        stories: stories,
      );
      final by = {for (final s in v.standards) s.standard.id: s};
      expect(by['self_communicating']!.gapReasons, [GapReason.lowRating]);
      expect(by['self_safety']!.gapReasons, [GapReason.noEvidence]);
      expect(by['care_collaboration']!.gapReasons, [GapReason.noEvidence]);
      expect(v.gaps.length, 3);
      final better = buildFrameworkView(
        f,
        stage: '1',
        ratings: [row('c', '2026-11-03', rating('self_communicating', 2))],
        stories: stories,
      );
      expect(better.standards[1].isGap, isFalse);
    });
  });

  group('evidence from tagged stories', () {
    final f = Framework.fromJson(lmf())!;
    final s = f.standards[1];

    test('reads tags and happened from Udyoga story cards; untagged ones are skipped', () {
      final stories = taggedStoriesInPlan(udyogaPlan());
      expect(stories.single.title, 'Rota swap at the made-up clinic');
      expect(stories.single.happened, '2026-03-01');
      expect(taggedStoriesInPlan('not json'), isEmpty);
      expect(taggedStoriesInPlan('{"cards": [{"tags": [{"framework": 1}]}]}'), isEmpty);
    });

    test('matches by framework and standard id, `-` and `_` alike, or by title', () {
      expect(evidenceFor(f, s, taggedStoriesInPlan(udyogaPlan())), hasLength(1));
      expect(evidenceFor(f, s, taggedStoriesInPlan(udyogaPlan(item: 'SELF-COMMUNICATING'))), hasLength(1));
      expect(evidenceFor(f, s, taggedStoriesInPlan(udyogaPlan(framework: 'nhs_hlm'))), isEmpty);
      expect(evidenceFor(f, s, taggedStoriesInPlan(udyogaPlan(item: 'self_safety'))), isEmpty);
      expect(
        evidenceFor(f, s, taggedStoriesInPlan(udyogaPlan(item: 'x', title: 'standard SELF_COMMUNICATING'))),
        hasLength(1),
      );
    });
  });

  group('in the book', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    Future<String> pid() async => (await book.db.select(book.db.learnPrograms).getSingle()).id;

    Future<void> udyoga() => book.db
        .into(book.db.bridgeStudyPlans)
        .insert(
          BridgeStudyPlansCompanion.insert(id: 'u1', source: 'udyoga', plan: udyogaPlan(), updated: 'T'),
        );

    test('import saves the framework; a re-sent plan replaces it and keeps the ratings', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      final id = await pid();
      final f = (await book.framework(id))!;
      await book.rateStandard(id, f, f.standards.first, stage: '1', rating: 2, note: ' ok ', today: today);
      await book.importCurriculum(
        parseCurriculum(jsonEncode(plan(framework: lmf(status: 'final')))),
        today: today,
      );
      final v = (await book.frameworkView(id))!;
      expect(v.framework.isDraft, isFalse);
      expect(v.standards.first.latest!.rating.note, 'ok');
      // The stage the learner picks sticks; an unknown one falls back.
      await book.setFrameworkStage(id, '2');
      expect((await book.frameworkView(id))!.stage, '2');
      expect((await book.frameworkView(id))!.standards.first.latest, isNull);
      await book.setFrameworkStage(id, '9');
      expect((await book.frameworkView(id))!.stage, '1');
    });

    test('ratings are not tests: no stats, no history export', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      final id = await pid();
      final f = (await book.framework(id))!;
      await book.rateStandard(id, f, f.standards.first, stage: '1', rating: 4, today: today);
      expect((await book.stats(today)).assessments, isEmpty);
      expect((await book.history(today)).tests, isEmpty);
    });

    test('readiness: a self-rating never covers; a gap makes the row weak', () async {
      await udyoga();
      await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      final id = await pid();
      final f = (await book.framework(id))!;
      // c2: rated Strong with a tagged story; still only weak.
      await book.rateStandard(id, f, f.standards[1], stage: '1', rating: 4, today: today);
      // c1: rated 0 with no story: a gap.
      await book.rateStandard(id, f, f.standards[0], stage: '1', rating: 0, today: today);
      final r = await book.readiness(id, today: today);
      final by = {for (final row in r.rows) row.criterion.ref: row};
      expect(by['c2']!.status, ReadinessStatus.weak);
      expect(by['c2']!.evidence.single.kind, EvidenceKind.framework);
      expect(by['c2']!.evidence.single.weight, EvidenceWeight.unchecked);
      expect(by['c1']!.status, ReadinessStatus.weak);
      expect(by['c1']!.reasons, contains(WeakReason.selfGap));
      expect(r.rows.where((x) => x.status == ReadinessStatus.covered), isEmpty);
    });

    test('even marked strong, framework evidence is never strong', () {
      const e = Evidence(
        kind: EvidenceKind.framework,
        title: 'x',
        detail: 'x',
        weight: EvidenceWeight.strong,
        day: today,
      );
      expect(judgeEvidence([e], today).status, ReadinessStatus.weak);
    });
  });
}
