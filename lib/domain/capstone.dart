/// Capstones (assess plan A3): a set of interview drills taken back-to-back
/// in one sitting, passed on an average and a lowest score on the plan's
/// 1–5 rubric scale, and "passed N sittings in a row".
///
/// A plan puts the rules on a topic or a course (`capstone`, format 3). They
/// are kept as a study item of type `capstone` whose content is
/// [CapstoneRules.toJson]; a course's capstone sits on its last topic. A
/// sitting is kept as an assessment on that item whose detail is
/// [CapstoneSitting.encode] (kind "capstone"), so no database change. Each
/// drill answered in a sitting is also an ordinary drill attempt, so Job
/// readiness counts it.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'interview.dart';
import 'study_items.dart';

/// The study item type of a capstone.
const capstoneType = 'capstone';

/// The rules of a capstone, from a plan's `capstone` block.
class CapstoneRules {
  const CapstoneRules({
    required this.drills,
    this.average = defaultAverage,
    this.minimum = defaultMinimum,
    this.passesInRow = 1,
    this.minutes,
    this.course = false,
  });

  static const defaultAverage = 4.0, defaultMinimum = 3;
  static const maxDrills = 12;
  static const minScore = 1, maxScore = 5;
  static const minPasses = 1, maxPasses = 10;
  static const minMinutes = 5, maxMinutes = 300;

  /// The drills' plan refs (their `id`, else the ref made from the
  /// question), in the order they are asked.
  final List<String> drills;

  /// The lowest average, on the 1–5 scale, that passes (1.0–5.0).
  final double average;

  /// No drill may score under this (1–5).
  final int minimum;

  /// Sittings to pass in a row before the capstone counts as done (1–10).
  final int passesInRow;

  /// The time for the whole sitting; null for none. The clock is shown and
  /// the time noted, but it never stops the sitting.
  final int? minutes;

  /// Set by the course rather than one topic.
  final bool course;

  /// Reads stored or plan rules. [drills] are already resolved to refs;
  /// numbers are held to their ranges as the plan's other numbers are, and
  /// a value that is not a number takes its default.
  factory CapstoneRules.fromJson(Map j, {List<String>? drills}) {
    num? n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
    final avg = n(j['average']);
    final min = n(j['minimum']), row = n(j['passesInRow']), time = n(j['minutes']);
    return CapstoneRules(
      drills:
          drills ??
          [
            for (final d in j['drills'] is List ? j['drills'] as List : const [])
              if (d is String && d.isNotEmpty) d,
          ].take(maxDrills).toList(),
      average: avg == null ? defaultAverage : ((avg.clamp(minScore, maxScore) * 10).round() / 10).toDouble(),
      minimum: min == null ? defaultMinimum : min.round().clamp(minScore, maxScore),
      passesInRow: row == null ? 1 : row.round().clamp(minPasses, maxPasses),
      minutes: time?.round().clamp(minMinutes, maxMinutes),
      course: j['course'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'drills': drills,
    'average': average,
    'minimum': minimum,
    'passesInRow': passesInRow,
    'minutes': ?minutes,
    if (course) 'course': true,
  };

  /// "average 4.0/5 or more · none under 3/5 · pass 2 in a row · 45 min".
  String get summary => [
    'average ${average.toStringAsFixed(1)}/5 or more',
    'none under $minimum/5',
    if (passesInRow > 1) 'pass $passesInRow in a row',
    if (minutes != null) '$minutes min',
  ].join(' · ');
}

/// The capstone rules an item holds, or null when it is not a capstone.
CapstoneRules? capstoneRules(StudyItem i) {
  if (i.type != capstoneType) return null;
  final r = CapstoneRules.fromJson(itemContent(i));
  return r.drills.isEmpty ? null : r;
}

/// A plan's `capstone` block as rules, its `drills` matched against
/// [drillRefs] (lower-case plan id or question to the drill's ref) and kept
/// in order, once each; unknown ones are left out. Null when it is not an
/// object or no drill is known.
CapstoneRules? planCapstone(Object? v, Map<String, String> drillRefs, {bool course = false}) {
  if (v is! Map) return null;
  final drills = <String>[];
  for (final d in v['drills'] is List ? v['drills'] as List : const []) {
    final ref = d is String || d is num ? drillRefs['$d'.trim().toLowerCase()] : null;
    if (ref != null && !drills.contains(ref)) drills.add(ref);
  }
  if (drills.isEmpty) return null;
  return CapstoneRules.fromJson({
    ...v,
    'course': course,
  }, drills: drills.take(CapstoneRules.maxDrills).toList());
}

// ---- one sitting ----

/// One drill in a sitting: its row id, its question, and its score on the
/// 0–8 drill scale (null when skipped), with the attempt it came from.
class CapstoneDrill {
  const CapstoneDrill({
    required this.id,
    required this.title,
    this.outOf8,
    this.attempt = '',
    this.persona = '',
  });

  final String id, title;
  final int? outOf8;

  /// The drill attempt (an assessment id); '' when skipped.
  final String attempt;

  /// The panel it was asked by ("challenging"), '' for the learner's own.
  final String persona;

  bool get answered => outOf8 != null;

  /// The score on the 1–5 rubric scale ([rubricOf5]); null when skipped.
  int? get of5 => outOf8 == null ? null : rubricOf5(outOf8!);

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'outOf8': ?outOf8,
    if (attempt.isNotEmpty) 'attempt': attempt,
    if (persona.isNotEmpty) 'persona': persona,
  };

  static CapstoneDrill? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return CapstoneDrill(
      id: j['id'] as String,
      title: j['title'] is String ? j['title'] as String : '',
      outOf8: j['outOf8'] is int ? (j['outOf8'] as int).clamp(0, drillMax) : null,
      attempt: j['attempt'] is String ? j['attempt'] as String : '',
      persona: j['persona'] is String ? j['persona'] as String : '',
    );
  }
}

