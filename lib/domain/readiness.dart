/// Job readiness (role study plan V6): one row per criterion of a program
/// (the essential and desirable criteria a Udyoga role plan sent, or ones
/// the learner typed in from a person specification), each with the
/// evidence built in Vidya and a status: covered, weak or missing.
///
/// The rules, in plain words:
///
/// * **Evidence** is the learner's own work linked to the criterion: topics
///   that work towards it (done or still open), the latest quiz score on
///   those topics, practice tasks on them, interview drills that test it
///   (the latest self-rated or Udyoga score), stories linked to it,
///   portfolio items whose skills match its words, and a skill of the same
///   name rated against its target.
/// * **Missing**: no evidence at all, not even something planned.
/// * **Covered**: at least one strong piece from the last [freshDays] days:
///   a done topic whose latest quiz is 70% or more, a practice task done
///   with evidence (a link or a note on what was done), a drill whose latest
///   score is 5 of 8 or more, or a linked story together with a done topic.
/// * **Weak**: anything else that has evidence: only old evidence (a strong
///   piece older than [freshDays] days), a latest quiz under 70%, a latest
///   drill under 5 of 8, only planned items (open topics, tasks not done,
///   drills not practised), or work that has not been checked yet (a topic
///   ticked without a quiz, a story, a portfolio item or a skill rating on
///   their own). Each piece is judged on its own latest result, so a low
///   score on one drill does not undo a strong task elsewhere.
/// * **AI never marks a row covered.** Nothing an AI writes or sends can set
///   a status: a criterion's source ("AI"), the "your CV shows this" flag
///   and any `covered` or `status` field a plan might carry are ignored,
///   and a piece of evidence marked [Evidence.ai] is listed but never
///   counts as strong. Only the learner's own results do.
/// * **Exams, capstones and stress tests** are listed with their dates. A
///   topic's latest exam counts as its quiz, judged on the exam's own pass
///   mark. A stress test whose `criteria` name the row counts on its latest
///   attempt: passed is medium evidence (self-rated, so it lifts the row to
///   weak but never covers it alone); any high-risk row left untouched, or
///   a rating under the bar, is low. A capstone counts for the rows its
///   drills test: passed is medium, not passed low (its drills already
///   count on their own as drill attempts).
/// * **Self-ratings never cover.** A framework self-rating (framework.dart)
///   that names a criterion is listed as evidence: a gap (rated 1 or less,
///   or with no story) makes the row weak, any other rating only lifts it
///   from missing to weak.
///
/// Readiness is shown as counts ("9 of 12 essential covered, 2 weak, 1
/// missing"), never as one percentage. Weak and missing rows also go back
/// to Udyoga in the plan's progress report (see [readinessReport]) so it
/// can turn them into drill cards.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'capstone.dart';
import 'exam.dart' show ExamResult, examAttempts;
import 'framework.dart';
import 'interview.dart';
import 'quiz.dart' show isQuizResult, percentOf;
import 'scenario.dart';
import 'study_items.dart';

/// Evidence older than this many days no longer covers a criterion.
const freshDays = 60;

/// The `source` of a criterion the learner typed in.
const ownCriterionSource = 'you';

/// The ref prefix of a criterion the learner typed in. A plan sent again
/// never touches these (plan refs are the plan's own ids).
const ownCriterionPrefix = 'own.';

/// Whether [c] was typed in by the learner rather than sent by a plan.
bool isOwnCriterion(Criterion c) => c.ref.startsWith(ownCriterionPrefix);

enum ReadinessStatus {
  missing('Missing'),
  weak('Weak'),
  covered('Covered');

  const ReadinessStatus(this.label);
  final String label;
}

/// What a piece of evidence is.
enum EvidenceKind {
  topic,
  quiz,
  exam,
  task,
  drill,
  scenario,
  capstone,
  story,
  portfolio,
  skill,
  cv,
  framework,
}

/// How a piece of evidence counts, before its age is looked at.
enum EvidenceWeight {
  /// Not done yet: an open topic, a task not done, a drill not practised.
  planned,

  /// Done but not checked: a topic ticked without a quiz, a story, a
  /// portfolio item, a skill rating. Lifts a row from missing to weak.
  unchecked,

  /// A self-rated pass (a stress test or a capstone): more than unchecked
  /// work, but it never covers a row on its own.
  medium,

  /// A checked result under the bar: a quiz under 70%, a drill under 5/8.
  low,

  /// A checked result at or over the bar, or a task done with evidence.
  strong,

  /// Shown for information only; never counts (the CV flag from Udyoga).
  info,
}

/// One piece of evidence for a criterion.
class Evidence {
  const Evidence({
    required this.kind,
    required this.title,
    required this.detail,
    required this.weight,
    this.day = '',
    this.id = '',
    this.ai = false,
  });

  final EvidenceKind kind;
  final String title;

  /// One line on how it stands ("Quiz 80% on 3 Nov 2026").
  final String detail;
  final EvidenceWeight weight;

