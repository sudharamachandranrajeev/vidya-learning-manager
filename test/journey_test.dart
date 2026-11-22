// The job journey (plan format 3): the parser and its limits, formats 1
// and 2 still importing, the dated templates, merging a job into its
// template, the coverage check, the journey kept in the database and the
// version 10 to 11 upgrade. Employers and criteria are made up.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/journey.dart';
import 'package:vidya/domain/journey_book.dart';
import 'package:vidya/domain/journey_templates.dart';
import 'package:vidya/domain/study_items.dart';

import 'support.dart';

const today = '2026-11-22';
const now = '2026-11-22T10:00:00.000Z';

Map<String, Object?> jobPlan({Map<String, Object?> journey = const {}, int version = 3}) => {
  'format': 'vidya-curriculum',
  'version': version,
  'program': {'title': 'Prepare: Example Officer at Example Health Trust'},
  'role': 'Example Officer',
  'criteria': [
    {'id': 'e1', 'text': 'Excellent written communication', 'essential': true},
    {'id': 'e2', 'text': 'Experience of managing a diary', 'essential': true},
    {'id': 'd1', 'text': 'Knowledge of NHS systems', 'essential': false},
  ],
  'journey': {
    'employer': 'Example Health Trust',
    'role': 'Example Officer',
    'sector': 'nhs',
    'advertUrl': 'https://example.org/jobs/123',
    'closes': '2026-12-10',
    ...journey,
  },
};

