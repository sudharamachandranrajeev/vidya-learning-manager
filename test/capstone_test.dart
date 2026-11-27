// Cross-examination and capstones (assess plan A3): the plan's drill
// `persona` and `ladder`, the `capstone` block on a topic or a course, the
// 1–5 rubric mapping, the pass and streak rules, saved sittings, and the
// delivery ranges kept with a challenging round. Made-up plan.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show Store;
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/capstone.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/spoken_interview.dart';

import 'support.dart';

const today = '2026-11-27';

/// A made-up plan: a beekeeping course with two topics of drills.
Map<String, Object?> capstonePlan({
  Object? drillPersona = 'challenging',
  Object? ladder = 2,
  Object? topicCapstone,
  Object? courseCapstone,
}) => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Apiary lead'},
  'courses': [
    {
      'title': 'Hive leadership',
      'capstone': ?courseCapstone,
      'topics': [
        {
          'title': 'Inspections',
          'drills': [
            {'id': 'd1', 'question': 'Tell me about a hive inspection you led.'},
            {
              'id': 'd2',
              'question': 'Why did you not report the swarm sooner?',
              'persona': drillPersona,
              'ladder': ladder,
            },
          ],
          'capstone': ?topicCapstone,
        },
        {
          'title': 'Handover',
          'drills': [
            {'question': 'How do you hand over a colony to a new keeper?'},
          ],
        },
      ],
    },
  ],
};

CurriculumPlan parse(Map<String, Object?> j) => parseCurriculum(jsonEncode(j));

Map<String, Object?> contentOf(PlanItem i) => jsonDecode(i.content) as Map<String, Object?>;

List<PlanItem> itemsOf(CurriculumPlan p, int topic) => p.courses.single.topics[topic].items;

