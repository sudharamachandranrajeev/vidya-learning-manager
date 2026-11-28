import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/readiness.dart' show JobReadiness;
import 'package:vidya/domain/review.dart';
import 'package:vidya/domain/time_fit.dart';

import 'support.dart';

const today = '2026-11-02'; // a Monday

void main() {
  late LearningBook book;
  setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
  tearDown(() => book.db.close());

  Future<List<StudyItem>> items() => book.db.select(book.db.learnItems).get();
  Future<List<Flashcard>> cards() => book.db.select(book.db.learnCards).get();

  Future<TimeFit> fitOf(String goalId, {int week = 0}) async {
    final s = await book.stats(today);
    final d = await book.readyByData();
    return fitFor(
      d.goals.singleWhere((g) => g.id == goalId),
      today: today,
      courses: s.courses,
      topics: s.topics,
      items: await items(),
      criteria: d.criteria,
      sessions: s.sessions,
      weekMinutes: week > 0 ? week : d.weekMinutes,
    );
  }

  group('ready-by dates', () {
    test('a plan uses the earlier of its target and interview dates; courses in a plan have none', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-12-20');
      await book.addCourse('Wick trimming', today: today, programId: p, due: '2026-11-10');
      final solo = await book.addCourse('Glass polishing exam', today: today, due: '2026-11-30');
      await book.addCourse('Undated', today: today);
      var goals = await book.readyByGoals();
      expect(
        [for (final g in goals) (g.id, g.day, g.source)],
        [(solo, '2026-11-30', ReadyBySource.due), (p, '2026-12-20', ReadyBySource.target)],
      );
      await book.setInterviewDate(p, '2026-12-01');
      goals = await book.readyByGoals();
      expect(goals.last.day, '2026-12-01');
      expect(goals.last.source, ReadyBySource.interview);
    });

    test('paused plans and done or dropped courses drop out', () async {
      final p = await book.addProgram('Paused', '', today: today, target: '2026-12-20');
      final prog = (await book.db.select(book.db.learnPrograms).get()).single;
      await book.save(book.db.learnPrograms, prog.copyWith(status: 'paused'), p);
      final c = await book.addCourse('Dropped', today: today, due: '2026-11-30');
      final course = (await book.db.select(book.db.learnCourses).get()).single;
      await book.save(book.db.learnCourses, course.copyWith(status: 'dropped'), c);
      expect(await book.readyByGoals(), isEmpty);
    });
  });

  group('fit', () {
    test('fits at the default 3.5 hours a week when there is enough time', () async {
      final c = await book.addCourse('Glass polishing exam', today: today, due: '2026-11-30'); // 28 days
      final t = await book.addTopic(c, 'Cloths');
      await book.addItem(t, 'video', 'Which cloth', minutes: 120);
      final f = await fitOf(c);
      expect(f.weekIsDefault, isTrue);
      expect(f.weekMinutes, defaultWeekMinutes);
      expect((f.needed, f.available, f.daysLeft), (120, 840, 28));
      expect(f.fits, isTrue);
      expect(f.headline, 'Fits');
      expect(f.suggestions, isEmpty);
      expect(f.detail, contains('the default: no weekly target is set'));
    });

    test('items with no estimate count the default; a topic with no items counts its own minutes', () async {
      final c = await book.addCourse('Glass polishing exam', today: today, due: '2026-11-30');
      final a = await book.addTopic(c, 'Cloths', minutes: 45);
      final b = await book.addTopic(c, 'Polish');
      await book.addItem(b, 'article', 'No estimate');
      await book.addItem(b, 'article', 'Estimated', minutes: 20);
      final done = await book.addItem(b, 'article', 'Done already', minutes: 500);
      final row = (await items()).singleWhere((i) => i.id == done);
      await book.save(book.db.learnItems, row.copyWith(done: const Value(today)), done);
      final f = await fitOf(c);
      expect(f.needs.map((n) => (n.topic.id, n.required + n.optional)), [
        (a, 45),
        (b, defaultItemMinutes + 20),
      ]);
      expect(f.guessed, isTrue);
      expect(f.detail, contains('count $defaultItemMinutes min each'));
    });

    test('short: says how many hours, then skims and drops lowest weight first', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-11-16'); // 14 days
      final c = await book.addCourse('Lanterns', today: today, programId: p);
      final essential = await book.addTopic(c, 'Safety');
      final desirable = await book.addTopic(c, 'History');
      final plain = await book.addTopic(c, 'Trivia');
      await book.saveOwnCriterion(p, body: 'Keeps the flame safe', essential: true, topicIds: [essential]);
      await book.saveOwnCriterion(p, body: 'Knows the history', essential: false, topicIds: [desirable]);
      for (final t in [essential, desirable, plain]) {
        await book.addItem(t, 'video', 'Core', minutes: 120, required: true);
        await book.addItem(t, 'article', 'Extra', minutes: 60);
      }
      await book.setWeekTarget(120); // 240 min in 14 days; 540 needed
      final f = await fitOf(p);
      expect((f.needed, f.available, f.short), (540, 240, 300));
      expect(f.headline, '5 hours short');
      expect(f.needs.map((n) => n.weight), [3, 2, 1]);
      // Skim all three (180 freed), then drop Trivia (its 120 required min).
      expect(
        [for (final s in f.suggestions) (s.need.topic.title, s.action, s.saves)],
        [('History', FitAction.skim, 60), ('Safety', FitAction.skim, 60), ('Trivia', FitAction.drop, 180)],
      );
      expect(f.saved, 300);
      expect(f.shortAfter, 0);
      expect(suggestionText(f.suggestions.last), 'Drop Trivia (saves 3 hours)');
    });

    test('an essential topic is never dropped, so it can stay short', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-11-09'); // 7 days
      final c = await book.addCourse('Lanterns', today: today, programId: p);
      final t = await book.addTopic(c, 'Safety');
      await book.saveOwnCriterion(p, body: 'Keeps the flame safe', essential: true, topicIds: [t]);
      await book.addItem(t, 'video', 'Core', minutes: 600, required: true);
      final f = await fitOf(p);
      expect(f.suggestions, isEmpty);
      expect(f.shortAfter, f.short);
    });

    test('a course with no topics counts its hours less time logged; no hours means not counted', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-11-30');
      final c = await book.addCourse('Big course', today: today, programId: p, hours: 4);
      await book.addCourse('Mystery', today: today, programId: p);
      await book.logSession(60, today: today, courseId: c);
      final f = await fitOf(p);
      expect(f.needed, 180);
      expect(f.unestimated, 1);
      expect(f.detail, contains('1 course has no time estimate'));
    });

    test('hoursText rounds up to the half hour', () {
      expect(hoursText(40), '40 min');
      expect(hoursText(60), '1 hour');
      expect(hoursText(61), '1.5 hours');
      expect(hoursText(300), '5 hours');
    });
  });

  group('reviews kept before the day', () {
    test('capDue pulls a late day into the last week before it, never today', () {
      const day = '2026-11-30';
      expect(capDue('2026-12-15', today: today, readyBy: null), '2026-12-15');
      expect(capDue('2026-11-20', today: today, readyBy: day), '2026-11-20');
      for (var slot = 0; slot < 20; slot++) {
        final d = capDue('2026-12-15', today: today, readyBy: day, slot: slot);
        expect(d.compareTo('2026-11-23') >= 0 && d.compareTo(day) < 0, isTrue, reason: d);
      }
      expect(capDue(day, today: today, readyBy: day), '2026-11-29');
      // Two days away: only tomorrow is free.
      expect(capDue('2026-11-20', today: today, readyBy: '2026-11-04', slot: 5), '2026-11-03');
      // Tomorrow or past: nothing to move to.
      expect(capDue('2026-11-20', today: today, readyBy: '2026-11-03'), '2026-11-20');
      expect(capDue('2026-11-20', today: today, readyBy: '2026-10-30'), '2026-11-20');
    });

    test('capSchedule changes only the due day and the interval it implies', () {
      const s = (interval: 40, ease: 2.6, reps: 5, lapses: 1, due: '2026-12-12');
      final c = capSchedule(s, today: today, readyBy: '2026-11-10');
      expect(c.due, '2026-11-09');
      expect((c.interval, c.ease, c.reps, c.lapses), (7, 2.6, 5, 1));
      expect(capSchedule(s, today: today), s);
    });

    test('a review graded with a ready-by day lands before it', () async {
      final c = await book.addCourse('Glass polishing exam', today: today, due: '2026-11-12');
      await book.saveCard('Q', 'A', today: today, courseId: c);
      var card = (await cards()).single;
      card = card.copyWith(interval: 30, reps: 4);
      await book.save(book.db.learnCards, card, card.id);
      final d = await book.readyByData();
      final limit = cardLimits([card], goals: d.goals, courses: (await book.stats(today)).courses)[card.id];
      expect(limit, '2026-11-12');
      await book.reviewCard(card, Grade.good, today: today, readyBy: limit);
      card = (await cards()).single;
      expect(card.due.compareTo('2026-11-12') < 0 && card.due.compareTo(today) > 0, isTrue, reason: card.due);
      expect(card.interval, daysBetween(today, card.due));
    });

    test('cards already due after the day are pulled in once; a rerun moves nothing', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today);
      final c = await book.addCourse('Lanterns', today: today, programId: p);
      await book.saveCard('Late', 'A', today: today, courseId: c);
      await book.saveCard('Early', 'B', today: today, courseId: c);
      await book.saveCard('Unlinked', 'C', today: today);
      for (final k in await cards()) {
        await book.save(
          book.db.learnCards,
          k.copyWith(due: k.front == 'Early' ? '2026-11-05' : '2027-01-10'),
          k.id,
        );
      }
      expect(await book.pullReviewsBefore(today), 0, reason: 'no date yet');
      await book.setProgramTarget(p, '2026-11-20');
      expect(await book.pullReviewsBefore(today), 1);
      final by = {for (final k in await cards()) k.front: k.due};
      expect(by['Late']!.compareTo('2026-11-20') < 0, isTrue);
      expect(by['Early'], '2026-11-05');
      expect(by['Unlinked'], '2027-01-10');
      expect(await book.pullReviewsBefore(today), 0);
    });

    test('a plan card with no course follows its plan by title', () async {
      final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-11-20');
      await book.saveCard('Q', 'A', today: today);
      final k = (await cards()).single;
      await book.save(book.db.learnCards, k.copyWith(plan: 'lantern keeper', due: '2027-01-01'), k.id);
      expect(await book.pullReviewsBefore(today), 1);
      expect(p, isNotEmpty);
    });
  });

  group('outcome', () {
    test('a passed day asks for the outcome until one is logged; it earns nothing', () async {
      final c = await book.addCourse('Glass polishing exam', today: today, due: '2026-10-30');
      var d = await book.readyByData();
      expect(awaitingOutcome(d.goals, d.outcomes, today).map((g) => g.id), [c]);
      expect(awaitingOutcome(d.goals, d.outcomes, '2026-10-30'), isEmpty, reason: 'not on the day itself');
      await book.logOutcome(d.goals.single, OutcomeResult.passed, today: today, percent: 82, note: 'Fine');
      d = await book.readyByData();
      expect(awaitingOutcome(d.goals, d.outcomes, today), isEmpty);
      final o = d.outcomes.single;
      expect(
        (o.goalId, o.target, o.result, o.percent, o.note),
        (c, '2026-10-30', OutcomeResult.passed, 82, 'Fine'),
      );
      final s = await book.stats(today);
      expect(s.assessments, isEmpty, reason: 'an outcome is not a test');
      expect((await book.history(today)).tests, isEmpty);
      final row = (await book.db.select(book.db.learnAssessments).get()).single;
      expect(isOutcomeRecord(row), isTrue);
      expect(row.itemId, outcomeItemId(c));
    });

    test('moving the date asks again for the new day', () async {
      final c = await book.addCourse('Glass polishing exam', today: today, due: '2026-10-30');
      var d = await book.readyByData();
      await book.logOutcome(d.goals.single, OutcomeResult.didNotHappen, today: today);
      await book.setCourseDue(c, '2026-11-01');
      d = await book.readyByData();
      expect(awaitingOutcome(d.goals, d.outcomes, today).single.day, '2026-11-01');
    });

    test('an outcome detail is not read as a drill, rating, exam or quiz result', () {
      const o = ReadyByOutcome(goalId: 'g', target: '2026-11-01', result: OutcomeResult.notPassed);
      final back = ReadyByOutcome.parse(o.encode())!;
      expect(
        (back.goalId, back.target, back.result, back.percent),
        ('g', '2026-11-01', OutcomeResult.notPassed, null),
      );
      expect(ReadyByOutcome.parse(''), isNull);
      expect(ReadyByOutcome.parse('{"kind":"exam"}'), isNull);
      expect(ReadyByOutcome.parse('not json'), isNull);
    });
  });

  test('readiness reads stay unchanged by an outcome row', () async {
    final p = await book.addProgram('Lantern keeper', '', today: today, target: '2026-10-30');
    final d = await book.readyByData();
    await book.logOutcome(d.goals.single, OutcomeResult.notPassed, today: today);
    final r = await book.readiness(p, today: today);
    expect(r.rows, isEmpty);
  });
}