void main() {
  group('parseJourney', () {
    test('reads stages in the fixed set, sources, checks and limits', () {
      final p = parseCurriculum(
        jsonEncode(
          jobPlan(
            journey: {
              'applicationStage': 'applied',
              'stages': [
                {
                  'id': 'apply',
                  'teach': [
                    {
                      'text': 'A fact',
                      'source': {'url': 'https://example.org/a', 'title': 'Example', 'date': '2026-11-21'},
                    },
                    {'text': 'Advice'},
                    {
                      'text': 'Bad link',
                      'source': {'url': 'javascript:alert(1)'},
                    },
                    'Plain string',
                    {'text': 'Pay', 'staleAfter': '2027-04-01'},
                  ],
                  'produce': [
                    {'title': 'Statement', 'kind': 'document'},
                    'Evidence map',
                  ],
                  'check': {'kind': 'coverage', 'prompt': 'Paste it'},
                  'headsUp': ['Keep a copy'],
                  'due': '2026-12-08',
                },
                {
                  'id': 'offer',
                  'check': {
                    'kind': 'quiz',
                    'questions': [
                      {
                        'question': 'Where does pay start?',
                        'options': ['Bottom', 'Top'],
                        'answer': 0,
                      },
                      {'question': 'No answer'},
                    ],
                  },
                },
                {'id': 'made-up', 'title': 'Dropped'},
                {'id': 'apply', 'title': 'Twice'},
                {
                  'id': 'checks',
                  'check': {'kind': 'telepathy'},
                },
              ],
            },
          ),
        ),
      );
      final j = p.journey!;
      expect(
        (j.employer, j.role, j.sector, j.closes, j.applicationStage),
        ('Example Health Trust', 'Example Officer', 'nhs', '2026-12-10', 'applied'),
      );
      expect(j.stages.map((s) => s.id), ['apply', 'offer', 'checks']);
      final apply = j.stage('apply')!;
      expect(apply.title, 'Apply');
      expect(apply.teach.map((l) => l.text), ['A fact', 'Advice', 'Bad link', 'Plain string', 'Pay']);
      expect(apply.teach.map((l) => l.sourced), [true, false, false, false, false]);
      expect(apply.teach.first.source!.date, '2026-11-21');
      expect(apply.teach.last.staleOn('2027-03-31'), isFalse);
      expect(apply.teach.last.staleOn('2027-04-01'), isTrue);
      expect(apply.produce.map((x) => (x.title, x.kind)), [
        ('Statement', 'document'),
        ('Evidence map', 'note'),
      ]);
      expect(apply.check!.kind, 'coverage');
      expect(apply.due, '2026-12-08');
      final quiz = j.stage('offer')!.check!;
      expect(quiz.questions.single['answer'], 'Bottom');
      expect(j.stage('checks')!.check, isNull);
    });

    test('a hostile journey is refused with a plain message', () {
      expect(
        () => parseCurriculum(
          jsonEncode(
            jobPlan(
              journey: {
                'stages': [
                  for (var i = 0; i < 21; i++) {'id': 'decide'},
                ],
              },
            ),
          ),
        ),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('Too many journey stages')),
        ),
      );
      expect(
        () => parseCurriculum(jsonEncode({...jobPlan(), 'journey': 'nope'})),
        throwsA(isA<FormatException>()),
      );
      // A journey with an unknown sector is kept as "other"; a bad date is dropped.
      final j = parseCurriculum(jsonEncode(jobPlan(journey: {'sector': 'moon', 'closes': '31/12/2026'})))
          .journey!;
      expect((j.sector, j.closes), ('other', null));
    });

    test('formats 1 and 2 still import without a journey; format 4 is refused', () {
      for (final v in [1, 2]) {
        final plan = {...jobPlan(version: v)}..remove('journey');
        plan['courses'] = [
          {
            'title': 'C',
            'topics': ['T'],
          },
        ];
        final p = parseCurriculum(jsonEncode(plan));
        expect(p.journey, isNull);
        expect(p.courses.single.topics.single.title, 'T');
      }
      // Udyoga sends its journey on a version 1 plan; it is read all the same.
      expect(parseCurriculum(jsonEncode(jobPlan(version: 1))).journey!.role, 'Example Officer');
      expect(curriculumVersion, 3);
      expect(
        () => parseCurriculum(jsonEncode(jobPlan(version: 4))),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer Vidya'))),
      );
      // A journey alone is a whole plan.
      expect(parseCurriculum(jsonEncode(jobPlan())).courses, isEmpty);
    });

    test('a journey survives its own JSON', () {
      final j = parseCurriculum(
        jsonEncode(
          jobPlan(
            journey: {
              'stages': [nhsTemplate.stage('offer')!.toJson()],
            },
          ),
        ),
      ).journey!;
      final again = parseJourney(jsonDecode(jsonEncode(j.toJson())));
      expect(jsonEncode(again.toJson()), jsonEncode(j.toJson()));
      expect(again.stage('offer')!.check!.questions, hasLength(3));
    });
  });

  group('templates', () {
    final templates = [nhsTemplate, universityTemplate, privateTemplate];

    test('every template has every stage in order, each with something to learn, produce and check', () {
      for (final t in templates) {
        expect(t.stages.map((s) => s.id), journeyStages.keys, reason: t.template);
        expect(t.stages.map((s) => s.order), List.generate(journeyStages.length, (i) => i));
        for (final s in t.stages) {
          expect(s.teach, isNotEmpty, reason: '${t.template} ${s.id}');
          expect(s.produce, isNotEmpty, reason: '${t.template} ${s.id}');
          expect(s.check, isNotNull, reason: '${t.template} ${s.id}');
        }
        expect(t.checked, templatesChecked);
      }
    });

    test('every source is a web address checked on the template date, and parses back', () {
      var sourced = 0;
      for (final t in templates) {
        for (final s in t.stages) {
          for (final l in [...s.teach, ...s.headsUp]) {
            if (l.source case final src?) {
              sourced++;
              expect(src.url, startsWith('https://'));
              expect(src.date, templatesChecked, reason: l.text);
              expect(src.title, isNotEmpty);
            }
          }
          // The template goes through the same reader as a plan.
          final back = parseJourney({
            'stages': [s.toJson()],
          }).stages.single;
          expect(jsonEncode(back.toJson()), jsonEncode(s.toJson()));
        }
      }
      expect(sourced, greaterThanOrEqualTo(30));
    });

    test('NHS pay figures are for 2026/27 and flagged for April; the key rules are there', () {
      String all(Journey t) => [
        for (final s in t.stages)
          for (final l in [...s.teach, ...s.headsUp]) l.text,
      ].join('\n');
      final pay = nhsTemplate.stages.expand((s) => s.teach).where((l) => l.text.contains('£25,760')).toList();
      expect(pay, isNotEmpty);
      for (final l in pay) {
        expect(l.text, contains('2026/27'));
        expect(l.staleAfter, '2027-04-01');
      }
      final nhs = all(nhsTemplate);
      expect(nhs, contains('bottom pay point of the new band'));
      expect(nhs, contains('agreed before you accept'));
      expect(nhs, contains('6 months before the offer letter'));
      expect(nhs, contains('Inter Authority Transfer'));
      expect(nhs, contains('probation period of about 6 months'));
      expect(nhs, contains('thank-you email is optional'));
      expect(nhs, contains('criterion by criterion'));
      expect(all(universityTemplate), contains('allows up to 9'));
      // No pay figures outside the NHS template, where none were checked.
      expect(all(universityTemplate), isNot(contains('£')));
      expect(all(privateTemplate), isNot(contains('£')));
    });

    test('the Civil Service and other employers get the general template', () {
      final t = templateFor('civil-service');
      expect((t.template, t.sector), ('General', 'civil-service'));
      expect(t.stages.map((s) => s.id), journeyStages.keys);
      expect(templateFor('nhs'), same(nhsTemplate));
    });
  });

  group('mergeJourney', () {
    final criteria = <PlanCriterion>[
      (id: 'e1', text: 'Excellent written communication', essential: true, kind: '', source: '', shown: null),
      (id: 'd1', text: 'Knowledge of NHS systems', essential: false, kind: '', source: '', shown: null),
    ];

    test('fills every stage from the template and adds the job\'s criteria and dates', () {
      final job = parseCurriculum(jsonEncode(jobPlan())).journey!;
      final j = mergeJourney(job, nhsTemplate, criteria: criteria);
      expect(j.stages.map((s) => s.id), journeyStages.keys);
      expect((j.template, j.checked, j.employer), ('NHS', templatesChecked, 'Example Health Trust'));
      final decide = j.stage('decide')!;
      expect(decide.teach.first.text, contains('1 essential criterion: Excellent written communication'));
      expect(decide.teach.first.source!.url, 'https://example.org/jobs/123');
      final apply = j.stage('apply')!;
      expect(apply.produce.map((p) => p.title), contains('Evidence for: Excellent written communication'));
      expect(apply.produce.map((p) => p.title), isNot(contains('Evidence for: Knowledge of NHS systems')));
      expect(apply.due, '2026-12-08');
      expect(j.stage('contact')!.due, '2026-12-03');
      expect(j.stage('decide')!.due, '2026-11-30');
      expect(j.stage('offer')!.due, isNull);
    });

    test('a stage the job brings keeps its own lines and borrows the rest', () {
      final job = parseCurriculum(
        jsonEncode(
          jobPlan(
            journey: {
              'closes': null,
              'stages': [
                {
                  'id': 'prepare',
                  'teach': ['Panel of three; a 10-minute presentation.'],
                  'due': '2026-12-20',
                },
              ],
            },
          ),
        ),
      ).journey!;
      final j = mergeJourney(job, nhsTemplate);
      final s = j.stage('prepare')!;
      expect(s.teach.single.text, 'Panel of three; a 10-minute presentation.');
      expect(s.produce, nhsTemplate.stage('prepare')!.produce);
      expect(s.check!.kind, 'interviewer');
      expect(s.headsUp, nhsTemplate.stage('prepare')!.headsUp);
      expect(s.due, '2026-12-20');
      expect(j.stage('apply')!.due, isNull);
    });

    test('Udyoga\'s application stage suggests a journey stage', () {
      expect(stageForApplication('preparing'), 'apply');
      expect(stageForApplication('applied'), 'follow-up');
      expect(stageForApplication('interview'), 'prepare');
      expect(stageForApplication('rejected'), 'after');
      expect(stageForApplication('offer'), 'offer');
      expect(stageForApplication('checks'), 'checks');
      expect(stageForApplication('accepted'), 'joining');
      expect(stageForApplication('withdrawn'), isNull);
      expect(stageForApplication(''), isNull);
    });
  });

  group('coverageCheck', () {
    test('finds the criterion\'s own words, some of its words, or none', () {
      const draft =
          'I have excellent written communication, shown in the minutes I write. I managed three '
          'diaries for directors.';
      final rows = coverageCheck(draft, [
        'Excellent written communication',
        'Experience of managing a diary',
        'Ability to use Microsoft Excel',
      ]);
      expect(rows.map((r) => r.coverage), [Coverage.exact, Coverage.partly, Coverage.missing]);
      expect(rows[1].missingWords, isEmpty);
      expect(rows[2].missingWords, containsAll(['microsoft', 'excel']));
      // Case, punctuation and line breaks do not matter; part of a word is not a match.
      expect(
        coverageCheck('EXCELLENT\nwritten-communication!', [
          'excellent written communication',
        ]).single.coverage,
        Coverage.exact,
      );
      expect(
        coverageCheck('reexcellent written communications', [
          'excellent written communication',
        ]).single.coverage,
        Coverage.partly,
      );
      expect(coverageCheck('', ['Anything at all']).single.coverage, Coverage.missing);
      expect(wordCount('  one two\nthree  '), 3);
    });
  });

  group('in the book', () {
    late AppDatabase db;
    late LearningBook book;
    setUp(() async {
      db = memoryDatabase();
      book = LearningBook(await Store.open(db));
    });
    tearDown(() => db.close());

    Future<String> add([Map<String, Object?>? plan]) async =>
        (await book.importCurriculum(parseCurriculum(jsonEncode(plan ?? jobPlan())), today: today)).programId;

    test('a plan\'s journey is saved and shown merged; sending it again keeps the learner\'s work', () async {
      final pid = await add();
      var v = (await book.journeyView(pid))!;
      expect(v.current, 'decide');
      expect(v.suggested, isNull);
      expect(v.journey.stages, hasLength(13));
      expect(
        v.journey.stage('apply')!.produce.map((p) => p.title),
        containsAll([
          'Evidence for: Excellent written communication',
          'Evidence for: Experience of managing a diary',
        ]),
      );

      await book.setJourneyStage(pid, 'apply', now: now);
      await book.setProduced(pid, 'apply', 'Supporting statement draft', true, now: now);
      await book.setProduceNote(
        pid,
        'apply',
        'Supporting statement draft',
        '  In my documents folder ',
        now: now,
      );
      final items = nhsTemplate.stage('follow-up')!.check!.items;
      for (final i in items.take(items.length - 1)) {
        await book.setTicked(pid, 'follow-up', i, true, items: items, now: now);
      }
      v = (await book.journeyView(pid))!;
      expect(v.of('follow-up').checkDone, '');
      expect(v.of('follow-up').checkResult, '2 of 3 ticked');
      await book.setTicked(pid, 'follow-up', items.last, true, items: items, now: now);

      // Udyoga sends the plan again: the application is in.
      await add(jobPlan(journey: {'applicationStage': 'applied'}));
      v = (await book.journeyView(pid))!;
      expect(v.current, 'apply');
      expect(v.suggested, 'follow-up');
      expect(v.journey.applicationStage, 'applied');
      expect(v.of('apply').produced, {'Supporting statement draft': today});
      expect(v.of('apply').notes, {'Supporting statement draft': 'In my documents folder'});
      expect(v.of('follow-up').checkDone, today);
      expect(v.of('follow-up').checkResult, 'All 3 ticked');
      expect(await db.select(db.learnJourneys).get(), hasLength(1));

      await book.setProduced(pid, 'apply', 'Supporting statement draft', false, now: now);
      expect((await book.journeyView(pid))!.of('apply').produced, isEmpty);
    });

    test('without a stage of its own, the application stage picks one', () async {
      final pid = await add(jobPlan(journey: {'applicationStage': 'interview'}));
      final v = (await book.journeyView(pid))!;
      expect((v.current, v.suggested), ('prepare', null));
    });

    test('a pasted draft is checked against the essential criteria and kept', () async {
      final pid = await add();
      const essentials = ['Excellent written communication', 'Experience of managing a diary'];
      var rows = await book.checkDraft(
        pid,
        'apply',
        'My excellent written communication.',
        essentials,
        now: now,
      );
      expect(rows.map((r) => r.coverage), [Coverage.exact, Coverage.missing]);
      var p = (await book.journeyView(pid))!.of('apply');
      expect((p.checkDone, p.checkResult), ('', '1 of 2 essential criteria in their own words'));
      expect(p.draft, 'My excellent written communication.');
      rows = await book.checkDraft(
        pid,
        'apply',
        'Excellent written communication. Experience of managing a diary.',
        essentials,
        now: now,
      );
      p = (await book.journeyView(pid))!.of('apply');
      expect(p.checkDone, today);
    });

    test('quiz and own checks are recorded and cleared', () async {
      final pid = await add();
      await book.setCheck(pid, 'offer', day: today, result: '3 of 3 right', now: now);
      expect((await book.journeyView(pid))!.of('offer').checkResult, '3 of 3 right');
      await book.setCheck(pid, 'offer', day: '', now: now);
      expect((await book.journeyView(pid))!.of('offer').checkDone, '');
    });

    test('one drill per essential criterion for the interviewer, once', () async {
      final pid = await add();
      expect(await book.addCriterionDrills(pid, today: today), 2);
      expect(await book.addCriterionDrills(pid, today: today), 0);
      final drills = (await book.programDrills(pid)).drills;
      expect(
        drills.map((d) => d.title),
        contains('Tell me about a time you showed this: Excellent written communication'),
      );
      expect(drills.map((d) => itemContent(d)['criterion']), containsAll(['e1', 'e2']));
    });

    test('a journey can be started by hand, and goes with its program', () async {
      final pid = await book.addProgram('Example role', '', today: today);
      expect(await book.journeyView(pid), isNull);
      await book.startJourney(pid, role: 'Example role', sector: 'university', now: now);
      final v = (await book.journeyView(pid))!;
      expect((v.journey.template, v.journey.role), ('University', 'Example role'));
      await book.removeProgram(pid);
      expect(await book.journeyRow(pid), isNull);
    });
  });

  group('from Udyoga', () {
    late AppDatabase db;
    late LearningBook book;
    setUp(() async {
      db = memoryDatabase();
      book = LearningBook(await Store.open(db));
    });
    tearDown(() => db.close());

    test('"Study for this role" brings a journey with the role and a sector guess', () async {
      // Written by Udyoga's tests (test/fixtures/udyoga-role-plan.json there).
      final p = parseCurriculum(File('test/fixtures/udyoga-role-plan.json').readAsStringSync());
      expect((p.journey!.role, p.journey!.sector, p.journey!.employer), ('IT Trainer', 'nhs', ''));
      final pid = (await book.importCurriculum(p, today: today)).programId;
      final v = (await book.journeyView(pid))!;
      expect((v.journey.template, v.current), ('NHS', 'decide'));
      expect(
        v.journey.stage('apply')!.produce.map((x) => x.title),
        contains('Evidence for: Teaching qualification'),
      );
    });

    test(
      '"Prepare this job" brings the employer, advert, closing date, criteria and the application stage',
      () async {
        // Written by Udyoga's tests (test/fixtures/udyoga-job-plan.json there).
        final p = parseCurriculum(File('test/fixtures/udyoga-job-plan.json').readAsStringSync());
        final j = p.journey!;
        expect(
          (j.employer, j.sector, j.advertUrl, j.closes, j.applicationStage),
          ('Example Health Trust', 'nhs', 'https://example.org/jobs/123', '2026-12-10', 'applied'),
        );
        expect(p.criteria.map((c) => (c.id, c.essential)), [('c1', true), ('c2', true), ('c3', false)]);
        final pid = (await book.importCurriculum(p, today: today)).programId;
        final v = (await book.journeyView(pid))!;
        // No stage chosen yet: Udyoga's "applied" picks one, with nothing else to suggest.
        expect((v.current, v.suggested), ('follow-up', null));
        expect(v.journey.stage('apply')!.due, '2026-12-08');
        expect(v.journey.stage('decide')!.teach.first.text, contains('2 essential criteria'));
        final program = await (db.select(db.learnPrograms)..where((x) => x.id.equals(pid))).getSingle();
        expect(program.title, 'Prepare: Clinical Informatics Nurse at Example Health Trust');
      },
    );
  });

  test('a version 10 database gains the journeys table and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v10.db');
    var db10 = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db10));
    final plan = {...jobPlan()}..remove('journey');
    plan['courses'] = [
      {
        'title': 'C',
        'topics': [
          {
            'title': 'T',
            'drills': [
              {'id': 'q1', 'question': 'Why this job?', 'criterion': 'e1'},
            ],
          },
        ],
      },
    ];
    final pid = (await b.importCurriculum(parseCurriculum(jsonEncode(plan)), today: today)).programId;
    final d = (await (db10.select(db10.learnItems)..where((i) => i.ref.equals('q1'))).get()).single;
    await b.recordDrill(d, const DrillAttempt(checks: [2, 1, 1, 1]), today: today);
    Future<List<Object>> rows(AppDatabase db) async => [
      ...(await db.select(db.learnPrograms).get()).map((r) => (r.id, r.title, r.role)),
      ...(await db.select(db.learnCriteria).get()).map((r) => (r.id, r.body, r.essential)),
      ...(await db.select(db.learnItems).get()).map((r) => (r.id, r.content)),
      ...(await db.select(db.learnAssessments).get()).map((r) => (r.id, r.score, r.detail)),
    ];
    final before = await rows(db10);
    // Back to version 10: no journeys table.
    await db10.customStatement('DROP INDEX IF EXISTS learn_journeys_program');
    await db10.customStatement('DROP TABLE learn_journeys');
    await db10.customStatement('PRAGMA user_version = 10');
    await db10.close();

    db10 = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db10));
    expect(await rows(db10), before);
    // The new table works.
    await b.importCurriculum(
      parseCurriculum(jsonEncode({...plan, 'journey': jobPlan()['journey']})),
      today: today,
    );
    expect((await b.journeyView(pid))!.journey.employer, 'Example Health Trust');
    final indexes = await db10.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get();
    expect(indexes.map((r) => r.read<String>('name')), contains('learn_journeys_program'));
    await db10.close();
    await dir.delete(recursive: true);
  });
}
