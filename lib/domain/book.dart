import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'achievements.dart';
import 'curriculum.dart';
import 'exam.dart';
import 'export.dart';
import 'framework.dart';
import 'import.dart';
import 'journey_book.dart';
import 'quiz.dart';
import 'review.dart';
import 'stats.dart';
import 'study_items.dart';
import 'templates.dart';
import 'time_fit.dart' show isOutcomeRecord;

const courseKinds = {
  'course': 'Course',
  'book': 'Book',
  'certification': 'Certification',
  'degree': 'Degree',
  'project': 'Project',
  'practice': 'Practice',
};

const portfolioKinds = {
  'project': 'Project',
  'certificate': 'Certificate',
  'publication': 'Publication',
  'talk': 'Talk',
  'contribution': 'Contribution',
  'degree': 'Degree',
};

const skillLevels = ['None', 'Aware', 'Learning', 'Competent', 'Proficient', 'Expert'];

/// What importing a study plan added (things already there are not counted).
/// [updatedCards] counts plan cards changed in place, [retiredCards] the
/// plan's cards it no longer sends (kept, not shown). [items] counts study
/// items added to topics, [criteria] the goal's criteria added, and
/// [retiredItems] the plan items it no longer sends (kept, not counted).
typedef CurriculumImport = ({
  String programId,
  int courses,
  int topics,
  int skills,
  int cards,
  int updatedCards,
  int retiredCards,
  int notes,
  int items,
  int criteria,
  int retiredItems,
});

/// Vidya's write path and the reads screens share.
class LearningBook {
  LearningBook(this.store);
  final Store store;

  AppDatabase get db => store.db as AppDatabase;

  Future<void> save<T extends Table, D>(TableInfo<T, D> table, Insertable<D> row, String id) =>
      store.save(table, row, id);

  Future<void> remove(TableInfo table, String id) => store.remove(table, id);

  // ---- curriculum ----

  Future<String> addProgram(String title, String goal, {required String today, String? target}) async {
    final id = newId();
    await save(
      db.learnPrograms,
      LearnProgramsCompanion.insert(
        id: id,
        title: title,
        goal: Value(goal),
        started: today,
        target: Value(target),
      ),
      id,
    );
    return id;
  }

  Future<String> addCourse(
    String title, {
    required String today,
    String? programId,
    String kind = 'course',
    String provider = '',
    String url = '',
    int hours = 0,
    String? due,
  }) async {
    final id = newId();
    await save(
      db.learnCourses,
      LearnCoursesCompanion.insert(
        id: id,
        programId: Value(programId),
        title: title,
        provider: Value(provider),
        url: Value(url),
        kind: Value(kind),
        hours: Value(hours),
        due: Value(due),
        added: today,
      ),
      id,
    );
    return id;
  }

  Future<String> addTopic(String courseId, String title, {int minutes = 30}) async {
    final last =
        await (db.select(db.learnTopics)
              ..where((t) => t.courseId.equals(courseId) & t.deleted.not())
              ..orderBy([(t) => OrderingTerm.desc(t.ord)])
              ..limit(1))
            .getSingleOrNull();
    final id = newId();
    await save(
      db.learnTopics,
      LearnTopicsCompanion.insert(
        id: id,
        courseId: courseId,
        title: title,
        minutes: Value(minutes),
        ord: Value((last?.ord ?? -1) + 1),
      ),
      id,
    );
    return id;
  }

  /// Marks a topic done today (or open again) and moves its course on: a
  /// planned course starts, and one whose topics are all done finishes.
  /// [note] is why it was ticked before its required items were done.
  Future<void> setTopicDone(Topic t, bool done, {required String today, String? note}) => db.transaction(
    () async {
      final fresh = await (db.select(db.learnTopics)..where((x) => x.id.equals(t.id))).getSingleOrNull() ?? t;
      await save(
        db.learnTopics,
        fresh.copyWith(done: Value(done ? today : null), tickNote: done ? (note ?? '') : ''),
        t.id,
      );
      final course = await (db.select(
        db.learnCourses,
      )..where((c) => c.id.equals(t.courseId))).getSingleOrNull();
      if (course == null || course.deleted) return;
      final topics = await (db.select(
        db.learnTopics,
      )..where((x) => x.courseId.equals(t.courseId) & x.deleted.not())).get();
      final all = topics.every((x) => x.id == t.id ? done : x.done != null);
      if (done && all) {
        await setCourseStatus(course, 'done', today: today);
      } else if (done && course.status == 'planned') {
        await setCourseStatus(course, 'doing', today: today);
      } else if (!done && course.status == 'done') {
        await setCourseStatus(course, 'doing', today: today);
      }
    },
  );

  Future<void> setCourseStatus(Course c, String status, {required String today}) async {
    await save(
      db.learnCourses,
      c.copyWith(status: status, finished: Value(status == 'done' ? today : null)),
      c.id,
    );
    final pid = c.programId;
    if (pid == null) return;
    final program = await (db.select(db.learnPrograms)..where((p) => p.id.equals(pid))).getSingleOrNull();
    if (program == null || program.deleted) return;
    final courses = await (db.select(
      db.learnCourses,
    )..where((x) => x.programId.equals(pid) & x.deleted.not() & x.status.equals('dropped').not())).get();
    final finished =
        courses.isNotEmpty && courses.every((x) => x.id == c.id ? status == 'done' : x.status == 'done');
    if (finished && program.status != 'done') {
      await save(db.learnPrograms, program.copyWith(status: 'done'), pid);
    } else if (!finished && program.status == 'done') {
      await save(db.learnPrograms, program.copyWith(status: 'active'), pid);
    }
  }

