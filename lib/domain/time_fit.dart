/// "Ready by": whether a plan (or a course of its own) fits before its
/// interview or exam day at the hours the learner has each week, what to
/// skim or drop when it does not, and the outcome asked for once the day
/// has passed. Plain rules over rows; the writes are in [TimeFitBook].
///
/// Where the dates live (no new table or column):
/// - a plan's ready-by day is the earlier of its target date
///   (`LearnPrograms.target`) and its interview date (the synced pref
///   `vidya.interviewDate.<id>`);
/// - a course with no plan uses its own due date (`LearnCourses.due`).
///   Courses inside a plan keep their due dates as week order only.
///
/// The weekly hours are the weekly time target (the synced pref
/// `vidya.weekTarget`), or [defaultWeekMinutes] when no target is set.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'interview.dart' show InterviewTraining;
import 'review.dart';
import 'study_items.dart';

/// Minutes a week assumed when the learner has set no weekly target: 3.5
/// hours, about half an hour a day.
const defaultWeekMinutes = 210;

/// Minutes counted for an open study item that has no estimate of its
/// own (items from a plan usually have one; items added by hand often do
/// not). A topic with no items at all counts its own estimate
/// (`LearnTopics.minutes`, 30 unless changed).
const defaultItemMinutes = 15;

/// Where a ready-by day came from.
enum ReadyBySource {
  target('target date'),
  interview('interview date'),
  due('due date');

  const ReadyBySource(this.label);
  final String label;
}

/// One dated goal: a plan ([programId] set) or a course with no plan.
typedef ReadyBy = ({
  String id,
  String? programId,
  String? courseId,
  String title,
  String day,
  ReadyBySource source,
});

/// Every dated goal still open: active plans with a target or interview
/// date (the earlier wins), then courses with no plan (or whose plan was
/// deleted) that are not done or dropped and have a due date. Soonest
/// first.
List<ReadyBy> readyByDates({
  required List<Program> programs,
  required List<Course> courses,
  Map<String, String> interviewDates = const {},
}) {
  final live = {
    for (final p in programs)
      if (!p.deleted) p.id,
  };
  final out = <ReadyBy>[
    for (final p in programs)
      if (!p.deleted && p.status == 'active')
        if (_earlier(p.target, interviewDates[p.id]) case (final day?, final source))
          (id: p.id, programId: p.id, courseId: null, title: p.title, day: day, source: source),
    for (final c in courses)
      if (!c.deleted &&
          c.status != 'done' &&
          c.status != 'dropped' &&
          (c.programId == null || !live.contains(c.programId)) &&
          (c.due ?? '').isNotEmpty)
        (id: c.id, programId: null, courseId: c.id, title: c.title, day: c.due!, source: ReadyBySource.due),
  ];
  return out..sort((a, b) => a.day != b.day ? a.day.compareTo(b.day) : a.title.compareTo(b.title));
}

(String?, ReadyBySource) _earlier(String? target, String? interview) {
  final t = (target ?? '').isEmpty ? null : target;
  final i = (interview ?? '').isEmpty ? null : interview;
  if (i != null && (t == null || i.compareTo(t) <= 0)) return (i, ReadyBySource.interview);
  return (t, ReadyBySource.target);
}

/// How much a topic matters to its plan: 3 when it works towards an
/// essential criterion, 2 towards a desirable one only, 1 otherwise.
int topicWeight(Topic t, Map<String, Criterion> criteriaByRef) {
  var w = 1;
  for (final r in criteriaRefs(t)) {
    final c = criteriaByRef[r];
    if (c == null) continue;
    if (c.essential) return 3;
    w = 2;
  }
  return w;
}

/// What an open topic still needs, in minutes: [required] for its open
/// required items, [optional] for the rest. [guessed] is true when any of
/// it came from a default rather than an estimate.
typedef TopicNeed = ({Topic topic, Course course, int weight, int required, int optional, bool guessed});

/// What a suggestion asks: do only the required items, or leave it out.
enum FitAction { skim, drop }

typedef FitSuggestion = ({TopicNeed need, FitAction action, int saves});

