import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show Value, BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/review.dart';
import 'package:vidya/domain/udyoga_link.dart';

import 'support.dart';

const today = '2026-11-16';

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  // As a plan arrives from Udyoga through sync (Udyoga's fixture).
  Future<void> receive(String updated, {String id = 'udyoga.study-plan', String? plan}) => db
      .into(db.bridgeStudyPlans)
      .insertOnConflictUpdate(
        BridgeStudyPlansCompanion.insert(
          id: id,
          source: 'udyoga',
          plan: plan ?? File('test/fixtures/udyoga-plan.json').readAsStringSync(),
          updated: updated,
        ),
      );

  Future<StudyProgressRow?> progress() =>
      (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals('udyoga.study-plan'))).getSingleOrNull();

  test('a plan from Udyoga is offered until added, and again when it changes', () async {
    expect(await book.offeredPlans(), isEmpty);
    await book.reportToUdyoga(now: '$today T1');
    expect(await progress(), isNull, reason: 'nothing is reported before a plan arrives');

    await receive('2026-11-16T09:00:00Z');
    final offers = await book.offeredPlans();
    expect(offers.single.plan.title, startsWith('Interview ready'));
    await book.reportToUdyoga(now: '$today T2');
    expect(await progress(), isNull, reason: 'nor before it is added');

    final r = await book.addOfferedPlan(offers.single, today: today, now: '$today T3');
    expect(r.courses, offers.single.plan.courses.length);
    expect(await book.offeredPlans(), isEmpty);
    expect((await progress())!.planUpdated, '2026-11-16T09:00:00Z');

    // Re-sent: offered again; adding updates the same program.
    await receive('2026-11-17T09:00:00Z');
    final again = await book.offeredPlans();
    expect(again, hasLength(1));
    final before = (await (db.select(db.learnPrograms)).get()).length;
    await book.addOfferedPlan(again.single, today: today, now: '$today T4');
    expect((await (db.select(db.learnPrograms)).get()).length, before);
    expect((await progress())!.planUpdated, '2026-11-17T09:00:00Z');
  });

  test('progress goes back only when it changes, and the fixture Udyoga reads is current', () async {
    await receive('2026-11-16T09:00:00Z');
    await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'T1');
    final first = await progress();

    await book.reportToUdyoga(now: 'T2');
    expect((await progress())!.hlc, first!.hlc, reason: 'no change, no write');

    final id = await book.addCourse(
      'Care Certificate',
      today: today,
      kind: 'certification',
      provider: 'Skills for Health',
    );
    final course = await (db.select(db.learnCourses)..where((c) => c.id.equals(id))).getSingle();
    await book.setCourseStatus(course, 'done', today: '2026-11-03');
    await book.addSkill('SystmOne', today: today, category: 'Digital', level: 3);
    await book.addSkill('Excel', today: today, category: 'Digital', level: 2);
    await book.reportToUdyoga(now: 'T3');
    final row = (await progress())!;
    expect(row.hlc, isNot(first.hlc));
    expect(row.planUpdated, '2026-11-16T09:00:00Z', reason: 'progress keeps the added plan version');
    final p = StudyProgress.parse(row.progress);
    expect(p.learning.map((l) => (l.title, l.kind, l.finished)), [('Care Certificate', 'certification', '2026-11-03')]);
    expect(p.skills.map((k) => (k.name, k.level)), containsAll([('SystmOne', 3), ('Excel', 2)]));

    // Udyoga's tests read this file, so a change in the format shows there.
    final fixture = File('test/fixtures/vidya-progress.json');
    final text = row.progress;
    if (!fixture.existsSync() || Platform.environment['UPDATE_FIXTURES'] == '1') {
      await fixture.writeAsString('$text\n');
    }
    expect(await fixture.readAsString(), '$text\n');
  });

  group('cards with a stable id', () {
    // Udyoga's interview drills (its test/fixtures/udyoga-drills.json).
    final drills = File('test/fixtures/udyoga-drills.json').readAsStringSync();
    const planId = 'udyoga.interview-drills';
    const storyId = 'udyoga.drill.story.fixture-story';

    Future<Flashcard> card(String ref) => (db.select(db.learnCards)..where((c) => c.ref.equals(ref))).getSingle();

    test('a re-sent plan updates a changed card in place, with no duplicate and its reviews kept', () async {
      await receive('T1', id: planId, plan: drills);
      final first = await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N1');
      final count = (await db.select(db.learnCards).get()).length;
      expect(first.cards, count);
      expect(count, greaterThan(5));
      final story = await card(storyId);
      expect(story.front, 'Your story in three bullets: Clinic diary clash');
      await book.reviewCard(story, Grade.good, today: today);
      final reviewed = await card(storyId);

      // The story is edited in Udyoga: the same id with new text.
      final edited = drills
          .replaceAll('Your story in three bullets: Clinic diary clash', 'Your story in three bullets: Monday clinic')
          .replaceAll('Double bookings fell from nine a week to one.', 'Double bookings fell to one a week.');
      await receive('T2', id: planId, plan: edited);
      final second = await book.addOfferedPlan((await book.offeredPlans()).single, today: '2026-11-17', now: 'N2');
      expect((second.cards, second.updatedCards), (0, 1));
      expect((await db.select(db.learnCards).get()).length, count, reason: 'no duplicate');
      final after = await card(storyId);
      expect(after.id, story.id);
      expect(after.front, 'Your story in three bullets: Monday clinic');
      expect(after.back, contains('Double bookings fell to one a week.'));
      // The schedule and the review history are kept.
      expect((after.due, after.reps, after.interval), (reviewed.due, reviewed.reps, reviewed.interval));
      expect((await (db.select(db.learnReviews)..where((r) => r.cardId.equals(story.id))).get()).length, 1);

      // Sent a third time unchanged: nothing to update.
      await receive('T3', id: planId, plan: edited);
      final third = await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N3');
      expect((third.cards, third.updatedCards), (0, 0));
    });

    test('a card deleted here stays deleted when the plan comes again', () async {
      await receive('T1', id: planId, plan: drills);
      await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N1');
      final story = await card(storyId);
      await book.remove(db.learnCards, story.id);
      await receive('T2', id: planId, plan: drills.replaceAll('Clinic diary clash', 'Monday clinic'));
      final r = await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N2');
      expect((r.cards, r.updatedCards), (0, 0));
      expect((await card(storyId)).deleted, isTrue);
    });

    test('a card from before ids, matched by deck and front, takes the id instead of a twin', () async {
      // An earlier Udyoga sent the story card with no id.
      final plan = File('test/fixtures/udyoga-plan.json').readAsStringSync();
      await receive('T1', plan: plan.replaceAll('"id": "udyoga.story.fixture-story",', ''));
      await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N1');
      final old = (await db.select(db.learnCards).get()).single;
      expect(old.ref, '');
      await receive('T2', plan: plan);
      await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N2');
      final now = (await db.select(db.learnCards).get()).single;
      expect((now.id, now.ref), (old.id, 'udyoga.story.fixture-story'));
    });

    test('what was rehearsed goes back to Udyoga, and the fixture Udyoga reads is current', () async {
      await receive('T1', id: planId, plan: drills);
      await book.addOfferedPlan((await book.offeredPlans()).single, today: today, now: 'N1');
      Future<StudyProgressRow> sent() =>
          (db.select(db.bridgeStudyProgress)..where((p) => p.id.equals(planId))).getSingle();
      expect(jsonDecode((await sent()).progress), isNot(contains('drills')), reason: 'nothing rehearsed yet');

      await book.reviewCard(await card(storyId), Grade.good, today: '2026-11-19');
      await book.reviewCard(await card('udyoga.drill.settler'), Grade.hard, today: '2026-11-18');
      await book.reviewCard(await card('udyoga.drill.settler'), Grade.easy, today: '2026-11-19');
      // A card of the user's own is not reported.
      await book.saveCard('Mine', 'Private', today: today);
      final mine = (await (db.select(db.learnCards)..where((c) => c.front.equals('Mine'))).getSingle());
      await book.reviewCard(mine, Grade.good, today: '2026-11-19');
      // A checklist item ticked off.
      final routine = await (db.select(
        db.learnCourses,
      )..where((c) => c.title.equals('Pre-interview routine'))).getSingle();
      final topic = await (db.select(
        db.learnTopics,
      )..where((t) => t.courseId.equals(routine.id) & t.title.equals('The day before'))).getSingle();
      await book.save(db.learnTopics, topic.copyWith(done: const Value('2026-11-19')), topic.id);
      await book.reportToUdyoga(now: 'N2');

      final row = await sent();
      final drillsBack = (jsonDecode(row.progress) as Map)['drills'] as List;
      expect(drillsBack, [
        {'course': 'Pre-interview routine', 'title': 'The day before', 'done': '2026-11-19'},
        {
          'id': 'udyoga.drill.settler',
          'title': 'Could you start by telling us a little about your current role?',
          'done': '2026-11-19',
          'rating': 'easy',
          'times': 2,
        },
        {
          'id': storyId,
          'title': 'Your story in three bullets: Clinic diary clash',
          'done': '2026-11-19',
          'rating': 'good',
          'times': 1,
        },
      ]);
      expect(row.progress, isNot(contains('Private')));
      // The rest of the report reads as before.
      expect(StudyProgress.parse(row.progress).learning, isEmpty);

      // Udyoga's tests read this file (its test/fixtures/vidya-drills-progress.json).
      final fixture = File('test/fixtures/vidya-drills-progress.json');
      if (!fixture.existsSync() || Platform.environment['UPDATE_FIXTURES'] == '1') {
        await fixture.writeAsString('${row.progress}\n');
      }
      expect(await fixture.readAsString(), '${row.progress}\n');
    });
  });

  test('a plan that cannot be read is left out, not fatal', () async {
    await db
        .into(db.bridgeStudyPlans)
        .insert(BridgeStudyPlansCompanion.insert(id: 'x', source: 'udyoga', plan: 'not json', updated: 'T'));
    expect(await book.offeredPlans(), isEmpty);
  });
}