  /// When it happened (yyyy-MM-dd), '' when it has no day (planned items).
  final String day;

  /// What a tap opens: a topic, item, story, portfolio or skill row id.
  final String id;

  /// Made or judged by an AI. Listed, but never strong (see the library
  /// rules). Nothing sets it today; it guards any AI marking added later.
  final bool ai;

  /// Whether it happened within [freshDays] days of [today].
  bool freshOn(String today) => day.isNotEmpty && daysBetween(day, today) <= freshDays;
}

/// Whole days from [from] to [to] (both yyyy-MM-dd).
int daysBetween(String from, String to) =>
    DateTime.parse('${to}T00:00Z').difference(DateTime.parse('${from}T00:00Z')).inDays;

/// Why a weak row is weak, in order of how much work it needs.
enum WeakReason {
  planned('Only planned so far'),
  lowQuiz('Latest quiz under 70%'),
  lowDrill('Latest drill under 4/5'),
  lowTest('Latest stress test or capstone not passed'),
  selfGap('Self-assessment gap'),
  unchecked('Not checked yet'),
  selfRated('Only self-rated passes so far'),
  old('Only old evidence (over $freshDays days)');

  const WeakReason(this.label);
  final String label;
}

/// One criterion's readiness.
class ReadinessRow {
  const ReadinessRow({
    required this.criterion,
    required this.status,
    this.evidence = const [],
    this.reasons = const [],
  });

  final Criterion criterion;
  final ReadinessStatus status;
  final List<Evidence> evidence;

  /// Why it is weak (empty unless [status] is weak).
  final List<WeakReason> reasons;

  bool get essential => criterion.essential;

  /// How weak the row is, 0 the weakest: missing, then weak with only
  /// planned items, low scores, unchecked work, old evidence; covered last.
  int get rank => switch (status) {
    ReadinessStatus.missing => 0,
    ReadinessStatus.covered => WeakReason.values.length + 1,
    ReadinessStatus.weak =>
      1 +
          (reasons.isEmpty
              ? WeakReason.unchecked.index
              : reasons.map((r) => r.index).reduce((a, b) => a < b ? a : b)),
  };
}

/// Judges one criterion from its evidence (see the library rules). Returns
/// the status and, when weak, why.
({ReadinessStatus status, List<WeakReason> reasons}) judgeEvidence(List<Evidence> evidence, String today) {
  final counted = [
    for (final e in evidence)
      if (e.weight != EvidenceWeight.info) e,
  ];
  if (counted.isEmpty) return (status: ReadinessStatus.missing, reasons: const []);
  // A self-rating is the learner's view, not checked work: never strong.
  bool strongAt(Evidence e) => !e.ai && e.kind != EvidenceKind.framework && e.weight == EvidenceWeight.strong;
  if (counted.any((e) => strongAt(e) && e.freshOn(today))) {
    return (status: ReadinessStatus.covered, reasons: const []);
  }
  // A linked story together with a done topic is strong, dated by the
  // newer of the two.
  final stories = counted.where((e) => !e.ai && e.kind == EvidenceKind.story && e.day.isNotEmpty);
  final doneTopics = counted.where(
    (e) => !e.ai && e.kind == EvidenceKind.topic && e.weight != EvidenceWeight.planned && e.day.isNotEmpty,
  );
  String? pairDay;
  for (final s in stories) {
    for (final t in doneTopics) {
      final d = s.day.compareTo(t.day) >= 0 ? s.day : t.day;
      if (pairDay == null || d.compareTo(pairDay) > 0) pairDay = d;
    }
  }
  if (pairDay != null && daysBetween(pairDay, today) <= freshDays) {
    return (status: ReadinessStatus.covered, reasons: const []);
  }
  final reasons = <WeakReason>{
    if (counted.every((e) => e.weight == EvidenceWeight.planned)) WeakReason.planned,
    if (counted.any(
      (e) => (e.kind == EvidenceKind.quiz || e.kind == EvidenceKind.exam) && e.weight == EvidenceWeight.low,
    ))
      WeakReason.lowQuiz,
    if (counted.any((e) => e.kind == EvidenceKind.drill && e.weight == EvidenceWeight.low))
      WeakReason.lowDrill,
    if (counted.any(
      (e) =>
          (e.kind == EvidenceKind.scenario || e.kind == EvidenceKind.capstone) &&
          e.weight == EvidenceWeight.low,
    ))
      WeakReason.lowTest,
    if (counted.any((e) => e.kind == EvidenceKind.framework && e.weight == EvidenceWeight.low))
      WeakReason.selfGap,
    if (counted.any((e) => strongAt(e)) || pairDay != null) WeakReason.old,
  };
  if (reasons.isEmpty) {
    reasons.add(
      counted.any((e) => e.weight == EvidenceWeight.medium) ? WeakReason.selfRated : WeakReason.unchecked,
    );
  }
  return (
    status: ReadinessStatus.weak,
    reasons: reasons.toList()..sort((a, b) => a.index.compareTo(b.index)),
  );
}