/// The verdict on a sitting: the average and lowest score on the 1–5
/// scale over the drills answered, and whether it passes: every drill
/// answered, the average at least [CapstoneRules.average] and none under
/// [CapstoneRules.minimum]. A skipped drill fails the sitting.
({double average, int minimum, bool passed}) capstoneVerdict(
  List<CapstoneDrill> drills,
  CapstoneRules rules,
) {
  final scores = [for (final d in drills) ?d.of5];
  if (scores.isEmpty) return (average: 0, minimum: 0, passed: false);
  final average = scores.fold(0, (a, s) => a + s) / scores.length;
  final minimum = scores.reduce((a, b) => a < b ? a : b);
  final passed =
      scores.length == drills.length && average + 1e-9 >= rules.average && minimum >= rules.minimum;
  return (average: average, minimum: minimum, passed: passed);
}

/// One sitting: the drills in the order asked, the time taken, and the
/// rules it was judged by (kept, so a later plan change does not re-judge
/// it).
class CapstoneSitting {
  CapstoneSitting({required this.drills, required this.rules, this.seconds = 0});

  final List<CapstoneDrill> drills;
  final CapstoneRules rules;
  final int seconds;

  late final _v = capstoneVerdict(drills, rules);
  double get average => _v.average;
  int get minimum => _v.minimum;
  bool get passed => _v.passed;

  /// Over the sitting's time, when it had one.
  bool get overTime => rules.minutes != null && seconds > rules.minutes! * 60;

  /// The detail JSON. `kind` marks it as a capstone sitting.
  String encode() => jsonEncode({
    'kind': 'capstone',
    'drills': [for (final d in drills) d.toJson()],
    'rules': rules.toJson(),
    if (seconds > 0) 'seconds': seconds,
    'average': (average * 10).round() / 10,
    'minimum': minimum,
    'passed': passed,
  });

  /// Reads a detail, or null when it is not a capstone sitting.
  static CapstoneSitting? parse(String detail) {
    if (detail.isEmpty) return null;
    Object? j;
    try {
      j = jsonDecode(detail);
    } on FormatException {
      return null;
    }
    if (j is! Map || j['kind'] != 'capstone' || j['rules'] is! Map) return null;
    final drills = [
      for (final d in j['drills'] is List ? j['drills'] as List : const []) ?CapstoneDrill.fromJson(d),
    ];
    return CapstoneSitting(
      drills: drills,
      rules: CapstoneRules.fromJson(j['rules'] as Map),
      seconds: j['seconds'] is int ? j['seconds'] as int : 0,
    );
  }
}

/// Passes in a row at the end of [sittings] (oldest first): a fail resets
/// the count to 0.
int capstoneStreak(Iterable<CapstoneSitting> sittings) {
  var run = 0;
  for (final s in sittings) {
    run = s.passed ? run + 1 : 0;
  }
  return run;
}

/// "1 of 2 passes in a row", or "Passed" style text once complete.
String streakText(int streak, CapstoneRules rules) => streak >= rules.passesInRow
    ? (rules.passesInRow == 1 ? 'Passed' : 'Passed $streak in a row (${rules.passesInRow} needed)')
    : '$streak of ${rules.passesInRow} ${rules.passesInRow == 1 ? 'pass' : 'passes in a row'}';

// ---- reads and writes ----

extension Capstones on LearningBook {
  /// The drills [capstone] asks, in its order: the course's interview drills
  /// (not retired) whose plan ref it lists. A drill deleted since is left out.
  Future<List<StudyItem>> capstoneDrills(StudyItem capstone) async {
    final rules = capstoneRules(capstone);
    if (rules == null) return const [];
    final topic = await (db.select(
      db.learnTopics,
    )..where((t) => t.id.equals(capstone.topicId))).getSingleOrNull();
    if (topic == null) return const [];
    final topics = await (db.select(
      db.learnTopics,
    )..where((t) => t.courseId.equals(topic.courseId) & t.deleted.not())).get();
    final rows =
        await (db.select(db.learnItems)..where(
              (i) =>
                  i.topicId.isIn([for (final t in topics) t.id]) &
                  i.type.equals('interview drill') &
                  i.deleted.not() &
                  i.retired.equals(''),
            ))
            .get();
    final byRef = {for (final r in rows) r.ref.toLowerCase(): r};
    return [for (final ref in rules.drills) ?byRef[ref.toLowerCase()]];
  }