/// The fit of one dated goal on a day.
class TimeFit {
  const TimeFit({
    required this.goal,
    required this.today,
    required this.weekMinutes,
    required this.weekIsDefault,
    required this.needed,
    required this.available,
    required this.needs,
    required this.suggestions,
    required this.unestimated,
    required this.guessed,
  });

  final ReadyBy goal;
  final String today;

  /// The hours a week it counts, in minutes, and whether that is
  /// [defaultWeekMinutes] because no weekly target is set.
  final int weekMinutes;
  final bool weekIsDefault;

  /// Study minutes still to do, and minutes there are before the day.
  final int needed, available;
  final List<TopicNeed> needs;

  /// What to skim, then drop, lowest weight first, until the gap closes.
  final List<FitSuggestion> suggestions;

  /// Courses with no topics and no hours estimate: not counted at all.
  final int unestimated;

  /// Whether any minutes came from [defaultItemMinutes] or a topic's own
  /// estimate rather than item estimates.
  final bool guessed;

  /// Days left before the day itself (the day is not a study day).
  int get daysLeft => goal.day.compareTo(today) <= 0 ? 0 : daysBetween(today, goal.day);
  bool get passed => goal.day.compareTo(today) < 0;
  bool get isToday => goal.day == today;
  int get short => needed - available;
  bool get fits => short <= 0;

  /// Minutes the suggestions free, and the gap left after them.
  int get saved => suggestions.fold<int>(0, (a, s) => a + s.saves);
  int get shortAfter => short - saved;

  /// The headline: "Fits", "4.5 hours short", or the day's state.
  String get headline {
    if (passed) return 'The day has passed';
    if (isToday) return 'The day is today';
    if (needed == 0) return 'Nothing left to study';
    return fits ? 'Fits' : '${hoursText(short)} short';
  }

  /// The numbers behind [headline], in one plain sentence.
  String get detail {
    if (passed || isToday) return '';
    final week = weekIsDefault
        ? '${hoursText(weekMinutes)} a week (the default: no weekly target is set)'
        : '${hoursText(weekMinutes)} a week';
    final parts = [
      'About ${hoursText(needed)} of study left; ${hoursText(available)} available in '
          '$daysLeft ${daysLeft == 1 ? 'day' : 'days'} at $week.',
      if (guessed) 'Items with no estimate count $defaultItemMinutes min each.',
      if (unestimated > 0)
        '${unestimated == 1 ? '1 course has' : '$unestimated courses have'} no time estimate '
            'and ${unestimated == 1 ? 'is' : 'are'} not counted.',
      'Flashcard reviews are not counted.',
    ];
    return parts.join(' ');
  }
}

/// Minutes as hours, rounded up to the half hour ("4.5 hours", "1 hour"),
/// or minutes under an hour ("40 min").
String hoursText(int minutes) {
  if (minutes < 60) return '$minutes min';
  final halves = (minutes / 30).ceil();
  final h = halves / 2;
  final s = h == h.roundToDouble() ? '${h.round()}' : h.toStringAsFixed(1);
  return '$s ${h == 1 ? 'hour' : 'hours'}';
}

