import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/export.dart';
import 'package:vidya/domain/next_up.dart';
import 'package:vidya/domain/quiz.dart';
import 'package:vidya/domain/stats.dart';
import 'package:vidya/domain/study_items.dart';

import 'support.dart';

const today = '2026-11-21'; // a Saturday

const task = <String, Object?>{
  'type': 'practice task',
  'title': 'Center 1 kg three times',
  'instructions': 'Use a timer.',
  'doneWhen': 'The clay runs true',
  'required': true,
};

/// A made-up format 2 plan: a pottery course with a quiz, a practice task
/// and criteria.
Map<String, Object?> plan({List<Map<String, Object?>>? items, List<Map<String, Object?>>? quiz}) => {
  'format': 'vidya-curriculum',
  'version': 2,
  'program': {'title': 'Pottery teacher'},
  'criteria': [
    {'id': 'c1', 'text': 'Explain centering to a beginner', 'essential': true},
    {'id': 'c2', 'text': 'Safe, clean studio', 'essential': false},
  ],
  'courses': [
    {
      'title': 'Wheel basics',
      'topics': [
        {
          'title': 'Centering',
          'details': 'Brace your arms against your knees.',
          'criteria': ['c1', 'c2'],
          'items':
              items ??
              [
                {
                  'type': 'video',
                  'title': 'Centering talk',
                  'url': 'https://example.org/v',
                  'required': true,
                },
                task,
                {'type': 'article', 'title': 'Wheel guide', 'url': 'https://example.org/wheel'},
              ],
          'quiz':
              quiz ??
              [
                {
                  'question': 'Which hand braces?',
                  'options': ['Left', 'Right'],
                  'answer': 'Left',
                  'explain': 'The left arm rests on the knee.',
                },
                {'question': 'What runs true?', 'answer': 'The clay', 'kind': 'short'},
                {'question': 'Name the wheel head', 'answer': 'Bat', 'kind': 'card'},
              ],
        },
        {'title': 'Trimming'},
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

  Future<Topic> topic(String title) =>
      (db.select(db.learnTopics)..where((t) => t.title.equals(title))).getSingle();
  Future<List<StudyItem>> itemsOf(String title) async {
    final t = await topic(title);
    return (db.select(db.learnItems)
          ..where((i) => i.topicId.equals(t.id) & i.deleted.not())
          ..orderBy([(i) => OrderingTerm.asc(i.ord)]))
        .get();
  }

  Future<StudyItem> quizOf(String title) async => (await itemsOf(title)).firstWhere((i) => i.type == 'quiz');
  Future<void> importPlan([Map<String, Object?>? p]) =>
      book.importCurriculum(parseCurriculum(jsonEncode(p ?? plan())), today: today);

  group('quiz', () {
    test('scoring saves a test on the topic; misses become cards once, however often retaken', () async {
      await importPlan();
      final quiz = await quizOf('Centering');
      expect(quizQuestions(quiz).map((q) => q.kind), ['choice', 'short', 'card']);

      var r = await book.recordQuiz(quiz, [true, false, false], today: today);
      expect((r.score, r.max, r.cards), (1, 3, 2));
      var tests = await db.select(db.learnAssessments).get();
      final t = await topic('Centering');
      expect(
        (tests.single.topicId, tests.single.courseId, tests.single.score, tests.single.max),
        (t.id, t.courseId, 1.0, 3.0),
      );
      expect(lastQuizPercents(tests)[t.id], 33);
      expect((await quizOf('Centering')).done, today, reason: 'taking the quiz marks the item done');

      final cards = await db.select(db.learnCards).get();
      expect(cards.map((c) => c.front), unorderedEquals(['What runs true?', 'Name the wheel head']));
      expect(cards.every((c) => c.deck == 'Wheel basics' && c.courseId == t.courseId), isTrue);
      expect(cards.every((c) => c.ref.startsWith('quiz.${quiz.id}.')), isTrue);

      // Retake: the same miss again and a new miss; then all right.
      r = await book.recordQuiz(quiz, [false, false, true], today: '2026-11-22');
      expect(r.cards, 1, reason: 'only the first miss of "Which hand braces?" adds a card');
      expect(await db.select(db.learnCards).get(), hasLength(3));
      final braces = (await db.select(db.learnCards).get()).firstWhere(
        (c) => c.front == 'Which hand braces?',
      );
      expect(braces.back, 'Left\n\nThe left arm rests on the knee.');
      r = await book.recordQuiz(quiz, [true, true, true], today: '2026-11-23');
      expect((r.score, r.cards), (3, 0));
      expect(await db.select(db.learnCards).get(), hasLength(3), reason: 'a right answer deletes nothing');
      tests = await db.select(db.learnAssessments).get();
      expect(lastQuizPercents(tests)[t.id], 100);

      // A card the learner deleted is not made again.
      await book.removeCard(braces.id);
      await book.recordQuiz(quiz, [false, true, true], today: '2026-11-24');
      expect((await db.select(db.learnCards).get()).where((c) => !c.deleted), hasLength(2));
    });

    test('retaking a quiz earns experience once per topic (the best score)', () async {
      await importPlan();
      final quiz = await quizOf('Centering');
      await book.recordQuiz(quiz, [true, true, true], today: today);
      final once = (await book.stats(today)).xp;
      await book.recordQuiz(quiz, [true, true, true], today: today);
      await book.recordQuiz(quiz, [false, true, true], today: today);
      final s = await book.stats(today);
      expect(s.assessments, hasLength(3));
      // Only new cards (one miss) add experience.
      expect(s.xp, once + Stats.xpNewCard);
    });

    test('answers are marked leniently; choices must match', () {
      const short = QuizQuestion(question: 'Q', answer: 'The clay');
      expect(autoCorrect(short, '  clay! '), isTrue);
      expect(autoCorrect(short, 'water'), isFalse);
      const choice = QuizQuestion(question: 'Q', answer: 'Left', kind: 'choice', options: ['Left', 'Right']);
      expect((autoCorrect(choice, 'Left'), autoCorrect(choice, 'Right')), (true, false));
      expect(
        questionProblem(const QuizQuestion(question: 'Q', answer: 'X', kind: 'choice', options: ['A', 'B'])),
        isNotNull,
      );
      expect(questionProblem(const QuizQuestion(question: '', answer: 'X')), 'Write the question.');
    });

    test(
      'questions typed by hand make a quiz; the learner\'s and AI questions survive a re-sent plan',
      () async {
        final cid = await book.addCourse('Glazes', today: today);
        final tid = await book.addTopic(cid, 'Mixing');
        final id = await book.saveQuizQuestions(tid, [
          const QuizQuestion(question: 'Wear what?', answer: 'A mask', own: true),
        ]);
        final made = (await itemsOf('Mixing')).single;
        expect((made.id, made.type, made.title, quizLength(made)), (id, 'quiz', 'Quiz: Mixing', 1));

        await importPlan();
        var quiz = await quizOf('Centering');
        final qs = quizQuestions(quiz);
        // The learner rewrites one plan question, deletes another, adds one;
        // an AI adds one.
        final edited = const QuizQuestion(
          question: 'Which arm braces?',
          answer: 'Left',
          own: true,
        ).copyWith(replaces: qs[0].question);
        await book.saveQuizQuestions(
          quiz.topicId,
          [
            edited,
            qs[2],
            const QuizQuestion(question: 'My own?', answer: 'Yes', own: true),
            const QuizQuestion(question: 'From AI?', answer: 'Yes', ai: true),
          ],
          dropped: [qs[1].key],
        );
        await importPlan();
        quiz = await quizOf('Centering');
        expect(quizQuestions(quiz).map((q) => (q.question, q.own, q.ai)), [
          ('Name the wheel head', false, false),
          ('Which arm braces?', true, false),
          ('My own?', true, false),
          ('From AI?', false, true),
        ]);
        expect(quizDropped(quiz), ['what runs true?']);
      },
    );

    test('AI replies are read into labelled questions; bad ones are left out', () {
      final qs = parseAiQuestions(
        'Here you go:\n{"quiz": [{"question": "Q1", "kind": "choice", "options": ["A", "B"], "answer": "B", '
        '"explain": "Because."}, {"question": "Q2", "answer": "x", "kind": "short"}, '
        '{"question": "Bad", "kind": "choice", "options": ["A", "B"], "answer": "C"}, {"question": "No answer"}]}',
      );
      expect(qs.map((q) => (q.question, q.kind, q.ai, q.own)), [
        ('Q1', 'choice', true, false),
        ('Q2', 'short', true, false),
      ]);
      expect(qs.first.explain, 'Because.');
      expect(() => parseAiQuestions('no json'), throwsFormatException);
      final prompt = aiQuizPrompt(topic: 'Centering', course: 'Wheel basics', existing: ['Old?']);
      expect(prompt, contains('"Centering"'));
      expect(prompt, contains('Old?'));
    });
  });

  group('earned tick', () {
    test('required items done and, with a quiz, the last score at least 70%', () async {
      await importPlan();
      var items = await itemsOf('Centering');
      expect(topicQuiz(items), isNotNull);
      for (final i in items.where((i) => i.required)) {
        await book.setItemDone(i, true, today: today);
      }
      items = await itemsOf('Centering');
      expect(topicEarned(items), isFalse, reason: 'quiz never taken');
      expect(topicEarned(items, quizPercent: 67), isFalse);
      expect(tickNeedsNote(items, quizPercent: 67), isTrue);
      expect(topicEarned(items, quizPercent: 70), isTrue);
      expect(tickNeedsNote(items, quizPercent: 70), isFalse);

      // Quiz passed but a required item open again: not earned.
      await book.setItemDone(items.first, false, today: today);
      items = await itemsOf('Centering');
      expect(topicEarned(items, quizPercent: 100), isFalse);
      // A topic with only a quiz is earned by passing it.
      expect(topicEarned([items.firstWhere((i) => i.type == 'quiz')], quizPercent: 80), isTrue);
      // Nothing to earn it by: never earned, ticking needs no note.
      expect((topicEarned(const []), tickNeedsNote(const [])), (false, false));

      // A manual tick still works with a note.
      final t = await topic('Centering');
      await book.setTopicDone(t, true, today: today, note: 'Taught it last term');
      expect((await topic('Centering')).tickNote, 'Taught it last term');
    });
  });

  group('practice tasks', () {
    test('done needs evidence or a note; one tap makes a portfolio item, once', () async {
      await importPlan();
      final task = (await itemsOf('Centering')).firstWhere((i) => i.type == 'practice task');
      expect(await book.completeTask(task, today: today), isNotNull);
      expect((await itemsOf('Centering')).firstWhere((i) => i.id == task.id).done, isNull);
      expect(taskCanBeDone('', 'Did it in class'), isTrue);

      expect(await book.completeTask(task, evidence: ' https://example.org/clip ', today: today), isNull);
      final done = (await itemsOf('Centering')).firstWhere((i) => i.id == task.id);
      expect((done.done, done.evidence), (today, 'https://example.org/clip'));

      final pid = await book.taskToPortfolio(done, today: '2026-11-25');
      expect(pid, taskPortfolioId(task.id));
      var p = (await db.select(db.learnPortfolio).get()).single;
      expect(
        (p.title, p.kind, p.url, p.day),
        ('Center 1 kg three times', 'project', 'https://example.org/clip', today),
      );
      expect(p.skills, 'Explain centering to a beginner, Safe  clean studio');
      expect(p.summary, 'Done when: The clay runs true');
      await book.taskToPortfolio(done, today: today);
      expect(await db.select(db.learnPortfolio).get(), hasLength(1));

      // Deleted, then tapped again: back.
      await book.remove(db.learnPortfolio, pid);
      await book.taskToPortfolio(done, today: today);
      p = (await db.select(db.learnPortfolio).get()).single;
      expect(p.deleted, isFalse);
    });
  });

  group('next up', () {
    test('order by program, course, topic and item; paused and dropped skipped; quiz after items', () async {
      await importPlan();
      final first = (await db.select(db.learnPrograms).get()).single;
      // An older program, paused; and a newer one, active.
      final paused = await book.addProgram('Paused plan', '', today: '2026-01-01');
      final pc = await book.addCourse('Paused course', today: today, programId: paused);
      await book.addTopic(pc, 'Never shown');
      await book.save(
        db.learnPrograms,
        (await (db.select(
          db.learnPrograms,
        )..where((p) => p.id.equals(paused))).getSingle()).copyWith(status: 'paused'),
        paused,
      );
      final later = await book.addProgram('Later plan', '', today: '2026-12-01');
      final lc = await book.addCourse('Later course', today: today, programId: later);
      await book.addTopic(lc, 'Later topic');
      final loose = await book.addCourse('Loose course', today: today);
      await book.addTopic(loose, 'Loose topic');

      Future<NextUp?> next({String? course}) async {
        final s = await book.stats(today);
        return nextUp(
          programs: s.programs,
          courses: s.courses,
          topics: s.topics,
          items: await (db.select(db.learnItems)..where((i) => i.deleted.not())).get(),
          quizPercents: lastQuizPercents(s.assessments),
          courseId: course,
        );
      }

      var n = await next();
      expect(
        (n!.program!.id, n.topic.title, n.item!.title, n.reason),
        (first.id, 'Centering', 'Centering talk', NextReason.required),
      );
      // Resume text for a video stopped part way.
      await book.saveItem(n.item!.copyWith(stoppedAt: '12:30'));
      n = await next();
      expect(resumeText(n!.item!), 'Resume at 12:30');

      for (final i in (await itemsOf('Centering')).where((i) => i.required)) {
        await book.setItemDone(i, true, today: today);
      }
      n = await next();
      expect((n!.item!.type, n.reason), ('quiz', NextReason.quiz));
      await book.recordQuiz(n.item!, [true, true, true], today: today);
      n = await next();
      expect((n!.item!.title, n.reason), ('Wheel guide', NextReason.optional));
      await book.setItemDone(n.item!, true, today: today);
      n = await next();
      expect((n!.topic.title, n.item, n.reason), ('Centering', null, NextReason.topic));
      await book.setTopicDone(n.topic, true, today: today);
      n = await next();
      expect(n!.topic.title, 'Trimming');

      // Dropping the course moves on to the newer program, then the loose course.
      final wheel = (await db.select(db.learnCourses).get()).firstWhere((c) => c.title == 'Wheel basics');
      await book.setCourseStatus(wheel, 'dropped', today: today);
      n = await next();
      expect(n!.topic.title, 'Later topic');
      expect((await next(course: loose))!.topic.title, 'Loose topic');
      expect(await next(course: pc), isNull, reason: 'paused program');
      final lt = (await db.select(db.learnTopics).get()).firstWhere((t) => t.title == 'Later topic');
      await book.setTopicDone(lt, true, today: today);
      final lo = (await db.select(db.learnTopics).get()).firstWhere((t) => t.title == 'Loose topic');
      await book.setTopicDone(lo, true, today: today);
      expect(await next(), isNull, reason: 'calm: nothing is waiting');
    });
  });

  group('time', () {
    test('the weekly target sums Monday to today; it is a synced pref', () async {
      expect(weekStart(today), '2026-11-16');
      expect(weekStart('2026-11-16'), '2026-11-16');
      await book.logSession(30, today: today, day: '2026-11-15'); // last Sunday: not this week
      await book.logSession(25, today: today, day: '2026-11-16');
      await book.logSession(40, today: today);
      final s = await book.stats(today);
      expect(minutesThisWeek(s.sessions, today), 65);
      expect(await book.weekTarget(), 0);
      await book.setWeekTarget(120);
      expect(await book.weekTarget(), 120);
      final pref = await (db.select(
        db.prefs,
      )..where((p) => p.id.equals(LearningBook.weekTargetKey))).getSingle();
      expect(pref.value, '120');
      expect(weekTargetText(65, 120), '65 of 120 min this week.');
      expect(weekTargetText(130, 120), contains('bonus'));
      expect(weekTargetText(0, 0), '');
      for (final w in ['streak', 'behind', 'missed', 'fail']) {
        expect(weekTargetText(0, 120).toLowerCase(), isNot(contains(w)));
      }
    });

    test('time logged on a topic counts for the topic and its course', () async {
      await importPlan();
      final t = await topic('Centering');
      await book.logSession(20, today: today, topicId: t.id);
      await book.logSession(15, today: today, topicId: t.id);
      await book.logSession(50, today: today, courseId: t.courseId);
      final s = await book.stats(today);
      expect(minutesByTopic(s.sessions), {t.id: 35});
      expect(s.sessions.where((x) => x.topicId == t.id).every((x) => x.courseId == t.courseId), isTrue);
      expect(s.hoursOn(t.courseId), closeTo(85 / 60, 0.001));
    });
  });

  group('history export', () {
    test('Markdown and JSON hold programs, topics, items done, takeaways, scores and own notes', () async {
      await importPlan();
      final items = await itemsOf('Centering');
      await book.saveItem(items[2].copyWith(done: const Value(today), takeaway: 'Keep the wheel fast'));
      await book.recordQuiz(await quizOf('Centering'), [true, true, false], today: today);
      await book.logSession(45, today: today, topicId: items.first.topicId);
      await book.saveNote('My glaze notes', 'Cone 6 is hot.', 'glaze', today: today);
      final h = await book.history(today);

      final md = historyMarkdown(h);
      expect(md, contains('## Pottery teacher'));
      expect(md, contains('### Wheel basics'));
      expect(md, contains('Centering (Studying'));
      expect(md, contains('last quiz 67%'));
      expect(md, contains('45 min studied'));
      expect(md, contains('[Wheel guide](https://example.org/wheel) (Article, done'));
      expect(md, contains('Takeaway: Keep the wheel fast'));
      expect(md, contains('Quiz: Centering, 2 of 3 (67%)'));
      expect(md, contains('### My glaze notes'));
      expect(md, isNot(contains('from plan')), reason: 'plan notes are the plan\'s text, left out');

      final j = jsonDecode(historyJson(h)) as Map<String, Object?>;
      expect((j['format'], j['version']), ('vidya-history', 1));
      final course = ((j['programs'] as List).single as Map)['courses'] as List;
      final centering = ((course.single as Map)['topics'] as List).first as Map;
      expect(
        (centering['title'], centering['status'], centering['lastQuizPercent']),
        ('Centering', 'studying', 67),
      );
      final done = centering['itemsDone'] as List;
      expect(done.map((x) => (x as Map)['title']), containsAll(['Wheel guide', 'Quiz: Centering']));
      expect((j['tests'] as List).single, containsPair('topic', 'Centering'));
      expect((j['notes'] as List).map((n) => (n as Map)['title']), ['My glaze notes']);
    });
  });

  group('notes', () {
    test('notes made from plans are hidden unless asked for, never lost', () async {
      await importPlan();
      await book.saveNote('My glaze notes', 'Cone 6.', 'glaze', today: today);
      final notes = await (db.select(db.learnNotes)..where((n) => n.deleted.not())).get();
      expect(notes.where(hasPlanNoteTag), isNotEmpty);
      expect(notes.where((n) => n.title.endsWith('study guide')).single.tags, contains('study guide'));
      expect(visibleNotes(notes).map((n) => n.title), ['My glaze notes']);
      expect(visibleNotes(notes, fromPlans: true), hasLength(notes.length));
      expect(visibleNotes(notes, fromPlans: true, query: 'cone'), hasLength(1));
      expect(visibleNotes(notes, tag: 'glaze').single.title, 'My glaze notes');
    });
  });

  group('retired items', () {
    test(
      'a re-sent plan retires items it no longer sends; done and own items stay; sent again, back',
      () async {
        await importPlan();
        var items = await itemsOf('Centering');
        final video = items.firstWhere((i) => i.type == 'video');
        final guide = items.firstWhere((i) => i.title == 'Wheel guide');
        await book.setItemDone(guide, true, today: today);
        final own = await book.addItem(video.topicId, 'note', 'My own item');

        // The plan now sends only the practice task.
        final fewer = plan(items: [task]);
        final r = await book.importCurriculum(parseCurriculum(jsonEncode(fewer)), today: '2026-11-22');
        expect(r.retiredItems, 1);
        items = await itemsOf('Centering');
        final v = items.firstWhere((i) => i.id == video.id);
        expect((v.retired, v.deleted), ('2026-11-22', false), reason: 'kept, not deleted');
        expect(items.firstWhere((i) => i.id == guide.id).retired, '', reason: 'done items are never retired');
        expect(items.firstWhere((i) => i.id == own).retired, '');
        expect(openRequired(items).map((i) => i.type), [
          'practice task',
        ], reason: 'retired items do not count');
        expect(activeItems(items).any((i) => i.id == video.id), isFalse);

        // Again: nothing more to retire. Then sent again: back in use.
        expect(
          (await book.importCurriculum(parseCurriculum(jsonEncode(fewer)), today: today)).retiredItems,
          0,
        );
        await importPlan();
        expect((await itemsOf('Centering')).firstWhere((i) => i.id == video.id).retired, '');
        // Splitting old study guides on start never brings a retired item back.
        await book.importCurriculum(parseCurriculum(jsonEncode(fewer)), today: today);
        await book.splitStudyGuides(today: today);
        expect((await itemsOf('Centering')).firstWhere((i) => i.id == video.id).retired, today);
        await book.unretireItem((await itemsOf('Centering')).firstWhere((i) => i.id == video.id));
        expect((await itemsOf('Centering')).firstWhere((i) => i.id == video.id).retired, '');
      },
    );
  });

  test('a version 7 database gains topic time, quiz links and retired items, and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v7.db');
    var db7 = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db7));
    await b.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
    final cid = (await db7.select(db7.learnCourses).get()).single.id;
    await b.logSession(30, today: today, courseId: cid, note: 'Wheel time');
    await b.addAssessment('Mock', 8, 10, today: today, courseId: cid);
    final before = (await db7.select(db7.learnItems).get()).map((i) => (i.id, i.title, i.content)).toList();
    // Turn it back into version 7: none of the new columns.
    await db7.customStatement('DROP INDEX IF EXISTS learn_sessions_topic');
    await db7.customStatement('DROP INDEX IF EXISTS learn_assessments_topic');
    await db7.customStatement('ALTER TABLE learn_sessions DROP COLUMN topic_id');
    await db7.customStatement('ALTER TABLE learn_assessments DROP COLUMN topic_id');
    await db7.customStatement('ALTER TABLE learn_items DROP COLUMN retired');
    await db7.customStatement('PRAGMA user_version = 7');
    await db7.close();

    db7 = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db7));
    final s = await b.stats(today);
    expect(
      (s.sessions.single.minutes, s.sessions.single.note, s.sessions.single.topicId),
      (30, 'Wheel time', null),
    );
    expect((s.assessments.single.title, s.assessments.single.topicId), ('Mock', null));
    final items = await db7.select(db7.learnItems).get();
    expect(items.map((i) => (i.id, i.title, i.content)).toList(), before);
    expect(items.every((i) => i.retired == ''), isTrue);
    // The new columns work.
    final t = s.topics.firstWhere((t) => t.title == 'Centering');
    await b.logSession(10, today: today, topicId: t.id);
    expect(minutesByTopic((await b.stats(today)).sessions), {t.id: 10});
    await db7.close();
    await dir.delete(recursive: true);
  });
}