// ---- next action ----

/// What the next action opens.
enum ActionKind { quiz, drill, topic, story }

/// The one thing to do next for the weakest essential row.
class ReadinessAction {
  const ReadinessAction(this.kind, this.label, {required this.criterion, this.id = ''});
  final ActionKind kind;

  /// The button text ("Take the quiz on Explaining clearly").
  final String label;
  final Criterion criterion;

  /// The quiz or drill item id, or the topic id; '' for a story.
  final String id;
}

/// The row to work on next: the weakest essential row (see
/// [ReadinessRow.rank]; plan order breaks ties), else the weakest
/// desirable one; null when every row is covered.
ReadinessRow? weakestRow(List<ReadinessRow> rows) {
  ReadinessRow? best;
  for (final r in rows) {
    if (r.status == ReadinessStatus.covered) continue;
    if (best == null ||
        (r.essential && !best.essential) ||
        (r.essential == best.essential && r.rank < best.rank)) {
      best = r;
    }
  }
  return best;
}

/// The next action for [row]: retake a low or old quiz, practise a low or
/// old drill, take a quiz never taken, practise a drill never practised,
/// finish an open task, else write a story for it.
ReadinessAction nextActionFor(
  ReadinessRow row, {
  required Map<String, StudyItem> quizzes,
  required String today,
}) {
  final c = row.criterion;
  final ev = row.evidence;
  bool stale(Evidence e) => e.weight == EvidenceWeight.strong && !e.freshOn(today);
  for (final e in ev) {
    if ((e.kind == EvidenceKind.quiz || e.kind == EvidenceKind.exam) &&
        (e.weight == EvidenceWeight.low || stale(e))) {
      final q = quizzes[e.id];
      if (q != null) {
        return ReadinessAction(ActionKind.quiz, 'Retake the quiz on ${e.title}', criterion: c, id: q.id);
      }
    }
  }
  for (final e in ev) {
    if (e.kind == EvidenceKind.drill && (e.weight == EvidenceWeight.low || stale(e))) {
      return ReadinessAction(ActionKind.drill, 'Practise drill again: ${e.title}', criterion: c, id: e.id);
    }
  }
  final quizzed = {
    for (final e in ev)
      if (e.kind == EvidenceKind.quiz || e.kind == EvidenceKind.exam) e.id,
  };
  for (final e in ev) {
    if (e.kind == EvidenceKind.topic && !quizzed.contains(e.id) && quizzes[e.id] != null) {
      return ReadinessAction(
        ActionKind.quiz,
        'Take the quiz on ${e.title}',
        criterion: c,
        id: quizzes[e.id]!.id,
      );
    }
  }
  for (final e in ev) {
    if (e.kind == EvidenceKind.drill && e.weight == EvidenceWeight.planned) {
      return ReadinessAction(ActionKind.drill, 'Practise drill: ${e.title}', criterion: c, id: e.id);
    }
  }
  for (final e in ev) {
    if (e.kind == EvidenceKind.task && e.weight == EvidenceWeight.planned) {
      return ReadinessAction(ActionKind.topic, 'Finish the task: ${e.title}', criterion: c, id: e.id);
    }
  }
  return ReadinessAction(ActionKind.story, 'Write a story for ${c.body}', criterion: c);
}

// ---- summary ----

/// Readiness in counts, never one percentage.
class ReadinessSummary {
  const ReadinessSummary({
    this.essential = 0,
    this.essentialCovered = 0,
    this.essentialWeak = 0,
    this.essentialMissing = 0,
    this.desirable = 0,
    this.desirableCovered = 0,
    this.interviewDate,
  });

  final int essential, essentialCovered, essentialWeak, essentialMissing;
  final int desirable, desirableCovered;

  /// The interview day set for the program (yyyy-MM-dd), null when none.
  final String? interviewDate;

  factory ReadinessSummary.of(List<ReadinessRow> rows, {String? interviewDate}) {
    int count(bool essential, [ReadinessStatus? s]) =>
        rows.where((r) => r.essential == essential && (s == null || r.status == s)).length;
    return ReadinessSummary(
      essential: count(true),
      essentialCovered: count(true, ReadinessStatus.covered),
      essentialWeak: count(true, ReadinessStatus.weak),
      essentialMissing: count(true, ReadinessStatus.missing),
      desirable: count(false),
      desirableCovered: count(false, ReadinessStatus.covered),
      interviewDate: interviewDate,
    );
  }