  /// The sittings of [capstoneId], oldest first, with their rows.
  Future<List<(Assessment, CapstoneSitting)>> capstoneSittings(String capstoneId) async {
    final rows = await (db.select(
      db.learnAssessments,
    )..where((a) => a.itemId.equals(capstoneId) & a.deleted.not())).get();
    rows.sort((a, b) {
      final d = a.day.compareTo(b.day);
      return d != 0 ? d : a.hlc.compareTo(b.hlc);
    });
    return [
      for (final r in rows)
        if (CapstoneSitting.parse(r.detail) case final s?) (r, s),
    ];
  }

  /// Saves a sitting of [capstone]: a result on its topic and course (the
  /// average on the 1–5 scale) with the sitting as its detail. Once the
  /// passes in a row reach the rule, the capstone is marked done. Returns
  /// the result's id.
  Future<String> recordCapstone(StudyItem capstone, CapstoneSitting sitting, {required String today}) =>
      db.transaction(() async {
        final topic = await (db.select(
          db.learnTopics,
        )..where((t) => t.id.equals(capstone.topicId))).getSingleOrNull();
        final id = newId();
        await save(
          db.learnAssessments,
          LearnAssessmentsCompanion.insert(
            id: id,
            courseId: Value(topic?.courseId),
            topicId: Value(topic?.id),
            itemId: Value(capstone.id),
            title: capstone.title.length > 200 ? capstone.title.substring(0, 200) : capstone.title,
            day: today,
            score: (sitting.average * 10).round() / 10,
            max: const Value(5),
            detail: Value(sitting.encode()),
            deleted: const Value(false),
          ),
          id,
        );
        final streak = capstoneStreak([for (final (_, s) in await capstoneSittings(capstone.id)) s]);
        final fresh = await (db.select(
          db.learnItems,
        )..where((i) => i.id.equals(capstone.id))).getSingleOrNull();
        if (fresh != null && fresh.done == null && streak >= sitting.rules.passesInRow) {
          await save(db.learnItems, fresh.copyWith(done: Value(today)), fresh.id);
        }
        return id;
      });
}

// ---- an unfinished sitting ----

/// The local setting that holds a capstone's [CapstoneProgress].
String capstoneProgressKey(String itemId) => 'capstone.progress.$itemId';

/// A sitting started but not finished, kept in this device's local
/// settings (never synced) like an exam in progress, so leaving the page
/// or closing the app loses nothing. The clock keeps running from [start].
class CapstoneProgress {
  const CapstoneProgress({
    required this.start,
    required this.drills,
    this.index = 0,
    this.results = const [],
    this.before = const {},
  });

  final DateTime start;

  /// The drills' row ids, fixed when the sitting started, and the one being
  /// answered.
  final List<String> drills;
  final int index;

  /// The drills already answered or skipped, in order.
  final List<CapstoneDrill> results;

  /// The attempt ids each drill had before the sitting (a newer one came
  /// from the interviewer during it).
  final Map<String, List<String>> before;

  String encode() => jsonEncode({
    'start': start.toUtc().toIso8601String(),
    'drills': drills,
    'index': index,
    'results': [for (final r in results) r.toJson()],
    'before': before,
  });

  /// Reads a saved sitting, or null when there is none or it is unreadable.
  static CapstoneProgress? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (j is! Map || j['start'] is! String || j['drills'] is! List) return null;
    final start = DateTime.tryParse(j['start'] as String);
    final drills = [
      for (final d in j['drills'] as List)
        if (d is String && d.isNotEmpty) d,
    ];
    if (start == null || drills.isEmpty) return null;
    final results = [
      for (final r in j['results'] is List ? j['results'] as List : const []) ?CapstoneDrill.fromJson(r),
    ];
    return CapstoneProgress(
      start: start.toLocal(),
      drills: drills,
      index: (j['index'] is int ? j['index'] as int : results.length).clamp(0, drills.length - 1),
      results: results.take(drills.length).toList(),
      before: {
        if (j['before'] case final Map b)
          for (final MapEntry(:key, :value) in b.entries)
            if (key is String && value is List)
              key: [
                for (final x in value)
                  if (x is String) x,
              ],
      },
    );
  }

  /// "Drill 2 of 3 · 12:30 so far".
  String summary(DateTime now) {
    final s = now.difference(start).inSeconds.clamp(0, 1 << 31);
    return 'drill ${index + 1} of ${drills.length} · ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} so far';
  }
}