  /// Deletes a program with its courses, their topics and sessions' links.
  Future<void> removeProgram(String id) => db.transaction(() async {
    final courses = await (db.select(db.learnCourses)..where((c) => c.programId.equals(id))).get();
    for (final c in courses) {
      await removeCourse(c.id);
    }
    await removeJourney(id);
    await remove(db.learnPrograms, id);
  });

  Future<void> removeCourse(String id) => db.transaction(() async {
    final topics = await (db.select(db.learnTopics)..where((t) => t.courseId.equals(id))).get();
    for (final t in topics) {
      if (!t.deleted) await removeTopic(t.id);
    }
    await remove(db.learnCourses, id);
  });

  /// Deletes a topic and its study items. Its note stays in Notes.
  Future<void> removeTopic(String id) => db.transaction(() async {
    for (final i in await (db.select(
      db.learnItems,
    )..where((i) => i.topicId.equals(id) & i.deleted.not())).get()) {
      await remove(db.learnItems, i.id);
    }
    await remove(db.learnTopics, id);
  });

  // ---- topic pages ----

  /// Sets what the learner says about an open topic: '' (worked out from
  /// its items), `studying` or `review`.
  Future<void> setTopicStatus(Topic t, String status) async {
    final fresh = await (db.select(db.learnTopics)..where((x) => x.id.equals(t.id))).getSingle();
    await save(db.learnTopics, fresh.copyWith(status: status), t.id);
  }

  /// Adds the learner's own item at the end of a topic's list (typed in,
  /// pasted as a link, or picked from a free resource search).
  Future<String> addItem(
    String topicId,
    String type,
    String title, {
    String url = '',
    String source = '',
    int minutes = 0,
    bool required = false,
    String stoppedAt = '',
    String takeaway = '',
    String evidence = '',
    String licence = '',
    String content = '',
  }) async {
    final last =
        await (db.select(db.learnItems)
              ..where((i) => i.topicId.equals(topicId) & i.deleted.not())
              ..orderBy([(i) => OrderingTerm.desc(i.ord)])
              ..limit(1))
            .getSingleOrNull();
    final id = newId();
    await save(
      db.learnItems,
      LearnItemsCompanion.insert(
        id: id,
        topicId: topicId,
        type: Value(type),
        title: title,
        url: Value(url),
        source: Value(source),
        minutes: Value(minutes),
        required: Value(required),
        ord: Value((last?.ord ?? -1) + 1),
        stoppedAt: Value(stoppedAt),
        takeaway: Value(takeaway),
        evidence: Value(evidence),
        licence: Value(licence),
        content: Value(content),
      ),
      id,
    );
    return id;
  }

  Future<void> saveItem(StudyItem i) => save(db.learnItems, i, i.id);

  /// Marks an item done today, or open again.
  Future<void> setItemDone(StudyItem i, bool done, {required String today}) =>
      save(db.learnItems, i.copyWith(done: Value(done ? today : null)), i.id);