  /// "9 of 12 essential covered, 2 weak, 1 missing · desirable 3 of 5 ·
  /// interview in 6 days". Parts with nothing to say are left out.
  String text(String today) {
    final parts = <String>[];
    if (essential > 0) {
      parts.add(
        [
          '$essentialCovered of $essential essential covered',
          if (essentialWeak > 0) '$essentialWeak weak',
          if (essentialMissing > 0) '$essentialMissing missing',
        ].join(', '),
      );
    }
    if (desirable > 0) parts.add('desirable $desirableCovered of $desirable');
    if (interviewDate case final d?) {
      final s = interviewCountdown(d, today);
      parts.add('${s[0].toLowerCase()}${s.substring(1)}');
    }
    return parts.isEmpty ? 'No criteria yet' : parts.join(' · ');
  }
}

/// A program's readiness: its rows (plan order), the summary and the next
/// action (null when every row is covered or there are none).
class Readiness {
  const Readiness({required this.rows, required this.summary, this.next});
  final List<ReadinessRow> rows;
  final ReadinessSummary summary;
  final ReadinessAction? next;

  List<ReadinessRow> get essential => [
    for (final r in rows)
      if (r.essential) r,
  ];
  List<ReadinessRow> get desirable => [
    for (final r in rows)
      if (!r.essential) r,
  ];
}

// ---- calibration (C5) ----

/// How many of the exam questions behind readiness had been asked before:
/// per topic whose latest quiz result is an exam attempt, the questions of
/// that attempt ([asked]) and how many of them came up in an earlier
/// attempt on the topic ([repeats]).
typedef SeenBefore = ({int repeats, int asked});

/// See [SeenBefore]. Practice quizzes are left out: only exam attempts
/// keep the questions asked.
SeenBefore examRepeats(Iterable<Assessment> tests) {
  final latest = latestQuizzes(tests);
  var repeats = 0, asked = 0;
  for (final MapEntry(key: topic, value: q) in latest.entries) {
    if (q.exam == null) continue;
    final attempts = [for (final a in examAttempts(tests, topic)) ?ExamResult.of(a)];
    if (attempts.isEmpty) continue;
    final last = attempts.last;
    final before = {for (final r in attempts.take(attempts.length - 1)) ...r.asked};
    repeats += last.asked.where(before.contains).length;
    asked += last.asked.length;
  }
  return (repeats: repeats, asked: asked);
}

/// Whether readiness rests largely (half or more) on exam questions seen
/// before, so it may be inflated.
bool possiblyInflated(SeenBefore s) => s.asked > 0 && s.repeats * 2 >= s.asked;

/// The warning for [s], or null when it is not [possiblyInflated].
String? inflationText(SeenBefore s) => !possiblyInflated(s)
    ? null
    : 'Possibly inflated: ${s.repeats} of ${s.asked} exam questions behind this readiness were asked in an '
          'earlier attempt. A remembered answer can look like knowledge; a fresh question pool tells more.';

/// What readiness showed when a real outcome was logged: [covered] of
/// [total] criteria (the essential ones when there are any, else all), and
/// the exam questions behind it seen before. Kept in the outcome's detail
/// so the result can be compared with it later.
class ReadinessSnapshot {
  const ReadinessSnapshot({
    required this.covered,
    required this.total,
    required this.essential,
    this.repeats = 0,
    this.asked = 0,
  });

  final int covered, total;

  /// The counts are of essential criteria (else of every criterion).
  final bool essential;
  final int repeats, asked;

  /// The share covered, as the percent compared with a result. Readiness
  /// itself is shown as counts; this is that count as a percent.
  int get percent => total == 0 ? 0 : (covered * 100 / total).round();

  SeenBefore get seen => (repeats: repeats, asked: asked);

  String get countsText => '$covered of $total ${essential ? 'essential ' : ''}criteria covered';

  /// From [r] and [seen]; null when the program has no criteria.
  static ReadinessSnapshot? of(Readiness r, SeenBefore seen) {
    if (r.rows.isEmpty) return null;
    final s = r.summary;
    final essential = s.essential > 0;
    return ReadinessSnapshot(
      covered: essential
          ? s.essentialCovered
          : r.rows.where((x) => x.status == ReadinessStatus.covered).length,
      total: essential ? s.essential : r.rows.length,
      essential: essential,
      repeats: seen.repeats,
      asked: seen.asked,
    );
  }

  Map<String, Object> toJson() => {
    'covered': covered,
    'total': total,
    'essential': essential,
    'repeats': repeats,
    'asked': asked,
  };

  static ReadinessSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    int? n(String k) => j[k] is num ? (j[k] as num).round() : null;
    final covered = n('covered'), total = n('total');
    if (covered == null || total == null || total <= 0 || covered < 0 || covered > total) return null;
    return ReadinessSnapshot(
      covered: covered,
      total: total,
      essential: j['essential'] == true,
      repeats: (n('repeats') ?? 0).clamp(0, 1 << 20),
      asked: (n('asked') ?? 0).clamp(0, 1 << 20),
    );
  }
}

// ---- building the rows ----

/// The latest quiz result on a topic: percent and day; for an exam
/// attempt, [exam] is set with whether it passed on the exam's own mark.
typedef QuizResult = ({int percent, String day, ({bool passed})? exam});