/// How [goal] fits on [today]. [weekMinutes] 0 means no weekly target, so
/// [defaultWeekMinutes] is used. Topics already done count nothing; a
/// course with no topics counts its hours estimate less the time logged
/// on it.
TimeFit fitFor(
  ReadyBy goal, {
  required String today,
  required List<Course> courses,
  required List<Topic> topics,
  required List<StudyItem> items,
  List<Criterion> criteria = const [],
  List<StudySession> sessions = const [],
  int weekMinutes = 0,
}) {
  final week = weekMinutes > 0 ? weekMinutes : defaultWeekMinutes;
  final scope = [
    for (final c in courses)
      if (!c.deleted &&
          c.status != 'done' &&
          c.status != 'dropped' &&
          (goal.programId != null ? c.programId == goal.programId : c.id == goal.courseId))
        c,
  ];
  final byRef = {
    for (final c in criteria)
      if (!c.deleted && c.programId == goal.programId) c.ref: c,
  };
  final byTopic = <String, List<StudyItem>>{};
  for (final i in items) {
    if (!i.deleted && i.retired.isEmpty) (byTopic[i.topicId] ??= []).add(i);
  }
  final needs = <TopicNeed>[];
  var unestimated = 0, extra = 0;
  var guessed = false;
  for (final c in scope) {
    final its = [
      for (final t in topics)
        if (t.courseId == c.id && !t.deleted) t,
    ]..sort((a, b) => a.ord != b.ord ? a.ord.compareTo(b.ord) : a.id.compareTo(b.id));
    if (its.isEmpty) {
      if (c.hours <= 0) {
        unestimated++;
        continue;
      }
      final logged = sessions
          .where((s) => !s.deleted && s.courseId == c.id)
          .fold<int>(0, (a, s) => a + s.minutes);
      extra += (c.hours * 60 - logged).clamp(0, c.hours * 60).toInt();
      continue;
    }
    for (final t in its) {
      if (t.done != null) continue;
      final open = [
        for (final i in byTopic[t.id] ?? const <StudyItem>[])
          if (i.done == null) i,
      ];
      final all = byTopic[t.id] ?? const <StudyItem>[];
      int req = 0, opt = 0;
      var g = false;
      if (all.isEmpty) {
        opt = t.minutes;
        g = true;
      } else {
        for (final i in open) {
          final m = i.minutes > 0 ? i.minutes : defaultItemMinutes;
          if (i.minutes <= 0) g = true;
          if (i.required) {
            req += m;
          } else {
            opt += m;
          }
        }
      }
      if (req + opt == 0) continue;
      guessed |= g;
      needs.add((
        topic: t,
        course: c,
        weight: topicWeight(t, byRef),
        required: req,
        optional: opt,
        guessed: g,
      ));
    }
  }
  final needed = extra + needs.fold<int>(0, (a, n) => a + n.required + n.optional);
  final days = goal.day.compareTo(today) <= 0 ? 0 : daysBetween(today, goal.day);
  final available = (week * days / 7).floor();
  return TimeFit(
    goal: goal,
    today: today,
    weekMinutes: week,
    weekIsDefault: weekMinutes <= 0,
    needed: needed,
    available: available,
    needs: needs,
    suggestions: needed > available && days > 0 ? suggestCuts(needs, needed - available) : const [],
    unestimated: unestimated,
    guessed: guessed,
  );
}

/// What to cut to free [short] minutes. First skim (keep only the
/// required items) the topics that have both kinds, lowest weight first
/// and, at one weight, later topics first; then drop whole topics the same
/// way. Topics towards an essential criterion (weight 3) are skimmed but
/// never dropped. Stops once enough is freed, so it may free less than
/// [short] when nothing else is safe to cut.
List<FitSuggestion> suggestCuts(List<TopicNeed> needs, int short) {
  final order = [...needs.indexed]
    ..sort((a, b) => a.$2.weight != b.$2.weight ? a.$2.weight.compareTo(b.$2.weight) : b.$1.compareTo(a.$1));
  final out = <FitSuggestion>[];
  final skimmed = <String>{};
  var freed = 0;
  for (final (_, n) in order) {
    if (freed >= short) return out;
    if (n.required > 0 && n.optional > 0) {
      out.add((need: n, action: FitAction.skim, saves: n.optional));
      skimmed.add(n.topic.id);
      freed += n.optional;
    }
  }
  for (final (_, n) in order) {
    if (freed >= short) return out;
    if (n.weight >= 3) continue;
    final left = skimmed.contains(n.topic.id) ? n.required : n.required + n.optional;
    out.removeWhere((s) => s.need.topic.id == n.topic.id);
    out.add((need: n, action: FitAction.drop, saves: n.required + n.optional));
    freed += left;
  }
  return out;
}

/// The words for one suggestion.
String suggestionText(FitSuggestion s) => switch (s.action) {
  FitAction.skim => 'Skim ${s.need.topic.title}: do only the required items (saves ${hoursText(s.saves)})',
  FitAction.drop => 'Drop ${s.need.topic.title} (saves ${hoursText(s.saves)})',
};