  /// Moves an item [by] places up (negative) or down its topic's list.
  Future<void> moveItem(StudyItem item, int by) => db.transaction(() async {
    final list =
        await (db.select(db.learnItems)
              ..where((i) => i.topicId.equals(item.topicId) & i.deleted.not())
              ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
            .get();
    final from = list.indexWhere((i) => i.id == item.id);
    if (from < 0) return;
    final to = (from + by).clamp(0, list.length - 1);
    if (to == from) return;
    list.insert(to, list.removeAt(from));
    for (final (k, i) in list.indexed) {
      if (i.ord != k) await save(db.learnItems, i.copyWith(ord: k), i.id);
    }
  });

  /// Writes a topic's own note, making it the first time. Saving drops the
  /// "from plan" tag, so the note counts as the learner's from then on.
  Future<void> saveTopicNote(Topic t, String courseTitle, String body, {required String today}) =>
      db.transaction(() async {
        final id = t.noteId.isNotEmpty ? t.noteId : topicNoteId(t.id);
        final old = await (db.select(db.learnNotes)..where((n) => n.id.equals(id))).getSingleOrNull();
        final tags = old == null
            ? 'topic note'
            : old.tags
                  .split(',')
                  .map((x) => x.trim())
                  .where((x) => x.isNotEmpty && x != planNoteTag)
                  .join(', ');
        await save(
          db.learnNotes,
          LearnNotesCompanion.insert(
            id: id,
            title: old?.title ?? '$courseTitle — ${t.title}',
            body: Value(body),
            tags: Value(tags),
            created: old?.created ?? today,
            updated: today,
            deleted: const Value(false),
          ),
          id,
        );
        final fresh = await (db.select(db.learnTopics)..where((x) => x.id.equals(t.id))).getSingle();
        if (fresh.noteId != id) await save(db.learnTopics, fresh.copyWith(noteId: id), t.id);
      });

  /// A plan's items for one topic, each updated in place by its stable id
  /// (plan fields only; done, stopped at, takeaway and evidence are the
  /// learner's and stay). One the learner deleted stays deleted. New ones
  /// go at the end. A quiz keeps the learner's own and AI questions beside
  /// the plan's (see [mergeQuizContent]). With [unretire], an item sent
  /// again after being retired is back in use. Returns how many were added.
  Future<int> _savePlanItems(String topicId, List<PlanItem> items, {bool unretire = false}) async {
    if (items.isEmpty) return 0;
    final have = {
      for (final i in await (db.select(db.learnItems)..where((i) => i.topicId.equals(topicId))).get())
        i.id: i,
    };
    var ord = have.values.where((i) => !i.deleted).fold(-1, (a, i) => i.ord > a ? i.ord : a) + 1;
    var added = 0;
    for (final p in items) {
      final id = planItemId(topicId, p.ref);
      final known = have[id];
      if (known != null) {
        if (known.deleted) continue;
        final next = known.copyWith(
          type: p.type,
          title: p.title,
          url: p.url,
          source: p.source,
          licence: p.licence,
          minutes: p.minutes,
          required: p.required,
          ref: p.ref,
          content: p.type == 'quiz' && known.type == 'quiz'
              ? mergeQuizContent(p.content, known.content)
              : p.content,
          retired: unretire ? '' : known.retired,
        );
        if (next != known) await save(db.learnItems, next, id);
        continue;
      }
      final row = LearnItemsCompanion.insert(
        id: id,
        topicId: topicId,
        type: Value(p.type),
        title: p.title,
        url: Value(p.url),
        source: Value(p.source),
        licence: Value(p.licence),
        minutes: Value(p.minutes),
        required: Value(p.required),
        ord: Value(ord++),
        ref: Value(p.ref),
        content: Value(p.content),
      );
      await save(db.learnItems, row, id);
      have[id] = await (db.select(db.learnItems)..where((i) => i.id.equals(id))).getSingle();
      added++;
    }
    return added;
  }

  /// Plan resource lines as link items (see [resourceItem]), with the same
  /// ids a plan item with that link would have.
  static List<PlanItem> _resourceItems(List<String> resources) => [
    for (final r in resources)
      if (resourceItem(r) case final x when x.title.isNotEmpty)
        PlanItem(
          type: x.type,
          title: x.title,
          url: x.url,
          ref: itemRef(type: x.type, title: x.title, url: x.url),
        ),
  ];

  /// Gives a topic its own note made from the plan or study guide, unless
  /// it has one, or had one the learner deleted. The note is tagged
  /// [planNoteTag] so it earns nothing until the learner writes in it.
  /// Returns whether a note was made.
  Future<bool> _ensureTopicNote(Topic t, String courseTitle, String body, String tag, String today) async {
    if (t.noteId.isNotEmpty || body.trim().isEmpty) return false;
    final id = topicNoteId(t.id);
    final old = await (db.select(db.learnNotes)..where((n) => n.id.equals(id))).getSingleOrNull();
    if (old == null) {
      await save(
        db.learnNotes,
        LearnNotesCompanion.insert(
          id: id,
          title: '$courseTitle — ${t.title}',
          body: Value(body.trim()),
          tags: Value([tag, 'topic note', planNoteTag].where((x) => x.isNotEmpty).join(', ')),
          created: today,
          updated: today,
        ),
        id,
      );
    }
    if (old?.deleted ?? false) return false;
    final fresh = await (db.select(db.learnTopics)..where((x) => x.id.equals(t.id))).getSingle();
    await save(db.learnTopics, fresh.copyWith(noteId: id), t.id);
    return old == null;
  }

  /// Splits each course's study-guide note (`<course> — study guide`, made
  /// by plans before topic pages) by its `## n. Title` headings: each
  /// topic gets its section as its own note, and the section's `- ` lines
  /// as link items. The guide itself is left as it is. Safe to run again,
  /// and on every device: the new rows have ids made from the topic's, so
  /// a second run or another device writes the same rows. Returns how many
  /// topics gained a note or items.
  Future<int> splitStudyGuides({required String today}) => db.transaction(() async {
    const suffix = ' — study guide';
    final guides = (await (db.select(
      db.learnNotes,
    )..where((n) => n.deleted.not())).get()).where((n) => n.title.endsWith(suffix)).toList();
    if (guides.isEmpty) return 0;
    final courses = await (db.select(db.learnCourses)..where((c) => c.deleted.not())).get();
    final programs = {for (final p in await db.select(db.learnPrograms).get()) p.id: p};
    var touched = 0;
    for (final g in guides) {
      final name = g.title.substring(0, g.title.length - suffix.length).toLowerCase();
      final tag = g.tags.split(',').first.trim();
      final matches = courses.where((c) => c.title.toLowerCase() == name).toList();
      if (matches.isEmpty) continue;
      // The guide's first tag is its plan's title, which picks the course
      // when two programs have one of the same name.
      final course =
          matches
              .where(
                (c) => programs[c.programId]?.title.replaceAll(',', ' ').toLowerCase() == tag.toLowerCase(),
              )
              .firstOrNull ??
          matches.first;
      final topics = await (db.select(
        db.learnTopics,
      )..where((t) => t.courseId.equals(course.id) & t.deleted.not())).get();
      for (final sec in guideSections(g.body)) {
        final t = topics.where((x) => x.title.toLowerCase() == sec.title.toLowerCase()).firstOrNull;
        if (t == null) continue;
        final made = await _ensureTopicNote(t, course.title, sec.text, tag, today);
        final added = await _savePlanItems(t.id, _resourceItems(sec.resources));
        if (made || added > 0) touched++;
      }
    }
    return touched;
  });

  /// Copies a starter curriculum: the program, its courses and topics, and
  /// the skills it builds (skills you already track are left alone).
  Future<String> importTemplate(ProgramTemplate t, {required String today}) => db.transaction(() async {
    final pid = await addProgram(t.title, t.goal, today: today);
    for (final c in t.courses) {
      final cid = await addCourse(c.title, today: today, programId: pid, kind: c.kind, hours: c.hours);
      for (final topic in c.topics) {
        await addTopic(cid, topic, minutes: (c.hours * 60 / c.topics.length).round().clamp(15, 240));
      }
    }
    final have = (await (db.select(
      db.learnSkills,
    )..where((s) => s.deleted.not())).get()).map((s) => s.name.toLowerCase()).toSet();
    for (final s in t.skills) {
      if (have.add(s.toLowerCase())) await addSkill(s, today: today);
    }
    return pid;
  });

  // ---- quizzes and practice tasks ----

  /// Saves a topic's quiz questions (and the plan questions the learner
  /// deleted), making the topic's quiz item the first time. Returns the
  /// quiz item's id.
  Future<String> saveQuizQuestions(
    String topicId,
    List<QuizQuestion> questions, {
    List<String> dropped = const [],
  }) => db.transaction(() async {
    final items =
        await (db.select(db.learnItems)..where(
              (i) =>
                  i.topicId.equals(topicId) & i.deleted.not() & i.type.equals('quiz') & i.retired.equals(''),
            ))
            .get();
    final quiz = items.firstOrNull;
    // The plan's exam rules stay when the learner edits the questions.
    final exam = quiz == null ? null : quizExamJson(quiz.content);
    final content = quizContent(questions, dropped: dropped, exam: exam);
    final minutes = exam == null
        ? (questions.length * 1.5).ceil()
        : ExamRules.fromJson(exam, questions: questions.length).minutes;
    if (quiz != null) {
      await save(db.learnItems, quiz.copyWith(content: content, minutes: minutes), quiz.id);
      return quiz.id;
    }
    final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(topicId))).getSingle();
    final id = await addItem(topicId, 'quiz', 'Quiz: ${topic.title}', minutes: minutes);
    final made = await (db.select(db.learnItems)..where((i) => i.id.equals(id))).getSingle();
    await save(db.learnItems, made.copyWith(content: content), id);
    return id;
  });

  /// Records a finished quiz: the score as a test linked to the topic and
  /// its course, the quiz item done today, and each missed question as a
  /// review card in the course's deck. A card's ref comes from the quiz and
  /// the question ([quizCardRef]), so a retake adds no second card, a card
  /// the learner deleted is not made again, and a later right answer leaves
  /// the card where it is. [right] holds, per question in order, whether it
  /// was answered right. Returns the score and how many cards were added.
  ///
  /// With [counted] false (practising a quiz that is an exam, outside an
  /// exam attempt) only the review cards are made: no result is saved and
  /// the item is not marked done.
  Future<({int score, int max, int cards})> recordQuiz(
    StudyItem quiz,
    List<bool> right, {
    required String today,
    bool counted = true,
  }) => _recordQuiz(quiz, quizQuestions(quiz), right, today: today, counted: counted);

  /// Records a finished exam attempt as [recordQuiz] does a quiz, with
  /// [result] as the result's detail. [shown] are the questions in the
  /// order asked and [right] whether each was marked right; missed ones
  /// become review cards.
  Future<({int score, int max, int cards})> recordExam(
    StudyItem quiz,
    List<QuizQuestion> shown,
    List<bool> right,
    ExamResult result, {
    required String today,
  }) => _recordQuiz(quiz, shown, right, today: today, detail: result.encode(), title: examTitle(quiz));

  Future<({int score, int max, int cards})> _recordQuiz(
    StudyItem quiz,
    List<QuizQuestion> questions,
    List<bool> right, {
    required String today,
    bool counted = true,
    String detail = '',
    String? title,
  }) => db.transaction(() async {
    final n = right.length < questions.length ? right.length : questions.length;
    final score = right.take(n).where((x) => x).length;
    final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(quiz.topicId))).getSingle();
    final course = await (db.select(
      db.learnCourses,
    )..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
    if (counted) {
      await addAssessment(
        title ?? quiz.title,
        score.toDouble(),
        n.toDouble(),
        today: today,
        courseId: course?.id,
        topicId: topic.id,
        detail: detail,
      );
      final fresh = await (db.select(db.learnItems)..where((i) => i.id.equals(quiz.id))).getSingle();
      if (fresh.done != today) await save(db.learnItems, fresh.copyWith(done: Value(today)), quiz.id);
    }
    final known = {
      for (final c in await (db.select(db.learnCards)..where((c) => c.ref.like('quiz.${quiz.id}.%'))).get())
        c.ref,
    };
    var cards = 0;
    for (var k = 0; k < n; k++) {
      if (right[k]) continue;
      final q = questions[k];
      final ref = quizCardRef(quiz.id, q);
      if (!known.add(ref)) continue;
      final id = newId();
      await save(
        db.learnCards,
        LearnCardsCompanion.insert(
          id: id,
          front: q.question,
          back: q.explain.isEmpty ? q.answer : '${q.answer}\n\n${q.explain}',
          deck: Value(course?.title ?? 'Quiz'),
          courseId: Value(course?.id),
          due: today,
          created: today,
          ref: Value(ref),
        ),
        id,
      );
      cards++;
    }
    return (score: score, max: n, cards: cards);
  });

  /// Marks a practice task done with its [evidence] link, or a short
  /// [note] on what was done when there is nothing to link to. Returns why
  /// it cannot be done yet, or null when saved.
  Future<String?> completeTask(
    StudyItem task, {
    String evidence = '',
    String note = '',
    required String today,
  }) async {
    if (!taskCanBeDone(evidence, note)) return 'Add an evidence link, or a short note on what you did.';
    await save(
      db.learnItems,
      task.copyWith(done: Value(today), evidence: evidence.trim(), takeaway: note.trim()),
      task.id,
    );
    return null;
  }

  /// Turns a practice task into a portfolio project in one tap: its title,
  /// evidence link, "done when" line and note, and the skills it shows (the
  /// job criteria its topic works towards, else the course). Tapping again
  /// finds the same item ([taskPortfolioId]) and brings it back if it was
  /// deleted. Returns the portfolio item's id.
  Future<String> taskToPortfolio(StudyItem task, {required String today}) => db.transaction(() async {
    final id = taskPortfolioId(task.id);
    final topic = await (db.select(
      db.learnTopics,
    )..where((t) => t.id.equals(task.topicId))).getSingleOrNull();
    final course = topic == null
        ? null
        : await (db.select(db.learnCourses)..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
    final refs = topic == null ? const <String>[] : criteriaRefs(topic);
    final pid = course?.programId;
    final criteria = refs.isEmpty || pid == null
        ? const <Criterion>[]
        : await (db.select(db.learnCriteria)
                ..where((c) => c.programId.equals(pid) & c.ref.isIn(refs) & c.deleted.not())
                ..orderBy([(c) => OrderingTerm.asc(c.ord)]))
              .get();
    final skills = criteria.isNotEmpty
        ? criteria.map((c) => c.body.replaceAll(',', ' ').trim()).join(', ')
        : (course?.title.replaceAll(',', ' ') ?? '');
    final doneWhen = itemContent(task)['doneWhen'];
    final summary = [
      if (doneWhen is String && doneWhen.isNotEmpty) 'Done when: $doneWhen',
      if (task.takeaway.isNotEmpty) task.takeaway,
    ].join('\n');
    final old = await (db.select(db.learnPortfolio)..where((p) => p.id.equals(id))).getSingleOrNull();
    await save(
      db.learnPortfolio,
      LearnPortfolioCompanion.insert(
        id: id,
        title: task.title,
        kind: const Value('project'),
        url: Value(task.evidence),
        day: old?.day ?? task.done ?? today,
        skills: Value(skills),
        summary: Value(summary),
        deleted: const Value(false),
      ),
      id,
    );
    return id;
  });

  // ---- weekly time target ----

  /// The synced pref holding the weekly study target in minutes.
  static const weekTargetKey = 'vidya.weekTarget';

  /// Minutes a week the learner aims for; 0 when no target is set.
  Future<int> weekTarget() async {
    final row = await (db.select(db.prefs)..where((p) => p.id.equals(weekTargetKey))).getSingleOrNull();
    return row == null || row.deleted ? 0 : int.tryParse(row.value) ?? 0;
  }

  Future<void> setWeekTarget(int minutes) => save(
    db.prefs,
    PrefsCompanion.insert(
      id: weekTargetKey,
      value: '${minutes.clamp(0, 10080)}',
      deleted: const Value(false),
    ),
    weekTargetKey,
  );

  // ---- the learner's own history ----

  /// Everything the history export holds (see `historyMarkdown`).
  Future<History> history(String today) async => (
    today: today,
    programs: await (db.select(db.learnPrograms)..where((r) => r.deleted.not())).get(),
    courses: await (db.select(db.learnCourses)..where((r) => r.deleted.not())).get(),
    topics: await (db.select(db.learnTopics)..where((r) => r.deleted.not())).get(),
    items: await (db.select(db.learnItems)..where((r) => r.deleted.not())).get(),
    tests: [
      for (final a in await (db.select(db.learnAssessments)..where((r) => r.deleted.not())).get())
        if (!isFrameworkRating(a) && !isOutcomeRecord(a)) a,
    ],
    sessions: await (db.select(db.learnSessions)..where((r) => r.deleted.not())).get(),
    notes: await (db.select(db.learnNotes)..where((r) => r.deleted.not())).get(),
  );

  // ---- practice ----

  /// Logs study time. With [topicId] (time logged on a topic page) the
  /// course is the topic's when not given.
  Future<void> logSession(
    int minutes, {
    required String today,
    String? courseId,
    String? topicId,
    String note = '',
    String? day,
  }) async {
    if (topicId != null && courseId == null) {
      courseId = (await (db.select(
        db.learnTopics,
      )..where((t) => t.id.equals(topicId))).getSingleOrNull())?.courseId;
    }
    final id = newId();
    return save(
      db.learnSessions,
      LearnSessionsCompanion.insert(
        id: id,
        courseId: Value(courseId),
        topicId: Value(topicId),
        day: day ?? today,
        minutes: minutes,
        note: Value(note),
      ),
      id,
    );
  }

  Future<void> addAssessment(
    String title,
    double score,
    double max, {
    required String today,
    String? courseId,
    String? topicId,
    String detail = '',
  }) {
    final id = newId();
    return save(
      db.learnAssessments,
      LearnAssessmentsCompanion.insert(
        id: id,
        courseId: Value(courseId),
        topicId: Value(topicId),
        title: title,
        day: today,
        score: score,
        max: Value(max),
        detail: Value(detail),
      ),
      id,
    );
  }

  // ---- skills, portfolio, notes ----

  Future<void> addSkill(
    String name, {
    required String today,
    String category = 'General',
    int level = 0,
    int target = 3,
  }) {
    final id = newId();
    return save(
      db.learnSkills,
      LearnSkillsCompanion.insert(
        id: id,
        name: name,
        category: Value(category),
        level: Value(level),
        target: Value(target),
        updated: today,
      ),
      id,
    );
  }

  Future<void> setSkillLevel(Skill s, int level, {required String today}) =>
      save(db.learnSkills, s.copyWith(level: level, updated: today), s.id);

  Future<void> addPortfolio(
    String title, {
    required String today,
    String kind = 'project',
    String url = '',
    String skills = '',
    String summary = '',
  }) {
    final id = newId();
    return save(
      db.learnPortfolio,
      LearnPortfolioCompanion.insert(
        id: id,
        title: title,
        kind: Value(kind),
        url: Value(url),
        day: today,
        skills: Value(skills),
        summary: Value(summary),
      ),
      id,
    );
  }

  Future<void> saveNote(String title, String body, String tags, {required String today, Note? existing}) {
    final id = existing?.id ?? newId();
    return save(
      db.learnNotes,
      LearnNotesCompanion.insert(
        id: id,
        title: title,
        body: Value(body),
        tags: Value(tags),
        created: existing?.created ?? today,
        updated: today,
      ),
      id,
    );
  }

  // ---- flashcards ----

  /// Adds a card, or changes the text of [existing] without touching its
  /// schedule. A new card is due today.
  Future<void> saveCard(
    String front,
    String back, {
    required String today,
    String deck = 'General',
    String? courseId,
    String image = '',
    String audio = '',
    Flashcard? existing,
  }) {
    final id = existing?.id ?? newId();
    if (existing != null) {
      return save(
        db.learnCards,
        existing.copyWith(
          front: front,
          back: back,
          deck: deck,
          courseId: Value(courseId),
          image: image,
          audio: audio,
        ),
        id,
      );
    }
    return save(
      db.learnCards,
      LearnCardsCompanion.insert(
        id: id,
        front: front,
        back: back,
        deck: Value(deck),
        courseId: Value(courseId),
        image: Value(image),
        audio: Value(audio),
        due: today,
        created: today,
      ),
      id,
    );
  }

  /// Adds imported cards as new cards due today, leaving out any whose deck
  /// and front already exist (so importing a file twice changes nothing).
  /// Returns how many were added.
  Future<int> importCards(List<ImportedCard> cards, {required String today}) =>
      db.transaction(() => _addNewCards([for (final c in cards) (card: c, courseId: null)], today));

  Future<int> _addNewCards(List<({ImportedCard card, String? courseId})> cards, String today) async {
    final seen = {
      for (final c in await (db.select(db.learnCards)..where((r) => r.deleted.not())).get())
        '${c.deck}\u0000${c.front}',
    };
    var added = 0;
    for (final (:card, :courseId) in cards) {
      if (!seen.add('${card.deck}\u0000${card.front}')) continue;
      await saveCard(
        card.front,
        card.back,
        today: today,
        deck: card.deck,
        courseId: courseId,
        image: card.image,
        audio: card.audio,
      );
      added++;
    }
    return added;
  }

  /// A plan's cards. One with an id updates the card with that ref in
  /// place (front, back, deck, course), keeping its schedule and reviews; a
  /// deleted one stays deleted. A card from before refs, matched by deck
  /// and front, takes the ref. Anything else is added, and cards with no id
  /// merge by deck and front as before.
  Future<({int added, int updated, int retired})> _savePlanCards(
    CurriculumPlan plan,
    Map<String, String> courseIds,
    String today,
  ) async {
    final cards = plan.cards;
    final planKey = plan.title.toLowerCase();
    final all = await db.select(db.learnCards).get();
    final byRef = {
      for (final c in all)
        if (c.ref.isNotEmpty) c.ref: c,
    };
    final byFront = {
      for (final c in all)
        if (!c.deleted && c.ref.isEmpty) '${c.deck}\u0000${c.front}': c,
    };
    var added = 0, updated = 0;
    final plain = <({ImportedCard card, String? courseId})>[];
    for (final c in cards) {
      final courseId = courseIds[c.course.toLowerCase()];
      if (c.id.isEmpty) {
        plain.add((
          card: (front: c.front, back: c.back, deck: c.deck, image: '', audio: ''),
          courseId: courseId,
        ));
        continue;
      }
      final known = byRef[c.id] ?? byFront.remove('${c.deck}\u0000${c.front}');
      if (known != null) {
        if (known.deleted) continue;
        final next = known.copyWith(
          front: c.front,
          back: c.back,
          deck: c.deck,
          courseId: Value(courseId ?? known.courseId),
          ref: c.id,
          plan: planKey,
          // Sent again after being retired: back in use, schedule kept.
          retired: '',
        );
        if (next != known) {
          await save(db.learnCards, next, known.id);
          updated++;
        }
        byRef[c.id] = next;
        continue;
      }
      final id = newId();
      await save(
        db.learnCards,
        LearnCardsCompanion.insert(
          id: id,
          front: c.front,
          back: c.back,
          deck: Value(c.deck),
          courseId: Value(courseId),
          due: today,
          created: today,
          ref: Value(c.id),
          plan: Value(planKey),
        ),
        id,
      );
      byRef[c.id] = (await (db.select(db.learnCards)..where((r) => r.id.equals(id))).getSingle());
      added++;
    }
    // A card this plan sent before and no longer sends (the story was
    // deleted in the sending app) is retired: kept with its reviews, no
    // longer shown. Only for a whole plan: one part of a long plan holds
    // only some of its cards.
    var retired = 0;
    if (_wholePlan(plan.part)) {
      final sent = {for (final c in cards) c.id};
      for (final c in all) {
        if (c.deleted || c.ref.isEmpty || c.plan != planKey || c.retired.isNotEmpty) continue;
        if (sent.contains(c.ref)) continue;
        await save(db.learnCards, c.copyWith(retired: today), c.id);
        retired++;
      }
    }
    return (added: added + await _addNewCards(plain, today), updated: updated, retired: retired);
  }

  static bool _wholePlan(String part) {
    final p = part.trim();
    return p.isEmpty || RegExp(r'^1\s*of\s*1$').hasMatch(p);
  }

  /// Adds a study plan (see curriculum.dart). Everything merges by title, so
  /// importing a plan twice, or its parts one after another, adds each thing
  /// once: the program, its courses, their topics, skills, notes, and cards
  /// (by deck and front). Course due dates count the plan's weeks from [today].
  /// Topic details and resources go into one study-guide note per course,
  /// and each topic also gets them as its own note and link items. Format 2
  /// items, quiz and drills become study items, updated in place by their
  /// stable ids when the plan comes again; criteria are kept per program.
  Future<CurriculumImport> importCurriculum(CurriculumPlan plan, {required String today}) => db.transaction(
    () async {
      final key = plan.title.toLowerCase();
      final program = (await (db.select(
        db.learnPrograms,
      )..where((p) => p.deleted.not())).get()).where((p) => p.title.toLowerCase() == key).firstOrNull;
      final String pid;
      if (program == null) {
        pid = await addProgram(plan.title, plan.goal, today: today, target: plan.targetDate);
        if (plan.role.isNotEmpty) {
          final made = await (db.select(db.learnPrograms)..where((p) => p.id.equals(pid))).getSingle();
          await save(db.learnPrograms, made.copyWith(role: plan.role), pid);
        }
      } else {
        pid = program.id;
        final goal = program.goal.isEmpty ? plan.goal : program.goal;
        final target = program.target ?? plan.targetDate;
        final role = plan.role.isNotEmpty ? plan.role : program.role;
        if (goal != program.goal || target != program.target || role != program.role) {
          await save(db.learnPrograms, program.copyWith(goal: goal, target: Value(target), role: role), pid);
        }
      }
      final criteria = await _savePlanCriteria(pid, plan.criteria);
      if (plan.journey case final j?) await saveJourney(pid, j, now: today);
      if (plan.framework case final f?) await saveFramework(pid, f);
      if (plan.stories.isNotEmpty || plan.cards.isNotEmpty) {
        await saveTaggedStories(pid, plan.stories, whole: _wholePlan(plan.part));
      }

      final noteTitles = {
        for (final n in await (db.select(db.learnNotes)..where((n) => n.deleted.not())).get())
          n.title.toLowerCase(),
      };
      var notes = 0;
      final tag = plan.title.replaceAll(',', ' ');
      Future<void> note(String title, String body, String tags) async {
        if (!noteTitles.add(title.toLowerCase())) return;
        await saveNote(title, body, tags, today: today);
        notes++;
      }

      final courseIds = {
        for (final c in await (db.select(
          db.learnCourses,
        )..where((c) => c.programId.equals(pid) & c.deleted.not())).get())
          c.title.toLowerCase(): c.id,
      };
      var courses = 0, topics = 0, items = 0, retiredItems = 0;
      for (final c in plan.courses) {
        final due = c.dueWeek == null ? null : addDays(today, c.dueWeek! * 7);
        var cid = courseIds[c.title.toLowerCase()];
        if (cid == null) {
          cid = await addCourse(
            c.title,
            today: today,
            programId: pid,
            kind: c.kind,
            provider: c.provider,
            url: c.url,
            hours: c.hours,
            due: due,
          );
          courseIds[c.title.toLowerCase()] = cid;
          courses++;
        }
        final courseId = cid;
        final have = {
          for (final t in await (db.select(
            db.learnTopics,
          )..where((t) => t.courseId.equals(courseId) & t.deleted.not())).get())
            t.title.toLowerCase(): t.id,
        };
        for (final t in c.topics) {
          var tid = have[t.title.toLowerCase()];
          if (tid == null) {
            tid = await addTopic(courseId, t.title, minutes: t.minutes);
            have[t.title.toLowerCase()] = tid;
            topics++;
          }
          // The plan owns a topic's criteria: a re-sent plan updates them.
          // Links to the learner's own criteria (refs starting `own.`) stay.
          var topic = await (db.select(db.learnTopics)..where((x) => x.id.equals(tid!))).getSingle();
          final refs = [
            ...t.criteria,
            for (final r in criteriaRefs(topic))
              if (r.startsWith('own.') && !t.criteria.contains(r)) r,
          ].join(',');
          if (t.criteria.isNotEmpty && topic.criteria != refs) {
            topic = topic.copyWith(criteria: refs);
            await save(db.learnTopics, topic, tid);
          }
          final sent = [...t.items, ..._resourceItems(t.resources)];
          items += await _savePlanItems(tid, sent, unretire: true);
          // Every part of a plan holds whole topics, so any part can retire.
          retiredItems += await _retirePlanItems(tid, {for (final p in sent) planItemId(tid, p.ref)}, today);
          await _ensureTopicNote(topic, c.title, topicGuideMarkdown(t), tag, today);
        }
        if (c.hasGuide) {
          await note('${c.title} — study guide', courseGuideMarkdown(c, due: due), '$tag, study guide');
        }
      }

      for (final n in plan.notes) {
        final title = n.title.toLowerCase().contains(key) ? n.title : '${plan.title} — ${n.title}';
        await note(title, n.body, [tag, n.tags].where((x) => x.isNotEmpty).join(', '));
      }

      final haveSkills = (await (db.select(
        db.learnSkills,
      )..where((s) => s.deleted.not())).get()).map((s) => s.name.toLowerCase()).toSet();
      var skills = 0;
      for (final s in plan.skills) {
        if (!haveSkills.add(s.name.toLowerCase())) continue;
        await addSkill(s.name, today: today, category: s.category, target: s.target);
        skills++;
      }

      final (added: cards, updated: updatedCards, retired: retiredCards) = await _savePlanCards(
        plan,
        courseIds,
        today,
      );

      return (
        programId: pid,
        courses: courses,
        topics: topics,
        skills: skills,
        cards: cards,
        updatedCards: updatedCards,
        retiredCards: retiredCards,
        notes: notes,
        items: items,
        criteria: criteria,
        retiredItems: retiredItems,
      );
    },
  );

  /// Retires a topic's plan items the plan no longer sends (ids not in
  /// [sent]): kept, with anything the learner did on them, but no longer
  /// counted. The learner's own items (no ref) and items already done are
  /// never touched. Returns how many were retired.
  Future<int> _retirePlanItems(String topicId, Set<String> sent, String today) async {
    var n = 0;
    for (final i in await (db.select(
      db.learnItems,
    )..where((i) => i.topicId.equals(topicId) & i.deleted.not())).get()) {
      if (i.ref.isEmpty || i.retired.isNotEmpty || i.done != null || sent.contains(i.id)) continue;
      await save(db.learnItems, i.copyWith(retired: today), i.id);
      n++;
    }
    return n;
  }

  /// Puts a retired item back in use.
  Future<void> unretireItem(StudyItem i) => save(db.learnItems, i.copyWith(retired: ''), i.id);

  /// A plan's criteria for its program, each updated in place by its id
  /// (or, without one, its text). Returns how many were added.
  Future<int> _savePlanCriteria(String programId, List<PlanCriterion> criteria) async {
    if (criteria.isEmpty) return 0;
    final have = {
      for (final c in await (db.select(db.learnCriteria)..where((c) => c.programId.equals(programId))).get())
        c.ref: c,
    };
    var added = 0;
    for (final (k, c) in criteria.indexed) {
      final ref = c.id.isNotEmpty ? c.id : 'text|${c.text.toLowerCase()}';
      final known = have[ref];
      if (known != null) {
        if (known.deleted) continue;
        final next = known.copyWith(
          body: c.text,
          essential: c.essential,
          kind: c.kind,
          source: c.source,
          shown: Value(c.shown),
          ord: k,
        );
        if (next != known) await save(db.learnCriteria, next, known.id);
        continue;
      }
      final id = '$programId.c${stableHash(ref)}';
      await save(
        db.learnCriteria,
        LearnCriteriaCompanion.insert(
          id: id,
          programId: programId,
          ref: ref,
          body: c.text,
          essential: Value(c.essential),
          kind: Value(c.kind),
          source: Value(c.source),
          shown: Value(c.shown),
          ord: Value(k),
        ),
        id,
      );
      added++;
    }
    return added;
  }

  /// Records a review and moves the card to its next due day, before
  /// [readyBy] when the card has one (see `cardReadyBy`).
  Future<void> reviewCard(
    Flashcard c,
    Grade g, {
    required String today,
    ReviewPace pace = ReviewPace.standard,
    String? readyBy,
  }) => db.transaction(() async {
    final n = nextSchedule(c, g, today, pace: pace, readyBy: readyBy);
    await save(
      db.learnCards,
      c.copyWith(interval: n.interval, ease: n.ease, reps: n.reps, lapses: n.lapses, due: n.due),
      c.id,
    );
    final id = newId();
    await save(
      db.learnReviews,
      LearnReviewsCompanion.insert(id: id, cardId: c.id, day: today, grade: g.index),
      id,
    );
  });

  Future<void> removeCard(String id) => remove(db.learnCards, id);

  // ---- measures and achievements ----

  Future<Stats> stats(String today) async {
    final unlocks = await (db.select(db.learnUnlocks)..where((u) => u.deleted.not())).get();
    return Stats(
      today: today,
      programs: await (db.select(db.learnPrograms)..where((r) => r.deleted.not())).get(),
      courses: await (db.select(db.learnCourses)..where((r) => r.deleted.not())).get(),
      topics: await (db.select(db.learnTopics)..where((r) => r.deleted.not())).get(),
      sessions: await (db.select(db.learnSessions)..where((r) => r.deleted.not())).get(),
      // Self-ratings and real outcomes are not tests: they earn nothing and
      // skew no average.
      assessments: [
        for (final a in await (db.select(db.learnAssessments)..where((r) => r.deleted.not())).get())
          if (!isFrameworkRating(a) && !isOutcomeRecord(a)) a,
      ],
      skills: await (db.select(db.learnSkills)..where((r) => r.deleted.not())).get(),
      portfolio: await (db.select(db.learnPortfolio)..where((r) => r.deleted.not())).get(),
      // Topic notes made from a plan earn nothing until the learner writes.
      notes: (await (db.select(
        db.learnNotes,
      )..where((r) => r.deleted.not())).get()).where((n) => !hasPlanNoteTag(n)).toList(),
      cards: await (db.select(db.learnCards)..where((r) => r.deleted.not() & r.retired.equals(''))).get(),
      retiredCards: await (db.select(
        db.learnCards,
      )..where((r) => r.deleted.not() & r.retired.equals('').not())).get(),
      reviews: await (db.select(db.learnReviews)..where((r) => r.deleted.not())).get(),
      unlocked: unlocks.length,
    );
  }

  /// Saves the achievements reached since last time and returns them, so
  /// the app can celebrate each once.
  Future<List<Achievement>> unlockNew(String today) async {
    final s = await stats(today);
    final have = {for (final u in await (db.select(db.learnUnlocks)).get()) u.id};
    final fresh = [
      for (final a in achievements)
        if (!have.contains(a.key) && a.value(s) >= a.target) a,
    ];
    for (final a in fresh) {
      await save(
        db.learnUnlocks,
        LearnUnlocksCompanion.insert(id: a.key, day: today, deleted: const Value(false)),
        a.key,
      );
    }
    return fresh;
  }
}