/// The latest quiz result per topic id (practice quizzes and exam
/// attempts). Drill attempts are not quizzes.
Map<String, QuizResult> latestQuizzes(Iterable<Assessment> tests) {
  final latest = <String, Assessment>{};
  for (final a in tests) {
    final t = a.topicId;
    if (t == null || a.deleted || !isQuizResult(a)) continue;
    final had = latest[t];
    if (had == null || a.day.compareTo(had.day) > 0 || (a.day == had.day && a.hlc.compareTo(had.hlc) > 0)) {
      latest[t] = a;
    }
  }
  return {
    for (final e in latest.entries)
      e.key: (
        percent: percentOf(e.value.score, e.value.max),
        day: e.value.day,
        exam: switch (ExamResult.of(e.value)) {
          final r? => (passed: r.passed),
          null => null,
        },
      ),
  };
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Whether a skill or portfolio skill name matches a criterion's words:
/// the same words, or one held whole inside the other (when the shorter
/// has at least four letters).
bool skillMatches(String skill, String criterion) {
  final a = _norm(skill), b = _norm(criterion);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final (short, long) = a.length <= b.length ? (a, b) : (b, a);
  return short.length >= 4 && ' $long '.contains(' $short ');
}

/// A result kept on an item (a stress-test attempt or a capstone sitting)
/// with its day.
typedef Dated<T> = ({String day, T result});

/// The latest result per item id among [tests], read by [parse] (null for
/// rows of another kind).
Map<String, Dated<T>> latestOnItems<T>(Iterable<Assessment> tests, T? Function(String detail) parse) {
  final latest = <String, Assessment>{};
  final read = <String, T>{};
  for (final a in tests) {
    final id = a.itemId;
    if (id == null || a.deleted) continue;
    final r = parse(a.detail);
    if (r == null) continue;
    final had = latest[id];
    if (had == null || a.day.compareTo(had.day) > 0 || (a.day == had.day && a.hlc.compareTo(had.hlc) > 0)) {
      latest[id] = a;
      read[id] = r;
    }
  }
  return {for (final e in latest.entries) e.key: (day: e.value.day, result: read[e.key] as T)};
}

String _pct(int p) => '$p%';
String _of8(double s) => s % 1 == 0 ? '${s.toInt()}' : s.toStringAsFixed(1);

/// Builds every row from rows already read. [topics] are the program's
/// topics, [items] their study items still in use, [quizzes] the latest
/// quiz per topic id, [drills] each drill's practice by item id,
/// [storyDays] the day each linked story was last saved (by story id).
Readiness assessReadiness({
  required List<Criterion> criteria,
  required List<Topic> topics,
  required List<StudyItem> items,
  required Map<String, QuizResult> quizzes,
  required Map<String, DrillEvidence> drills,
  required List<Story> stories,
  required Map<String, String> storyDays,
  required List<PortfolioItem> portfolio,
  required List<Skill> skills,
  required String today,
  String? interviewDate,
  Map<String, List<Evidence>> framework = const {},
  Map<String, Dated<ScenarioAttempt>> scenarios = const {},
  Map<String, Dated<CapstoneSitting>> capstones = const {},
}) {
  final topicById = {for (final t in topics) t.id: t};
  final itemsOf = <String, List<StudyItem>>{};
  for (final i in items) {
    (itemsOf[i.topicId] ??= []).add(i);
  }
  final rows = <ReadinessRow>[];
  for (final c in criteria) {
    final ev = <Evidence>[];
    final linked = [
      for (final t in topics)
        if (criteriaRefs(t).contains(c.ref)) t,
    ];
    for (final t in linked) {
      final its = itemsOf[t.id] ?? const <StudyItem>[];
      final q = quizzes[t.id];
      // Ticked, or earned by its required items and a passed quiz.
      final doneDay = t.done ?? (topicEarned(its, quizPercent: q?.percent) ? q?.day : null);
      final status = topicStatus(t, its);
      ev.add(
        Evidence(
          kind: EvidenceKind.topic,
          title: t.title,
          detail: doneDay != null ? 'Topic done ${niceDate(doneDay)}' : 'Topic ${status.label.toLowerCase()}',
          weight: doneDay != null ? EvidenceWeight.unchecked : EvidenceWeight.planned,
          day: doneDay ?? '',
          id: t.id,
        ),
      );
      if (q != null) {
        final pass = q.exam?.passed ?? q.percent >= passPercent;
        ev.add(
          Evidence(
            kind: q.exam != null ? EvidenceKind.exam : EvidenceKind.quiz,
            title: t.title,
            detail: [
              q.exam != null
                  ? 'Exam ${_pct(q.percent)} (${pass ? 'passed' : 'not passed'}) on ${niceDate(q.day)}'
                  : 'Quiz ${_pct(q.percent)} on ${niceDate(q.day)}',
              if (pass && doneDay == null) 'topic not done yet',
            ].join(' · '),
            weight: !pass
                ? EvidenceWeight.low
                : doneDay != null
                ? EvidenceWeight.strong
                : EvidenceWeight.unchecked,
            day: q.day,
            id: t.id,
          ),
        );
      }
      for (final i in its) {
        if (i.type != 'practice task') continue;
        final shown = i.evidence.trim().isNotEmpty || i.takeaway.trim().isNotEmpty;
        ev.add(
          Evidence(
            kind: EvidenceKind.task,
            title: i.title,
            detail: i.done == null
                ? 'Practice task not done yet'
                : shown
                ? 'Task done ${niceDate(i.done!)} with evidence'
                : 'Task done ${niceDate(i.done!)}, no evidence added',
            weight: i.done == null
                ? EvidenceWeight.planned
                : shown
                ? EvidenceWeight.strong
                : EvidenceWeight.unchecked,
            day: i.done ?? '',
            id: t.id,
          ),
        );
      }
    }
    for (final i in items) {
      if (i.type != 'interview drill') continue;
      if (!drillCriteria(i, topicById[i.topicId], criteria).any((x) => x.id == c.id)) continue;
      final d = drills[i.id] ?? const DrillEvidence();
      final latest = d.latest;
      final u = d.udyoga;
      // The newer of the score here and Udyoga's (here wins a tie), as
      // DrillEvidence.latest picks it.
      final fromUdyoga = u != null && (d.own == null || u.day.compareTo(d.ownDay) > 0);
      final day = latest == null ? '' : (fromUdyoga ? u.day : d.ownDay);
      ev.add(
        Evidence(
          kind: EvidenceKind.drill,
          title: drillQuestion(i),
          detail: latest == null
              ? (d.asked ? 'Drill sent to Udyoga, no score yet' : 'Drill not practised yet')
              : [
                  'Drill ${rubricText(latest)} (${_of8(latest)}/$drillMax) on ${niceDate(day)}',
                  if (fromUdyoga) 'scored in Udyoga' else if (d.ownNote.isNotEmpty) d.ownNote,
                ].join(' · '),
          weight: latest == null
              ? EvidenceWeight.planned
              : drillWeak(latest)
              ? EvidenceWeight.low
              : EvidenceWeight.strong,
          day: day,
          id: i.id,
        ),
      );
    }
    for (final i in items) {
      if (i.type != scenarioType) continue;
      final sc = scenarioOf(i);
      if (sc == null || !sc.criteria.contains(c.ref)) continue;
      ev.add(_scenarioEvidence(i, scenarios[i.id]));
    }
    for (final i in items) {
      if (i.type != capstoneType) continue;
      final rules = capstoneRules(i);
      final course = topicById[i.topicId]?.courseId;
      if (rules == null || course == null) continue;
      final refs = {for (final r in rules.drills) r.toLowerCase()};
      final tests = items.any(
        (d) =>
            d.type == 'interview drill' &&
            refs.contains(d.ref.toLowerCase()) &&
            topicById[d.topicId]?.courseId == course &&
            drillCriteria(d, topicById[d.topicId], criteria).any((x) => x.id == c.id),
      );
      if (tests) ev.add(_capstoneEvidence(i, capstones[i.id]));
    }
    for (final s in stories) {
      if (!s.criteria.contains(c.id)) continue;
      final day = storyDays[s.id] ?? '';
      ev.add(
        Evidence(
          kind: EvidenceKind.story,
          title: s.title,
          detail: day.isEmpty ? 'Story linked' : 'Story linked, saved ${niceDate(day)}',
          weight: EvidenceWeight.unchecked,
          day: day,
          id: s.id,
        ),
      );
    }
    for (final p in portfolio) {
      if (!p.skills.split(',').any((k) => skillMatches(k, c.body))) continue;
      ev.add(
        Evidence(
          kind: EvidenceKind.portfolio,
          title: p.title,
          detail: 'Portfolio item, ${niceDate(p.day)}',
          weight: EvidenceWeight.unchecked,
          day: p.day,
          id: p.id,
        ),
      );
    }
    for (final k in skills) {
      if (!skillMatches(k.name, c.body) || k.level <= 0) continue;
      ev.add(
        Evidence(
          kind: EvidenceKind.skill,
          title: k.name,
          detail: 'Skill ${k.level} of target ${k.target}${k.level >= k.target ? ' (at target)' : ''}',
          weight: EvidenceWeight.unchecked,
          day: k.updated,
          id: k.id,
        ),
      );
    }
    // Self-ratings from the program's framework: never strong (see
    // framework.dart), so they cannot cover a row on their own.
    ev.addAll(framework[c.ref] ?? const []);
    if (c.shown == true) {
      ev.add(
        const Evidence(
          kind: EvidenceKind.cv,
          title: 'Your CV shows this',
          detail: 'From Udyoga; it does not count as evidence here',
          weight: EvidenceWeight.info,
        ),
      );
    }
    final j = judgeEvidence(ev, today);
    rows.add(ReadinessRow(criterion: c, status: j.status, evidence: ev, reasons: j.reasons));
  }
  final weakest = weakestRow(rows);
  final quizItems = <String, StudyItem>{for (final t in topics) t.id: ?topicQuiz(itemsOf[t.id] ?? const [])};
  return Readiness(
    rows: rows,
    summary: ReadinessSummary.of(rows, interviewDate: interviewDate),
    next: weakest == null ? null : nextActionFor(weakest, quizzes: quizItems, today: today),
  );
}

/// A stress test as evidence (see the library rules): planned until tried;
/// then its latest attempt, medium when passed, low otherwise.
Evidence _scenarioEvidence(StudyItem i, Dated<ScenarioAttempt>? last) {
  if (last == null) {
    return Evidence(
      kind: EvidenceKind.scenario,
      title: i.title,
      detail: 'Stress test not tried yet',
      weight: EvidenceWeight.planned,
      id: i.id,
    );
  }
  final a = last.result;
  final untouched = a.findings.untouchedHigh.length;
  return Evidence(
    kind: EvidenceKind.scenario,
    title: i.title,
    detail: [
      'Stress test ${a.passed ? 'passed' : 'not passed'} on ${niceDate(last.day)}',
      'rating ${a.of5}/5',
      if (untouched > 0) '$untouched high-risk ${untouched == 1 ? 'row' : 'rows'} untouched',
    ].join(' · '),
    weight: a.passed ? EvidenceWeight.medium : EvidenceWeight.low,
    day: last.day,
    id: i.id,
  );
}

/// A capstone as evidence for the rows its drills test: planned until sat;
/// then its latest sitting, medium when passed, low otherwise.
Evidence _capstoneEvidence(StudyItem i, Dated<CapstoneSitting>? last) {
  if (last == null) {
    return Evidence(
      kind: EvidenceKind.capstone,
      title: i.title,
      detail: 'Capstone not sat yet',
      weight: EvidenceWeight.planned,
      id: i.id,
    );
  }
  final s = last.result;
  return Evidence(
    kind: EvidenceKind.capstone,
    title: i.title,
    detail:
        'Capstone ${s.passed ? 'passed' : 'not passed'} on ${niceDate(last.day)} · '
        'average ${s.average.toStringAsFixed(1)}/5, lowest ${s.minimum}/5',
    weight: s.passed ? EvidenceWeight.medium : EvidenceWeight.low,
    day: last.day,
    id: i.id,
  );
}

// ---- the report for Udyoga ----

/// The `readiness` list added to a plan's progress report: one entry per
/// weak or missing row, in plan order, `{"criterionId", "text", "status",
/// "essential"}`. `criterionId` is the plan's id for the criterion, '' for
/// one the learner typed in; `status` is `weak` or `missing`. Covered rows
/// are left out, so an empty list means every criterion is covered.
List<Map<String, Object>> readinessReport(Readiness r) => [
  for (final row in r.rows)
    if (row.status != ReadinessStatus.covered)
      {
        'criterionId': isOwnCriterion(row.criterion) || row.criterion.ref.startsWith('text|')
            ? ''
            : row.criterion.ref,
        'text': row.criterion.body,
        'status': row.status.name,
        'essential': row.essential,
      },
];

// ---- reads and writes ----

extension JobReadiness on LearningBook {
  /// The program's readiness on [today] (see [assessReadiness]).
  Future<Readiness> readiness(String programId, {required String today}) async {
    final criteria = await programCriteria(programId);
    final (:topics, drills: _) = await programDrills(programId);
    final ids = [for (final t in topics) t.id];
    final items = ids.isEmpty
        ? <StudyItem>[]
        : await (db.select(db.learnItems)
                ..where((i) => i.topicId.isIn(ids) & i.deleted.not() & i.retired.equals(''))
                ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
              .get();
    final pos = {for (final (k, t) in topics.indexed) t.id: k};
    items.sort((a, b) => pos[a.topicId]!.compareTo(pos[b.topicId]!));
    final tests = ids.isEmpty
        ? const <Assessment>[]
        : await (db.select(db.learnAssessments)..where((a) => a.deleted.not() & a.topicId.isIn(ids))).get();
    final drillIds = [
      for (final i in items)
        if (i.type == 'interview drill') i.id,
    ];
    final storyRows = await (db.select(db.learnStories)..where((s) => s.deleted.not())).get();
    return assessReadiness(
      criteria: criteria,
      topics: topics,
      items: items,
      quizzes: latestQuizzes(tests),
      drills: await drillEvidence(drillIds),
      stories: await storyBank(),
      storyDays: {for (final s in storyRows) s.id: s.updated},
      portfolio: await (db.select(db.learnPortfolio)..where((p) => p.deleted.not())).get(),
      skills: await (db.select(db.learnSkills)..where((k) => k.deleted.not())).get(),
      today: today,
      interviewDate: await interviewDate(programId),
      framework: switch (await frameworkView(programId)) {
        final v? => frameworkReadiness(v),
        null => const {},
      },
      scenarios: latestOnItems(tests, ScenarioAttempt.parse),
      capstones: latestOnItems(tests, CapstoneSitting.parse),
    );
  }

  /// The program's exam questions seen before (see [examRepeats]).
  Future<SeenBefore> readinessRepeats(String programId) async {
    final (:topics, drills: _) = await programDrills(programId);
    final ids = [for (final t in topics) t.id];
    if (ids.isEmpty) return (repeats: 0, asked: 0);
    return examRepeats(
      await (db.select(db.learnAssessments)..where((a) => a.deleted.not() & a.topicId.isIn(ids))).get(),
    );
  }

  /// What readiness shows on [today] for the program, to keep with an
  /// outcome; null when it has no criteria.
  Future<ReadinessSnapshot?> readinessSnapshot(String programId, {required String today}) async =>
      ReadinessSnapshot.of(await readiness(programId, today: today), await readinessRepeats(programId));

  /// Adds (no [id]) or changes one of the learner's own criteria for a
  /// program, typed in from a person specification, and sets which of the
  /// program's topics work towards it. Returns its row id.
  Future<String> saveOwnCriterion(
    String programId, {
    String? id,
    required String body,
    required bool essential,
    List<String>? topicIds,
  }) => db.transaction(() async {
    final old = id == null
        ? null
        : await (db.select(db.learnCriteria)..where((c) => c.id.equals(id))).getSingleOrNull();
    final rowId = old?.id ?? newId();
    final ref = old?.ref ?? '$ownCriterionPrefix$rowId';
    final last =
        await (db.select(db.learnCriteria)
              ..where((c) => c.programId.equals(programId))
              ..orderBy([(c) => OrderingTerm.desc(c.ord)])
              ..limit(1))
            .getSingleOrNull();
    await save(
      db.learnCriteria,
      LearnCriteriaCompanion.insert(
        id: rowId,
        programId: programId,
        ref: ref,
        body: body.trim(),
        essential: Value(essential),
        source: const Value(ownCriterionSource),
        ord: Value(old?.ord ?? (last == null ? 0 : last.ord + 1)),
        deleted: const Value(false),
      ),
      rowId,
    );
    if (topicIds != null) await _linkTopics(programId, ref, topicIds.toSet());
    return rowId;
  });

  /// Deletes one of the learner's own criteria and unlinks it from topics.
  Future<void> deleteOwnCriterion(Criterion c) => db.transaction(() async {
    await remove(db.learnCriteria, c.id);
    await _linkTopics(c.programId, c.ref, const {});
  });

  /// Makes exactly [topicIds] (of the program's topics) list [ref].
  Future<void> _linkTopics(String programId, String ref, Set<String> topicIds) async {
    final (:topics, drills: _) = await programDrills(programId);
    for (final t in topics) {
      final refs = criteriaRefs(t);
      final want = topicIds.contains(t.id);
      if (want == refs.contains(ref)) continue;
      final next = want
          ? [...refs, ref]
          : [
              for (final r in refs)
                if (r != ref) r,
            ];
      await save(db.learnTopics, t.copyWith(criteria: next.join(',')), t.id);
    }
  }
}

/// The program Home shows readiness for: of the programs with criteria
/// (not finished), the one with the nearest interview still to come, else
/// the most recently started role plan, else the most recently started
/// one. Null when no program has criteria.
Program? pickReadinessProgram(
  List<Program> programs, {
  required Set<String> withCriteria,
  required Map<String, String> interviewDates,
  required String today,
}) {
  final open = [
    for (final p in programs)
      if (withCriteria.contains(p.id) && p.status != 'done') p,
  ];
  if (open.isEmpty) return null;
  final coming = [
    for (final p in open)
      if (interviewDates[p.id] case final d? when d.compareTo(today) >= 0) (p, d),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  if (coming.isNotEmpty) return coming.first.$1;
  int newest(Program a, Program b) => b.started.compareTo(a.started);
  final roles = open.where((p) => p.role.isNotEmpty).toList()..sort(newest);
  if (roles.isNotEmpty) return roles.first;
  return (open..sort(newest)).first;
}

extension ReadinessFocus on LearningBook {
  /// The program Home shows readiness for (see [pickReadinessProgram]).
  Future<Program?> readinessFocus(String today) async {
    final programs = await (db.select(db.learnPrograms)..where((p) => p.deleted.not())).get();
    final withCriteria = {
      for (final c in await (db.select(db.learnCriteria)..where((c) => c.deleted.not())).get()) c.programId,
    };
    return pickReadinessProgram(
      programs,
      withCriteria: withCriteria,
      interviewDates: {
        for (final p in programs)
          if (withCriteria.contains(p.id)) p.id: ?await interviewDate(p.id),
      },
      today: today,
    );
  }
}
