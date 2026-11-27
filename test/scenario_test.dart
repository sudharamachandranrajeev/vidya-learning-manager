// Stress tests (assess plan A5): the plan's `scenario` item, its limits,
// the automatic checks (untouched high-risk rows, expected actions), the
// saved attempt and its done rule, and the progress kept on the device.
// Made-up plan: a community library's returns desk, no real people.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show Store;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/scenario.dart';
import 'package:vidya/domain/study_items.dart';

import 'support.dart';

const today = '2026-11-27';

Map<String, Object?> deskScenario({Object? rows, Object? minutes = 20, Object? actions}) => {
  'type': 'scenario',
  'id': 'st1',
  'title': 'Returns desk triage',
  'minutes': minutes,
  'brief': 'You run the **returns desk** alone this morning.',
  'columns': ['Item', 'Shelf', 'Days late', 'Flags'],
  'rows':
      rows ??
      [
        {
          'cells': ['B001', 'Maps', '40', 'water damage reported'],
          'risk': 'high',
          'expect': 'escalate',
          'why': 'Damage goes to the conservator the same day.',
        },
        {
          'cells': ['B002', 'Fiction', '2', ''],
          'risk': 'low',
          'expect': 'act',
        },
        {
          'cells': ['B003', 'Local history', '15', 'only copy'],
          'risk': 'high',
        },
        {
          'cells': ['B004', 'Poetry', '0', ''],
        },
      ],
  'actions': ?actions,
  'rubric': 'Damage and only copies first; every escalation has a reason.',
  'criteria': ['c1'],
};

Map<String, Object?> plan(List<Object?> items) => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Library assistant'},
  'courses': [
    {
      'title': 'Front desk',
      'topics': [
        {'title': 'Returns', 'items': items},
      ],
    },
  ],
};

PlanItem? planScenario(Map<String, Object?> item) =>
    parseCurriculum(jsonEncode(plan([item]))).courses.single.topics.single.items.firstOrNull;