void main() {
  group('plan format 3: drill persona and ladder', () {
    test('valid: kept on the drill', () {
      final d2 = itemsOf(parse(capstonePlan()), 0)[1];
      expect(contentOf(d2), containsPair('persona', 'challenging'));
      expect(contentOf(d2), containsPair('ladder', 2));
    });

    test('any engine persona, any case; an out-of-range ladder is held to 1–5', () {
      final d2 = itemsOf(parse(capstonePlan(drillPersona: 'Quiet', ladder: 9)), 0)[1];
      expect((contentOf(d2)['persona'], contentOf(d2)['ladder']), ('quiet', 5));
      final low = itemsOf(parse(capstonePlan(ladder: -3)), 0)[1];
      expect(contentOf(low)['ladder'], 1);
    });

    test('invalid: an unknown panel or a ladder that is not a number is left out', () {
      final d2 = itemsOf(parse(capstonePlan(drillPersona: 'hostile', ladder: 'hard')), 0)[1];
      expect(contentOf(d2).containsKey('persona'), isFalse);
      expect(contentOf(d2).containsKey('ladder'), isFalse);
    });

    test('absent: the drill is as before', () {
      final d1 = itemsOf(parse(capstonePlan()), 0)[0];
      expect(contentOf(d1), {'question': 'Tell me about a hive inspection you led.'});
    });
  });

  group('plan format 3: capstone', () {
    test('on a topic: rules kept, drills by id or question, in order', () {
      final p = parse(
        capstonePlan(
          topicCapstone: {
            'drills': ['d2', 'How do you hand over a colony to a new keeper?', 'd1', 'd2'],
            'average': 4.0,
            'minimum': 3,
            'passesInRow': 2,
            'minutes': 45,
          },
        ),
      );
      final cap = itemsOf(p, 0).last;
      expect(
        (cap.type, cap.ref, cap.title, cap.minutes),
        ('capstone', 'capstone', 'Capstone: Inspections', 45),
      );
      final handover = itemsOf(p, 1).single.ref;
      expect(contentOf(cap), {
        'drills': ['d2', handover, 'd1'],
        'average': 4.0,
        'minimum': 3,
        'passesInRow': 2,
        'minutes': 45,
      });
    });

    test('on a course: on its last topic, marked as the course\'s', () {
      final p = parse(
        capstonePlan(
          courseCapstone: {
            'drills': ['d1'],
          },
        ),
      );
      final cap = itemsOf(p, 1).last;
      expect((cap.type, cap.ref, cap.title), ('capstone', 'capstone|course', 'Capstone: Hive leadership'));
      // Only drills are required; the rest take their defaults.
      expect(contentOf(cap), {
        'drills': ['d1'],
        'average': 4.0,
        'minimum': 3,
        'passesInRow': 1,
        'course': true,
      });
    });

    test('ranges are held; unknown drills dropped; no known drill means no capstone', () {
      final p = parse(
        capstonePlan(
          topicCapstone: {
            'drills': ['d1', 'nope'],
            'average': 7,
            'minimum': 0,
            'passesInRow': 99,
            'minutes': 1,
          },
        ),
      );
      expect(contentOf(itemsOf(p, 0).last), {
        'drills': ['d1'],
        'average': 5.0,
        'minimum': 1,
        'passesInRow': 10,
        'minutes': 5,
      });
      for (final bad in [
        {
          'drills': ['nope'],
        },
        {'drills': 'd1'},
        'd1',
        {'average': 4},
      ]) {
        expect(itemsOf(parse(capstonePlan(topicCapstone: bad)), 0).map((i) => i.type), [
          'interview drill',
          'interview drill',
        ], reason: '$bad');
      }
    });

    test('absent: no capstone item; a plan item of type capstone is not one', () {
      expect(itemsOf(parse(capstonePlan()), 0).any((i) => i.type == 'capstone'), isFalse);
      final j = capstonePlan();
      (((j['courses'] as List).single as Map)['topics'] as List)[1] = {
        'title': 'Handover',
        'items': [
          {'type': 'capstone', 'title': 'Not a capstone'},
        ],
      };
      expect(itemsOf(parse(j), 1).single.type, 'note');
    });
  });

  group('the 1–5 rubric scale', () {
    test('round(score / 8 × 4) + 1 for every self-rating and AI score', () {
      expect([for (var s = 0; s <= 8; s++) rubricOf5(s)], [1, 2, 2, 3, 3, 4, 4, 5, 5]);
      expect(rubricOf5(-2), 1);
      expect(rubricOf5(11), 5);
      expect(rubricText(6), '4/5');
      // Udyoga's score scaled to 8 maps the same way: 7/10 is 5.6/8.
      expect(rubricOf5(const UdyogaScore(day: today, score: 7, max: 10).outOf8), 4);
    });

    test('a weak drill (under 5/8) is never above 3/5', () {
      for (var s = 0; s <= 8; s++) {
        expect(drillWeak(s), rubricOf5(s) <= 3, reason: '$s/8');
      }
    });

    test('an attempt shows its own score on the scale; stored data unchanged', () {
      final self = DrillAttempt(checks: const [2, 1, 2, 1]);
      expect((self.score, self.of5), (6, 4));
      final ai = DrillAttempt(checks: const [], outOf8: 3);
      expect((ai.score, ai.of5), (3, 3));
      expect(jsonDecode(self.encode()), {
        'kind': 'drill',
        'checks': [2, 1, 2, 1],
      });
    });
  });

  group('pass and streak', () {
    const rules = CapstoneRules(drills: ['a', 'b', 'c'], average: 4.0, minimum: 3, passesInRow: 2);
    CapstoneSitting sitting(List<int?> of8) => CapstoneSitting(
      drills: [for (final (i, s) in of8.indexed) CapstoneDrill(id: '$i', title: 'Q$i', outOf8: s)],
      rules: rules,
    );

    test('passes on the average and the lowest score together', () {
      // 8, 6, 6 out of 8 are 5, 4, 4 out of 5: average 4.3, lowest 4.
      final pass = sitting([8, 6, 6]);
      expect((pass.average.toStringAsFixed(1), pass.minimum, pass.passed), ('4.3', 4, true));
      // Exactly the average passes.
      expect(sitting([6, 6, 6]).passed, isTrue);
      // Average high enough, but one drill under the minimum.
      final low = sitting([8, 8, 2]);
      expect((low.average.toStringAsFixed(1), low.minimum, low.passed), ('4.0', 2, false));
      // Every drill at the minimum, average too low.
      expect(sitting([4, 4, 4]).passed, isFalse);
      // A skipped drill fails the sitting.
      expect(sitting([8, 8, null]).passed, isFalse);
      expect(sitting([null, null, null]).passed, isFalse);
    });

    test('passes in a row: a fail resets the count', () {
      final p = sitting([8, 8, 8]), f = sitting([0, 0, 0]);
      expect(capstoneStreak([]), 0);
      expect(capstoneStreak([p]), 1);
      expect(capstoneStreak([p, p]), 2);
      expect(capstoneStreak([p, f]), 0);
      expect(capstoneStreak([p, f, p]), 1);
      expect(streakText(1, rules), '1 of 2 passes in a row');
      expect(streakText(2, rules), 'Passed 2 in a row (2 needed)');
      expect(streakText(0, const CapstoneRules(drills: ['a'])), '0 of 1 pass');
      expect(streakText(1, const CapstoneRules(drills: ['a'])), 'Passed');
    });

    test('a sitting reads back as written, with the rules it was judged by', () {
      final s = CapstoneSitting(
        drills: const [
          CapstoneDrill(id: 'x', title: 'Q', outOf8: 6, attempt: 'a1', persona: 'challenging'),
          CapstoneDrill(id: 'y', title: 'R'),
        ],
        rules: const CapstoneRules(drills: ['x', 'y'], minutes: 10),
        seconds: 700,
      );
      final back = CapstoneSitting.parse(s.encode())!;
      expect(back.drills.first.toJson(), s.drills.first.toJson());
      expect(back.drills.last.answered, isFalse);
      expect((back.rules.minutes, back.seconds, back.overTime, back.passed), (10, 700, true, false));
      expect(CapstoneSitting.parse(DrillAttempt(checks: const [2, 2, 2, 2]).encode()), isNull);
      expect(CapstoneSitting.parse('not json'), isNull);
    });
  });

  group('in the database', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    test('a sitting is saved on the capstone; done once passed N in a row; not a quiz result', () async {
      await book.importCurriculum(
        parse(
          capstonePlan(
            topicCapstone: {
              'drills': ['d1', 'd2'],
              'passesInRow': 2,
            },
          ),
        ),
        today: today,
      );
      final items = await book.db.select(book.db.learnItems).get();
      final cap = items.singleWhere((i) => i.type == capstoneType);
      final drills = await book.capstoneDrills(cap);
      expect(drills.map((d) => d.ref), ['d1', 'd2']);
      expect(drillPersona(drills.last), 'challenging');
      expect(drillLadder(drills.last), 2);
      expect(drillPreset(drills.last), (persona: ie.PersonaKind.challenging, level: 2));
      expect(drillPreset(drills.first), (persona: null, level: null));

      Future<void> sit(int of8) => book.recordCapstone(
        cap,
        CapstoneSitting(
          drills: [for (final d in drills) CapstoneDrill(id: d.id, title: d.title, outOf8: of8)],
          rules: capstoneRules(cap)!,
          seconds: 60,
        ),
        today: today,
      );
      Future<String?> done() async =>
          (await (book.db.select(book.db.learnItems)..where((i) => i.id.equals(cap.id))).getSingle()).done;

      await sit(8);
      expect(await done(), isNull, reason: 'one pass of two');
      await sit(2);
      await sit(8);
      expect(await done(), isNull, reason: 'the fail reset the count');
      await sit(8);
      expect(await done(), today);
      final sittings = await book.capstoneSittings(cap.id);
      expect([for (final (_, s) in sittings) s.passed], [true, false, true, true]);
      expect(capstoneStreak([for (final (_, s) in sittings) s]), 2);
      final (row, _) = sittings.first;
      expect((row.score, row.max, row.itemId), (5.0, 5.0, cap.id));
      expect(isQuizResult(row), isFalse);
      expect(lastQuizPercents([for (final (r, _) in sittings) r]), isEmpty);
    });

    test('a challenging round keeps delivery ranges as text, read back by question', () async {
      final id = await book.startRound(
        title: 'Apiary lead',
        framework: 'private',
        settings: const ie.RoundSettings(persona: ie.PersonaKind.challenging, level: 2),
        questions: [
          ie.EngineQuestion({'question': 'Why did you not report the swarm sooner?'}),
        ],
        criteria: const [],
        today: today,
      );
      const pace = RoundDelivery(
        label: 'Pace',
        value: '190 words a minute',
        usual: 'Usual: 120 to 170 words a minute',
        place: 'above',
      );
      await book.saveRoundDeliveries(id, 0, [
        [pace],
        [const RoundDelivery(label: 'Pauses', value: 'No pauses of a second or more')],
      ]);
      final r = (await book.savedRound(id))!;
      expect(r.persona, ie.PersonaKind.challenging);
      expect(r.deliveries[0]!.map((t) => t.map((d) => d.toJson()).toList()).toList(), [
        [pace.toJson()],
        [
          {'label': 'Pauses', 'value': 'No pauses of a second or more', 'usual': '', 'place': 'within'},
        ],
      ]);
      expect(pace.placeText, 'above the usual range');
      expect(r.settings.persona, ie.PersonaKind.challenging, reason: 'the round settings are unchanged');
    });
  });
}
