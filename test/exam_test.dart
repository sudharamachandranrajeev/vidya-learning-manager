import 'dart:convert';
import 'dart:math';

import 'package:brahma_core/brahma_core.dart' show Store;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/exam.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/study_items.dart';

import 'support.dart';

const today = '2026-11-27';

/// A made-up plan: a pottery course whose last topic is a timed mock exam
/// with questions tagged by topic.
Map<String, Object?> examPlan({Object? exam = const {}, int version = 3}) => {
  'format': 'vidya-curriculum',
  'version': version,
  'program': {'title': 'Pottery certificate'},
  'courses': [
    {
      'title': 'Wheel work',
      'topics': [
        {'title': 'Centering', 'id': 't-center'},
        {'title': 'Trimming'},
        {
          'title': 'Mock exam',
          'quiz': [
            {
              'question': 'Which hand braces on the knee?',
              'options': ['Left', 'Right'],
              'answer': 'Left',
              'topic': 't-center',
            },
            {'question': 'What runs true?', 'answer': 'The clay', 'topic': 'centering'},
            {'question': 'What tool trims a foot ring?', 'answer': 'A loop tool', 'topic': 'Trimming'},
            {'question': 'When is leather hard?', 'answer': 'Firm but damp', 'topic': 'Glazing'},
          ],
          'exam': ?exam,
        },
      ],
    },
  ],
};

PlanItem quizOf(CurriculumPlan p) => p.courses.single.topics.last.items.single;

int quizLength2(CurriculumPlan p) => ((jsonDecode(quizOf(p).content) as Map)['questions'] as List).length;

Assessment row(String day, {String detail = '', String topic = 't', String hlc = 'a', double score = 1}) =>
    Assessment(
      id: '$day$hlc',
      hlc: hlc,
      deleted: false,
      courseId: null,
      topicId: topic,
      title: 'x',
      day: day,
      score: score,
      max: 2,
      itemId: null,
      detail: detail,
    );

const q1 = QuizQuestion(question: 'One?', answer: 'a', topic: 'Centering');
const q2 = QuizQuestion(question: 'Two?', answer: 'b', topic: 'Trimming');
const q3 = QuizQuestion(question: 'Three?', answer: 'c', topic: 'Trimming');
const q4 = QuizQuestion(question: 'Four?', answer: 'd');