void main() {
  group('plan format', () {
    test('a valid scenario item keeps its brief, table, actions and rubric', () {
      final i = planScenario(deskScenario())!;
      expect(i.type, 'scenario');
      expect(i.ref, 'st1');
      expect(i.minutes, 20);
      final s = Scenario.fromJson(jsonDecode(i.content))!;
      expect(s.columns, ['Item', 'Shelf', 'Days late', 'Flags']);
      expect(s.rows, hasLength(4));
      expect(s.rows[0].risk, 'high');
      expect(s.rows[0].expect, 'escalate');
      expect(s.rows[0].why, startsWith('Damage'));
      expect(s.rows[3].risk, '');
      expect(s.actions, defaultScenarioActions);
      expect(s.highRows, [0, 2]);
      expect(s.brief, contains('returns desk'));
      expect(s.rubric, startsWith('Damage'));
      expect(s.criteria, ['c1']);
    });

    test('the type is also read from "stress test" and other aliases', () {
      expect(itemTypeOf('stress test'), 'scenario');
      expect(itemTypeOf('Stress-Test'), 'scenario');
      expect(itemTypeOf('scenario'), 'scenario');
      expect(itemTypeOf('in-tray exercise'), 'scenario');
      expect(addableItemTypes.containsKey('scenario'), isFalse, reason: 'only from a plan');
      expect(checkTypes, contains('scenario'));
    });

    test('limits: rows, columns, cells and minutes are held to their ranges', () {
      final many = [
        for (var k = 0; k < 75; k++)
          {
            'cells': ['R$k', 'x' * 300, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
            'risk': k == 0 ? 'HIGH' : 'severe',
            'expect': k == 0 ? 'panic' : 'Leave',
          },
      ];
      final item = {
        ...deskScenario(rows: many, minutes: 999),
        'columns': ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'c9', 'c10'],
      };
      final s = Scenario.fromJson(jsonDecode(planScenario(item)!.content))!;
      expect(s.rows, hasLength(Scenario.maxRows));
      expect(s.columns, hasLength(Scenario.maxColumns));
      expect(s.rows.first.cells, hasLength(Scenario.maxColumns));
      expect(s.rows.first.cells[1], hasLength(Scenario.maxCell));
      expect(s.minutes, Scenario.maxMinutes);
      expect(s.rows[0].risk, 'high', reason: 'case does not matter');
      expect(s.rows[0].expect, '', reason: 'not one of the actions');
      expect(s.rows[1].risk, '', reason: 'unknown risk dropped');
      expect(s.rows[1].expect, 'leave');
      expect(Scenario.fromJson({...deskScenario(), 'minutes': 1})!.minutes, Scenario.minMinutes);
      expect(Scenario.fromJson({...deskScenario(), 'minutes': null})!.minutes, Scenario.defaultMinutes);
    });

    test('custom actions: kept in lower case once each; fewer than two take the defaults', () {
      final s = Scenario.fromJson(deskScenario(actions: ['Call', 'call', 'Email', 'Wait']))!;
      expect(s.actions, ['call', 'email', 'wait']);
      expect(s.rows[0].expect, '', reason: '"escalate" is not one of these actions');
      expect(Scenario.fromJson(deskScenario(actions: ['only']))!.actions, defaultScenarioActions);
    });

    test('absent or unusable: no table drops the item; empty rows are skipped', () {
      expect(planScenario({'type': 'scenario', 'title': 'No table'}), isNull);
      expect(planScenario({...deskScenario(), 'columns': []}), isNull);
      expect(planScenario(deskScenario(rows: [])), isNull);
      expect(planScenario(deskScenario(rows: ['not a row', {}])), isNull);
      final s = Scenario.fromJson(
        deskScenario(
          rows: [
            {
              'cells': ['', '', ''],
            },
            ['A1', 'Atlas'],
          ],
        ),
      )!;
      expect(s.rows.single.cells, ['A1', 'Atlas', '', ''], reason: 'a bare list is a row; short rows padded');
      expect(Scenario.fromJson('nope'), isNull);
    });

    test('a topic without a scenario is unchanged, and the AI prompt explains the item', () {
      final p = parseCurriculum(
        jsonEncode(
          plan([
            {'type': 'video', 'title': 'Shelving', 'url': 'https://example.org/v'},
          ]),
        ),
      );
      expect(p.courses.single.topics.single.items.single.type, 'video');
      expect(curriculumPrompt, contains('"type": "scenario"'));
      expect(curriculumPrompt, contains('A "scenario" item is a timed stress test'));
    });
  });

  group('checks', () {
    final s = Scenario.fromJson(deskScenario())!;

    test('untouched high-risk rows, expected actions and counts', () {
      final f = scenarioFindings(s, ['leave', 'act', '', '']);
      expect(f.untouchedHigh, [2]);
      expect(f.matched, [1]);
      expect(f.mismatched, [0]);
      expect(f.counts, {'act': 1, 'escalate': 0, 'leave': 1, 'note': 0, '': 2});
    });

    test('every high-risk row touched and every expectation met', () {
      final f = scenarioFindings(s, ['escalate', 'act', 'note']);
      expect(f.untouchedHigh, isEmpty);
      expect(f.matched, [0, 1]);
      expect(f.mismatched, isEmpty);
      expect(f.counts[''], 1, reason: 'a short pick list counts as no action');
    });

    test('done needs no untouched high-risk row and a rating of 5/8 or more', () {
      ScenarioAttempt a(List<String> picks, List<int> checks) =>
          ScenarioAttempt(scenario: s, picks: picks, reasons: List.filled(4, ''), checks: checks);
      expect(a(['escalate', 'act', 'note', ''], [2, 1, 1, 1]).passed, isTrue);
      expect(a(['escalate', 'act', 'note', ''], [2, 1, 1, 1]).of5, 4);
      expect(a(['escalate', 'act', 'note', ''], [1, 1, 1, 1]).passed, isFalse, reason: '4/8');
      expect(a(['escalate', 'act', '', ''], [2, 2, 2, 2]).passed, isFalse, reason: 'row 3 untouched');
    });

    test('an attempt round-trips through its detail, scenario included', () {
      final a = ScenarioAttempt(
        scenario: s,
        picks: ['escalate', '', 'note', 'leave'],
        reasons: ['damage', '', 'only copy', ''],
        checks: [2, 2, 1, 0],
        seconds: 300,
        timedOut: true,
      );
      final back = ScenarioAttempt.parse(a.encode())!;
      expect(back.picks, a.picks);
      expect(back.reasons, a.reasons);
      expect(back.outOf8, 5);
      expect(back.seconds, 300);
      expect(back.timedOut, isTrue);
      expect(back.scenario.rows[0].why, s.rows[0].why);
      expect(jsonDecode(a.encode())['kind'], 'scenario');
      expect(ScenarioAttempt.parse('{"kind":"capstone"}'), isNull);
      expect(ScenarioAttempt.parse('not json'), isNull);
    });

    test('progress on the device round-trips and fits the table', () {
      final p = ScenarioProgress(
        start: DateTime.utc(2026, 11, 27, 9),
        picks: ['act', 'leave'],
        reasons: ['why', ''],
        handedIn: 61,
      );
      final back = ScenarioProgress.parse(p.encode(), 4)!;
      expect(back.start.toUtc(), DateTime.utc(2026, 11, 27, 9));
      expect(back.picks, ['act', 'leave', '', '']);
      expect(back.reasons, ['why', '', '', '']);
      expect(back.handedIn, 61);
      expect(ScenarioProgress.parse('', 4), isNull);
      expect(ScenarioProgress.parse('{bad', 4), isNull);
    });
  });

  group('saved attempts', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    test('an attempt is a result on the item; a passing one marks it done', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(plan([deskScenario()]))), today: today);
      final item = (await book.db.select(book.db.learnItems).get()).singleWhere((i) => i.type == 'scenario');
      final s = scenarioOf(item)!;
      final failing = ScenarioAttempt(
        scenario: s,
        picks: ['escalate', 'act', '', ''],
        reasons: List.filled(4, ''),
        checks: [2, 2, 2, 2],
      );
      await book.recordScenario(item, failing, today: today);
      var fresh = (await book.db.select(book.db.learnItems).get()).singleWhere((i) => i.id == item.id);
      expect(fresh.done, isNull);

      final passing = ScenarioAttempt(
        scenario: s,
        picks: ['escalate', 'act', 'note', 'leave'],
        reasons: List.filled(4, ''),
        checks: [2, 2, 1, 1],
        seconds: 600,
      );
      await book.recordScenario(item, passing, today: today);
      fresh = (await book.db.select(book.db.learnItems).get()).singleWhere((i) => i.id == item.id);
      expect(fresh.done, today);
      final attempts = await book.scenarioAttempts(item.id);
      expect(attempts, hasLength(2));
      expect(attempts.last.$1.score, 4, reason: "6/8 is 4/5");
      expect(attempts.last.$1.max, 5);
      expect(attempts.last.$1.topicId, item.topicId);
      expect(attempts.first.$2.findings.untouchedHigh, [2]);
    });
  });
}