// ---- reviews kept before the day ----

/// The ready-by day each card's reviews must land before: its course's
/// goal (the course's plan, or the course itself), else the plan it came
/// from (matched by title). Cards with neither have no limit.
String? cardReadyBy(Flashcard c, {required List<ReadyBy> goals, required List<Course> courses}) {
  final course = c.courseId == null ? null : courses.where((x) => x.id == c.courseId).firstOrNull;
  if (course != null) {
    final g = goals
        .where((g) => g.courseId == course.id || (g.programId != null && g.programId == course.programId))
        .firstOrNull;
    if (g != null) return g.day;
  }
  if (c.plan.isNotEmpty) {
    return goals.where((g) => g.programId != null && g.title.toLowerCase() == c.plan).firstOrNull?.day;
  }
  return null;
}

/// Every card's limit at once (see [cardReadyBy]), by card id; cards with
/// no limit are left out.
Map<String, String> cardLimits(
  Iterable<Flashcard> cards, {
  required List<ReadyBy> goals,
  required List<Course> courses,
}) => {for (final c in cards) c.id: ?cardReadyBy(c, goals: goals, courses: courses)};

// ---- the outcome once the day has passed ----

/// The `kind` of an assessment detail that records how a real interview
/// or exam went (see [ReadyByOutcome]).
const outcomeKind = 'readyby-outcome';

/// The `itemId` an outcome row carries for a goal, so it can be found
/// again without reading every result.
String outcomeItemId(String goalId) => 'readyby.$goalId';

/// How it went.
enum OutcomeResult {
  passed('Passed, or got the job'),
  notPassed('Did not pass, or no offer'),
  waiting('Taken, still waiting for the result'),
  didNotHappen('Did not happen (moved or cancelled)');

  const OutcomeResult(this.label);
  final String label;

  static OutcomeResult? named(Object? n) => values.where((r) => r.name == n).firstOrNull;
}

/// A real outcome for a goal's day, kept as a `LearnAssessments` row's
/// detail. [percent] is the score when there was one. Readiness
/// calibration (C5) compares it with what the app showed beforehand.
class ReadyByOutcome {
  const ReadyByOutcome({
    required this.goalId,
    required this.target,
    required this.result,
    this.percent,
    this.note = '',
  });

  final String goalId;

  /// The ready-by day it answers (yyyy-MM-dd).
  final String target;
  final OutcomeResult result;
  final int? percent;
  final String note;

  String encode() => jsonEncode({
    'kind': outcomeKind,
    'goal': goalId,
    'target': target,
    'result': result.name,
    'percent': ?percent,
    if (note.isNotEmpty) 'note': note,
  });

  static ReadyByOutcome? parse(String detail) {
    if (detail.isEmpty) return null;
    try {
      final j = jsonDecode(detail);
      if (j is! Map || j['kind'] != outcomeKind) return null;
      final result = OutcomeResult.named(j['result']);
      final goal = j['goal'], target = j['target'];
      if (result == null || goal is! String || target is! String) return null;
      final p = j['percent'];
      final note = j['note'];
      return ReadyByOutcome(
        goalId: goal,
        target: target,
        result: result,
        percent: p is num ? p.round().clamp(0, 100) : null,
        note: note is String ? note : '',
      );
    } on FormatException {
      return null;
    }
  }
}

/// Whether [a] records a real outcome (not a quiz or test result).
bool isOutcomeRecord(Assessment a) => ReadyByOutcome.parse(a.detail) != null;

/// The goals whose day has passed with no outcome logged for that day.
List<ReadyBy> awaitingOutcome(List<ReadyBy> goals, List<ReadyByOutcome> outcomes, String today) => [
  for (final g in goals)
    if (g.day.compareTo(today) < 0 && !outcomes.any((o) => o.goalId == g.id && o.target == g.day)) g,
];

// ---- reads and writes ----

/// Everything the ready-by screens need, read once.
typedef ReadyByData = ({
  List<ReadyBy> goals,
  List<ReadyByOutcome> outcomes,
  List<Criterion> criteria,
  int weekMinutes,
});