void main() {
  group('plan format: exam and question topics', () {
    test('a full exam block is read and kept in the quiz content', () {
      final p = parseCurriculum(
        jsonEncode(examPlan(exam: {'minutes': 25, 'passPercent': 80, 'retakeDays': 7, 'shuffle': true})),
      );
      final quiz = quizOf(p);
      final content = jsonDecode(quiz.content) as Map;
      expect(content['exam'], {'minutes': 25, 'passPercent': 80, 'retakeDays': 7, 'shuffle': true});
      expect(quiz.minutes, 25, reason: 'an exam takes its own time');
      final topics = [for (final q in content['questions'] as List) (q as Map)['topic']];
      expect(topics, [
        'Centering',
        'Centering',
        'Trimming',
        'Glazing',
      ], reason: 'id and case resolve to titles');
    });

    test('out-of-range values are held to their ranges', () {
      ExamRules rules(Map<String, Object?> e) => ExamRules.fromJson(
        jsonDecode(quizOf(parseCurriculum(jsonEncode(examPlan(exam: e)))).content)['exam'],
      );
      expect(
        rules({'minutes': 0, 'passPercent': 0, 'retakeDays': -3}),
        const ExamRules(minutes: 1, passPercent: 1, retakeDays: 0),
      );
      expect(
        rules({'minutes': 9999, 'passPercent': 250, 'retakeDays': 400, 'shuffle': 'yes'}),
        const ExamRules(minutes: 300, passPercent: 100, retakeDays: 60),
      );
      expect(rules({}), const ExamRules(minutes: 6, passPercent: 70), reason: '1.5 min a question, 70%');
    });

    test('count is read and held to 1–100; the time defaults to 1.5 minutes a question drawn', () {
      ExamRules rules(Map<String, Object?> e) => ExamRules.fromJson(
        jsonDecode(quizOf(parseCurriculum(jsonEncode(examPlan(exam: e)))).content)['exam'],
      );
      expect(rules({'count': 2}), const ExamRules(minutes: 3, count: 2));
      expect(rules({'count': 0}).count, 1);
      expect(rules({'count': 500}).count, 100);
      expect(rules({'count': 'many'}).count, isNull);
      expect(rules({}).count, isNull);
    });

    test('an exam topic may hold 100 questions; a practice quiz still 20', () {
      List<Map<String, Object>> qs(int n) => [
        for (var i = 0; i < n; i++) {'question': 'Q$i?', 'answer': 'a'},
      ];
      Map<String, Object?> withQuiz(int n, {bool exam = true}) {
        final p = examPlan(exam: exam ? {'minutes': 60} : null);
        final topics = ((p['courses'] as List).single as Map)['topics'] as List;
        (topics.last as Map)['quiz'] = qs(n);
        return p;
      }

      expect(quizLength2(parseCurriculum(jsonEncode(withQuiz(100)))), 100);
      expect(() => parseCurriculum(jsonEncode(withQuiz(101))), throwsA(isA<FormatException>()));
      expect(() => parseCurriculum(jsonEncode(withQuiz(21, exam: false))), throwsA(isA<FormatException>()));
      expect(quizLength2(parseCurriculum(jsonEncode(withQuiz(20, exam: false)))), 20);
    });

    test('a quiz given as an object with questions and exam is read too', () {
      final plan = examPlan(exam: null);
      final topic = ((plan['courses'] as List).single as Map)['topics'] as List;
      final mock = topic.last as Map;
      topic[2] = {
        'title': 'Mock exam',
        'quiz': {
          'questions': mock['quiz'],
          'exam': {'minutes': 10},
        },
      };
      final content = jsonDecode(quizOf(parseCurriculum(jsonEncode(plan))).content) as Map;
      expect((content['questions'] as List).length, 4);
      expect(content['exam'], {'minutes': 10, 'passPercent': 70, 'retakeDays': 0, 'shuffle': false});
    });

    test('without an exam block, and in older plans, the quiz is as before', () {
      for (final version in [1, 2, 3]) {
        final p = parseCurriculum(jsonEncode(examPlan(exam: null, version: version)));
        final quiz = quizOf(p);
        final content = jsonDecode(quiz.content) as Map;
        expect(content.containsKey('exam'), isFalse);
        expect(quiz.minutes, 6);
        expect(content.keys, ['questions']);
      }
      // An exam that is not an object is ignored.
      expect((jsonDecode(quizOf(parseCurriculum(jsonEncode(examPlan(exam: 5)))).content) as Map).keys, [
        'questions',
      ]);
    });

    test('the prompt teaches the exam block and question topics', () {
      expect(curriculumPrompt, contains('"exam": { "minutes": 20, "passPercent": 70, "retakeDays": 7'));
      expect(curriculumPrompt, contains('"count" 1–100'));
      expect(curriculumPrompt, contains('up to 100 for a topic with an "exam"'));
      expect(curriculumPrompt, contains('"topic": "Topic title"'));
      expect(curriculumPrompt, contains('"retakeDays" 0–60'));
    });
  });

  group('exam rules on a quiz item', () {
    StudyItem item(String content) => StudyItem(
      id: 'i',
      hlc: 'h',
      deleted: false,
      topicId: 't',
      type: 'quiz',
      title: 'Quiz: Mock exam',
      url: '',
      source: '',
      licence: '',
      minutes: 0,
      required: false,
      ord: 0,
      ref: 'quiz',
      content: content,
      done: null,
      stoppedAt: '',
      takeaway: '',
      evidence: '',
      retired: '',
    );

    test('a practice quiz has no rules; an exam has its own pass mark', () {
      final plain = item(quizContent([q1, q2]));
      expect(examRules(plain), isNull);
      expect(quizPassPercent(plain), passPercent);
      final exam = item(quizContent([q1, q2], exam: {'minutes': 5, 'passPercent': 85}));
      expect(examRules(exam), const ExamRules(minutes: 5, passPercent: 85));
      expect(quizPassPercent(exam), 85);
      expect(quizPending([exam], 80), isTrue, reason: '80% is under this exam\'s 85%');
      expect(quizPending([exam], 85), isFalse);
      expect(examTitle(exam), 'Exam: Mock exam');
    });

    test('a plan sent again keeps the plan\'s exam rules, or drops them when it drops them', () {
      final known = quizContent([q1], exam: {'minutes': 5});
      final withExam = mergeQuizContent(quizContent([q1, q2], exam: {'minutes': 9}), known);
      expect(quizExamJson(withExam), {'minutes': 9});
      expect(quizExamJson(mergeQuizContent(quizContent([q1, q2]), known)), isNull);
    });
  });

  group('marking an exam', () {
    const rules = ExamRules(minutes: 10, passPercent: 60);

    test('score, pass or fail, attempted and time', () {
      final r = scoreExam(
        shown: [q1, q2, q3, q4],
        right: [true, false, true, false],
        attempted: [true, true, true, false],
        seconds: 245,
        rules: rules,
        topicTitle: 'Mock exam',
      );
      expect((r.right, r.total, r.percent, r.passed, r.attempted), (2, 4, 50, false, 3));
      expect((r.seconds, r.limitSeconds, r.timedOut), (245, 600, false));
      expect(r.asked, [
        for (final q in [q1, q2, q3, q4]) questionId(q),
      ]);
    });

    test('per-topic breakdown; a question without a topic counts under the quiz\'s own', () {
      final r = scoreExam(
        shown: [q2, q1, q3, q4],
        right: [false, true, false, true],
        attempted: [true, true, true, true],
        seconds: 9999,
        rules: rules,
        topicTitle: 'Mock exam',
        timedOut: true,
      );
      expect(
        [for (final t in r.topics) (t.topic, t.right, t.total)],
        [('Trimming', 0, 2), ('Centering', 1, 1), ('Mock exam', 1, 1)],
      );
      expect(r.seconds, 600, reason: 'never more than the time allowed');
      expect(r.studyFirst, ['Trimming']);
    });

    test('study these first: weakest percent first, then most missed', () {
      const a = QuizQuestion(question: 'a', answer: 'x', topic: 'A');
      const b = QuizQuestion(question: 'b', answer: 'x', topic: 'B');
      const c = QuizQuestion(question: 'c', answer: 'x', topic: 'C');
      final r = scoreExam(
        // A: 1 of 2; B: 0 of 1; C: 0 of 2.
        shown: [a, a, b, c, c],
        right: [true, false, false, false, false],
        attempted: List.filled(5, true),
        seconds: 1,
        rules: rules,
        topicTitle: 'T',
      );
      expect(r.studyFirst, ['C', 'B', 'A']);
    });

    test('the detail round-trips and counts as a quiz result, not a drill', () {
      final r = scoreExam(
        shown: [q1, q2],
        right: [true, true],
        attempted: [true, true],
        seconds: 30,
        rules: rules,
        topicTitle: 'T',
        timedOut: true,
      );
      final a = row(today, detail: r.encode(), score: 2);
      final back = ExamResult.of(a)!;
      expect((back.right, back.total, back.percent, back.passed), (2, 2, 100, true));
      expect((back.seconds, back.limitSeconds, back.passPercent, back.timedOut), (30, 600, 60, true));
      expect(back.asked, r.asked);
      expect([for (final t in back.topics) t.topic], ['Centering', 'Trimming']);
      expect(isQuizResult(a), isTrue);
      expect(lastQuizPercents([a])['t'], 100);
      expect(latestQuizzes([a])['t']?.percent, 100);
      final drill = row(today, detail: '{"kind":"drill","checks":[2,2,2,2]}');
      expect(isQuizResult(drill), isFalse);
      expect(ExamResult.of(drill), isNull);
      expect(ExamResult.of(row(today)), isNull, reason: 'a practice quiz is not an exam attempt');
    });

    test('shuffle changes the order only when asked', () {
      expect(examOrder(5, shuffle: false), [0, 1, 2, 3, 4]);
      final shuffled = examOrder(20, shuffle: true, random: Random(1));
      expect(shuffled.toSet(), Set.of(List.generate(20, (i) => i)));
      expect(shuffled, isNot(List.generate(20, (i) => i)));
    });
  });

  group('retake lock', () {
    final exam = scoreExam(
      shown: [q1],
      right: [true],
      attempted: [true],
      seconds: 1,
      rules: const ExamRules(minutes: 1),
      topicTitle: 'T',
    ).encode();

    test('the next attempt counts from the last attempt plus the wait', () {
      const rules = ExamRules(minutes: 5, retakeDays: 7);
      final attempts = examAttempts([
        row('2026-11-20', detail: exam),
        row('2026-11-10', detail: exam),
        row('2026-11-25'), // a practice quiz: not an attempt
        row('2026-11-24', detail: exam, topic: 'other'),
      ], 't');
      expect([for (final a in attempts) a.day], ['2026-11-10', '2026-11-20']);
      final next = examNextDay(attempts, rules);
      expect(next, '2026-11-27');
      expect(examLocked(next, '2026-11-26'), isTrue);
      expect(examLocked(next, '2026-11-27'), isFalse);
    });

    test('no wait, or no attempt yet, never locks', () {
      expect(examNextDay([row(today, detail: exam)], const ExamRules(minutes: 5)), isNull);
      expect(examNextDay(const [], const ExamRules(minutes: 5, retakeDays: 3)), isNull);
      expect(examLocked(null, today), isFalse);
    });
  });

  group('seen before and drawing questions', () {
    List<QuizQuestion> pool(int n) => [
      for (var i = 0; i < n; i++) QuizQuestion(question: 'Q$i?', answer: 'a'),
    ];
    ExamResult attempt(List<QuizQuestion> asked) => scoreExam(
      shown: asked,
      right: List.filled(asked.length, true),
      attempted: List.filled(asked.length, true),
      seconds: 1,
      rules: const ExamRules(minutes: 1),
      topicTitle: 'T',
    );

    test('without count every question is asked and nothing is said', () {
      expect(
        seenBefore(pool: 4, rules: const ExamRules(minutes: 1), asking: const ['a'], earlier: const []),
        isNull,
      );
      expect(pickExamQuestions(pool(4), const ExamRules(minutes: 1)), [0, 1, 2, 3]);
    });

    test('a pool under twice the count is small; the share seen before is counted', () {
      const rules = ExamRules(minutes: 5, count: 4);
      expect(seenBefore(pool: 8, rules: rules, asking: const [], earlier: const [])!.smallPool, isFalse);
      final s = seenBefore(pool: 7, rules: rules, asking: const [], earlier: const []);
      expect(s!.smallPool, isTrue);
      expect(smallPoolText(s), contains('small question pool'));
      final earlier = attempt([q1, q2]);
      final r = seenBefore(
        pool: 30,
        rules: rules,
        asking: [questionId(q1), questionId(q3), questionId(q2), questionId(q4)],
        earlier: [earlier],
      )!;
      expect(r, (smallPool: false, repeats: 2, asked: 4));
      expect(seenBeforeText(r), startsWith('2 of 4 questions (50%) were asked in an earlier attempt'));
      expect(smallPoolText(r), isNull);
      expect(seenBeforeText((smallPool: false, repeats: 0, asked: 4)), contains('new'));
    });

    test('count draws unasked questions first, then those asked longest ago', () {
      final p = pool(6);
      const rules = ExamRules(minutes: 5, count: 2);
      final first = attempt([p[0], p[1]]), second = attempt([p[2], p[3]]);
      for (var seed = 0; seed < 20; seed++) {
        expect(pickExamQuestions(p, rules, earlier: [first, second], random: Random(seed)), [4, 5]);
      }
      final third = attempt([p[4], p[5]]);
      expect(pickExamQuestions(p, rules, earlier: [first, second, third]), [
        0,
        1,
      ], reason: 'oldest come back');
      final mixed = pickExamQuestions(
        p,
        const ExamRules(minutes: 5, count: 3),
        earlier: [first, second, third],
      );
      expect(mixed.take(3).toSet().containsAll([0, 1]), isTrue);
      expect(mixed.length, 3);
      // Shuffle reorders what was drawn; a count over the pool asks all.
      final shuffled = pickExamQuestions(
        p,
        const ExamRules(minutes: 5, count: 6, shuffle: true),
        random: Random(3),
      );
      expect(shuffled.toSet(), {0, 1, 2, 3, 4, 5});
      expect(pickExamQuestions(p, const ExamRules(minutes: 5, count: 50)), [0, 1, 2, 3, 4, 5]);
    });
  });

  group('an unfinished attempt', () {
    test('round-trips, and maps back to the pool without deleted questions', () {
      final p = ExamProgress(
        start: DateTime.utc(2026, 11, 27, 9),
        asked: [questionId(q2), questionId(q1), 'gone'],
        given: const ['b', '', 'x'],
        index: 1,
      );
      final back = ExamProgress.parse(p.encode())!;
      expect((back.start.toUtc(), back.index, back.handedIn), (DateTime.utc(2026, 11, 27, 9), 1, null));
      expect(back.asked, p.asked);
      expect(back.given, p.given);
      final m = back.against([q1, q2, q3])!;
      expect(m.order, [1, 0]);
      expect(m.given, ['b', '']);
      expect(back.against([q3]), isNull);
      final marking = ExamProgress.parse(
        ExamProgress(
          start: DateTime.utc(2026),
          asked: const ['a'],
          given: const ['x'],
          handedIn: 40,
          timedOut: true,
        ).encode(),
      )!;
      expect((marking.handedIn, marking.timedOut), (40, true));
      expect(ExamProgress.parse(''), isNull);
      expect(ExamProgress.parse('{"start": 3}'), isNull);
      expect(examProgressKey('i1'), 'exam.progress.i1');
    });
  });

  group('timer announcements', () {
    test('every five minutes, then at one minute, 30 and 10 seconds', () {
      expect(
        [
          for (var s = 1200; s > 0; s--)
            if (isAnnounceMark(s)) s,
        ],
        [1200, 900, 600, 300, 60, 30, 10],
      );
    });

    test('a skipped second still announces the mark it passed, never the start', () {
      expect(crossedAnnounceMark(602, 601, total: 900), isNull);
      expect(crossedAnnounceMark(601, 600, total: 900), 600);
      expect(crossedAnnounceMark(62, 58, total: 900), 60);
      expect(crossedAnnounceMark(301, 9, total: 900), 10, reason: 'the lowest mark when several pass');
      expect(crossedAnnounceMark(601, 599, total: 600), isNull);
    });

    test('words and clock text', () {
      expect(timeLeftText(300), '5 minutes left');
      expect(timeLeftText(60), '1 minute left');
      expect(timeLeftText(30), '30 seconds left');
      expect(timeLeftText(1), '1 second left');
      expect(timeLeftText(90), '1 min 30 s left');
      expect(clockText(65), '01:05');
      expect(clockText(3725), '1:02:05');
      expect(clockText(-4), '00:00');
    });
  });

  group('recording', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    Future<StudyItem> quiz() async =>
        (await (book.db.select(book.db.learnItems)..where((i) => i.type.equals('quiz'))).get()).single;

    test('an attempt is saved with its detail, missed questions become cards once', () async {
      await book.importCurriculum(
        parseCurriculum(jsonEncode(examPlan(exam: {'minutes': 5, 'retakeDays': 7}))),
        today: today,
      );
      final q = await quiz();
      final shown = quizQuestions(q).reversed.toList();
      final right = [true, false, true, false];
      final result = scoreExam(
        shown: shown,
        right: right,
        attempted: [true, true, true, false],
        seconds: 120,
        rules: examRules(q)!,
        topicTitle: 'Mock exam',
      );
      var r = await book.recordExam(q, shown, right, result, today: today);
      expect((r.score, r.max, r.cards), (2, 4, 2));
      final tests = await book.db.select(book.db.learnAssessments).get();
      expect(tests.single.title, 'Exam: Mock exam');
      expect(ExamResult.of(tests.single)!.attempted, 3);
      final cards = await book.db.select(book.db.learnCards).get();
      expect(cards.map((c) => c.front).toSet(), {shown[1].question, shown[3].question});
      expect((await quiz()).done, today);

      r = await book.recordExam(q, shown, right, result, today: '2026-12-04');
      expect(r.cards, 0, reason: 'a retake adds no second card');
      expect(
        examNextDay(
          examAttempts(await book.db.select(book.db.learnAssessments).get(), q.topicId),
          examRules(q)!,
        ),
        '2026-12-11',
      );
    });

    test('practice on an exam is not counted: cards only, no result, not done', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(examPlan(exam: {'minutes': 5}))), today: today);
      final q = await quiz();
      final r = await book.recordQuiz(q, [false, true, true, true], today: today, counted: false);
      expect((r.score, r.max, r.cards), (3, 4, 1));
      expect(await book.db.select(book.db.learnAssessments).get(), isEmpty);
      expect((await quiz()).done, isNull);
    });

    test('editing the questions keeps the exam rules', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(examPlan(exam: {'minutes': 12}))), today: today);
      final q = await quiz();
      await book.saveQuizQuestions(q.topicId, [
        ...quizQuestions(q),
        const QuizQuestion(question: 'Mine?', answer: 'y', own: true),
      ]);
      final after = await quiz();
      expect(examRules(after), const ExamRules(minutes: 12));
      expect(after.minutes, 12);
      expect(quizLength(after), 5);
    });
  });
}