extension TimeFitBook on LearningBook {
  /// The open dated goals (see [readyByDates]).
  Future<List<ReadyBy>> readyByGoals() async {
    final programs = await (db.select(db.learnPrograms)..where((p) => p.deleted.not())).get();
    final courses = await (db.select(db.learnCourses)..where((c) => c.deleted.not())).get();
    return readyByDates(
      programs: programs,
      courses: courses,
      interviewDates: {
        for (final p in programs)
          if (p.status == 'active') p.id: ?await interviewDate(p.id),
      },
    );
  }

  /// Every outcome logged, oldest first.
  Future<List<ReadyByOutcome>> readyByOutcomes() async {
    final rows =
        await (db.select(db.learnAssessments)
              ..where((a) => a.deleted.not() & a.itemId.like('readyby.%'))
              ..orderBy([(a) => OrderingTerm.asc(a.day)]))
            .get();
    return [for (final r in rows) ?ReadyByOutcome.parse(r.detail)];
  }

  Future<ReadyByData> readyByData() async => (
    goals: await readyByGoals(),
    outcomes: await readyByOutcomes(),
    criteria: await (db.select(db.learnCriteria)..where((c) => c.deleted.not())).get(),
    weekMinutes: await weekTarget(),
  );

  /// Sets or clears a plan's target date. With an interview date set, the
  /// earlier of the two is the ready-by day.
  Future<void> setProgramTarget(String programId, String? day) async {
    final p = await (db.select(db.learnPrograms)..where((x) => x.id.equals(programId))).getSingle();
    await save(db.learnPrograms, p.copyWith(target: Value(day)), p.id);
  }

  /// Sets or clears a course's due date (its ready-by day when it has no
  /// plan).
  Future<void> setCourseDue(String courseId, String? day) async {
    final c = await (db.select(db.learnCourses)..where((x) => x.id.equals(courseId))).getSingle();
    await save(db.learnCourses, c.copyWith(due: Value(day)), c.id);
  }

  /// Logs how the real interview or exam went for [goal]'s day. Kept as a
  /// result row whose detail says it is an outcome, so it earns nothing
  /// and changes no average.
  Future<String> logOutcome(
    ReadyBy goal,
    OutcomeResult result, {
    required String today,
    int? percent,
    String note = '',
  }) async {
    final id = newId();
    final o = ReadyByOutcome(
      goalId: goal.id,
      target: goal.day,
      result: result,
      percent: percent?.clamp(0, 100),
      note: note.trim().length > 500 ? note.trim().substring(0, 500) : note.trim(),
    );
    await save(
      db.learnAssessments,
      LearnAssessmentsCompanion.insert(
        id: id,
        courseId: Value(goal.courseId),
        itemId: Value(outcomeItemId(goal.id)),
        title: 'Outcome: ${goal.title}',
        day: today,
        score: (o.percent ?? (result == OutcomeResult.passed ? 100 : 0)).toDouble(),
        max: const Value(100),
        detail: Value(o.encode()),
        deleted: const Value(false),
      ),
      id,
    );
    return id;
  }

  /// Moves every card whose next review lands on or after its ready-by day
  /// to a day before it (see [capDue]). Runs when a date is set and when
  /// the app opens; running again changes nothing. Gives how many moved.
  Future<int> pullReviewsBefore(String today) => db.transaction(() async {
    final goals = await readyByGoals();
    if (goals.isEmpty) return 0;
    final courses = await (db.select(db.learnCourses)..where((c) => c.deleted.not())).get();
    final cards = await (db.select(
      db.learnCards,
    )..where((c) => c.deleted.not() & c.retired.equals(''))).get();
    var moved = 0;
    for (final c in cards) {
      final limit = cardReadyBy(c, goals: goals, courses: courses);
      final due = capDue(c.due, today: today, readyBy: limit, slot: dueSlot(c.id));
      if (due != c.due) {
        await save(db.learnCards, c.copyWith(due: due), c.id);
        moved++;
      }
    }
    return moved;
  });
}
