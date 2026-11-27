/// Stress tests (assess plan A5): a scenario item holds a brief and a
/// made-up data table (a workqueue, an inbox, a list of jobs). The learner
/// has a fixed time, which never pauses, to pick an action for each row
/// with a one-line reason. Then automatic checks (high-risk rows left
/// untouched, rows whose expected action was given), and a self-rating on
/// four checks (0–8, shown on the 1–5 rubric scale).
///
/// A plan carries one as a topic item of type `scenario` (format 3); its
/// content is [Scenario.toJson]. An attempt is kept as an assessment on the
/// item whose detail is [ScenarioAttempt.encode] (kind "scenario"), so no
/// database change. The item is done once an attempt leaves no high-risk
/// row untouched and rates itself at least [scenarioPassOutOf8] of 8.
///
/// A row's risk, expected action and model answer are hidden while the
/// clock runs and shown with the result.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'interview.dart' show drillScore, drillWeakBelow, rubricOf5;
import 'study_items.dart';

/// The study item type of a stress test.
const scenarioType = 'scenario';

/// The detail `kind` of a stress-test attempt.
const scenarioKind = 'scenario';

/// The actions a row can take when the plan gives none.
const defaultScenarioActions = ['act', 'escalate', 'leave', 'note'];

/// The risk levels a row may carry.
const scenarioRisks = ['high', 'medium', 'low'];

/// The lowest self-rating, out of 8, that can mark a stress test done (the
/// drills' "not weak" line: 4/5 on the rubric scale).
const scenarioPassOutOf8 = drillWeakBelow;

/// One row of the table: its cells (one per column), and what the plan
/// knows about it: `risk` (high, medium, low or ''), `expect` (one of the
/// actions, or '') and `why` (a model answer, or '').
class ScenarioRow {
  const ScenarioRow({required this.cells, this.risk = '', this.expect = '', this.why = ''});
  final List<String> cells;
  final String risk, expect, why;

  bool get high => risk == 'high';

  Map<String, Object> toJson() => {
    'cells': cells,
    if (risk.isNotEmpty) 'risk': risk,
    if (expect.isNotEmpty) 'expect': expect,
    if (why.isNotEmpty) 'why': why,
  };
}

/// A stress test, from a plan item or a stored one.
class Scenario {
  const Scenario({
    required this.columns,
    required this.rows,
    this.brief = '',
    this.minutes = defaultMinutes,
    this.actions = defaultScenarioActions,
    this.rubric = '',
    this.criteria = const [],
  });

  static const maxRows = 60, maxColumns = 8, maxCell = 200;
  static const minMinutes = 5, maxMinutes = 180, defaultMinutes = 20;
  static const maxActions = 8, maxAction = 40;
  static const maxBrief = 4000, maxWhy = 1000, maxCriteria = 20;

  final String brief, rubric;
  final List<String> columns, actions, criteria;
  final List<ScenarioRow> rows;
  final int minutes;

  /// The rows marked high risk, by index.
  List<int> get highRows => [
    for (final (i, r) in rows.indexed)
      if (r.high) i,
  ];

  /// Reads a plan item or stored content. Text is trimmed and cut to its
  /// limit; the first [maxColumns] columns and [maxRows] rows are kept;
  /// `minutes` is held to 5–180 (20 when missing); a `risk` that is not
  /// high, medium or low, and an `expect` that is not one of the actions,
  /// are left out. Fewer than two actions take the defaults. Null when no
  /// column or no row is left.
  static Scenario? fromJson(Object? j) {
    if (j is! Map) return null;
    String s(Object? v, int max) {
      if (v is! String && v is! num) return '';
      final t = '$v'.trim();
      return t.length > max ? t.substring(0, max) : t;
    }

    final columns = [
      for (final c in j['columns'] is List ? j['columns'] as List : const [])
        if (s(c, maxCell) case final t when t.isNotEmpty) t,
    ].take(maxColumns).toList();
    if (columns.isEmpty) return null;
    final actions = <String>[];
    for (final a in j['actions'] is List ? j['actions'] as List : const []) {
      final t = s(a, maxAction).toLowerCase();
      if (t.isNotEmpty && !actions.contains(t) && actions.length < maxActions) actions.add(t);
    }
    final acts = actions.length < 2 ? defaultScenarioActions : actions;
    final rows = <ScenarioRow>[];
    for (final r in j['rows'] is List ? j['rows'] as List : const []) {
      if (rows.length >= maxRows) break;
      final raw = r is Map ? r['cells'] : r;
      if (raw is! List) continue;
      final cells = [for (var k = 0; k < columns.length; k++) k < raw.length ? s(raw[k], maxCell) : ''];
      if (cells.every((c) => c.isEmpty)) continue;
      final m = r is Map ? r : const {};
      final risk = s(m['risk'], 10).toLowerCase();
      final expect = s(m['expect'], maxAction).toLowerCase();
      rows.add(
        ScenarioRow(
          cells: cells,
          risk: scenarioRisks.contains(risk) ? risk : '',
          expect: acts.contains(expect) ? expect : '',
          why: s(m['why'], maxWhy),
        ),
      );
    }
    if (rows.isEmpty) return null;
    final time = j['minutes'];
    final mins = time is num ? time : num.tryParse('${time ?? ''}');
    return Scenario(
      columns: columns,
      rows: rows,
      brief: s(j['brief'], maxBrief),
      minutes: mins == null ? defaultMinutes : mins.round().clamp(minMinutes, maxMinutes),
      actions: List.unmodifiable(acts),
      rubric: s(j['rubric'], maxBrief),
      criteria: [
        for (final c in j['criteria'] is List ? j['criteria'] as List : const [])
          if (s(c, 60).replaceAll(',', ' ') case final t when t.isNotEmpty) t,
      ].take(maxCriteria).toList(),
    );
  }

  Map<String, Object> toJson() => {
    if (brief.isNotEmpty) 'brief': brief,
    'minutes': minutes,
    'columns': columns,
    'rows': [for (final r in rows) r.toJson()],
    'actions': actions,
    if (rubric.isNotEmpty) 'rubric': rubric,
    if (criteria.isNotEmpty) 'criteria': criteria,
  };

  /// "12 rows · 20 min".
  String get summary => '${rows.length} ${rows.length == 1 ? 'row' : 'rows'} · $minutes min';
}

/// The stress test an item holds, or null when it is not one.
Scenario? scenarioOf(StudyItem i) => i.type == scenarioType ? Scenario.fromJson(itemContent(i)) : null;

/// "Escalate" for "escalate".
String actionLabel(String a) => a.isEmpty ? a : a[0].toUpperCase() + a.substring(1);

// ---- the checks ----

/// The four checks a stress test is rated on, each 0 (no), 1 (partly) or
/// 2 (yes), scored as a drill is (0–8, [drillScore]).
const scenarioChecks = [
  ('risk', 'Risks first', 'Did you find and deal with the rows that could do harm before the rest?'),
  (
    'order',
    'Sensible priorities',
    'Would a senior colleague agree with the order and the actions you chose?',
  ),
  ('reasons', 'Reasons recorded', 'Could someone picking up your work see why you chose each action?'),
  ('rubric', 'Met the rubric', 'Did your work meet what the rubric asks for?'),
];

/// What the automatic checks found: the high-risk rows with no action, the
/// rows whose expected action was matched or not, and how many rows took
/// each action ('' for none).
typedef ScenarioFindings = ({
  List<int> untouchedHigh,
  List<int> matched,
  List<int> mismatched,
  Map<String, int> counts,
});

/// The automatic checks on [picks] (an action per row, '' for none).
ScenarioFindings scenarioFindings(Scenario s, List<String> picks) {
  String pick(int i) => i < picks.length ? picks[i] : '';
  final untouched = <int>[], matched = <int>[], mismatched = <int>[];
  final counts = {for (final a in s.actions) a: 0, '': 0};
  for (final (i, r) in s.rows.indexed) {
    final p = pick(i);
    counts[p] = (counts[p] ?? 0) + 1;
    if (r.high && p.isEmpty) untouched.add(i);
    if (r.expect.isNotEmpty) (p == r.expect ? matched : mismatched).add(i);
  }
  return (untouchedHigh: untouched, matched: matched, mismatched: mismatched, counts: counts);
}

// ---- one attempt ----

/// One attempt: the scenario as it was taken (kept, so a later plan change
/// does not re-judge it), the action and reason per row, the time taken and
/// the self-rating.
class ScenarioAttempt {
  ScenarioAttempt({
    required this.scenario,
    required this.picks,
    required this.reasons,
    required this.checks,
    this.seconds = 0,
    this.timedOut = false,
  });

  final Scenario scenario;
  final List<String> picks, reasons;
  final List<int> checks;
  final int seconds;
  final bool timedOut;

  late final ScenarioFindings findings = scenarioFindings(scenario, picks);

  /// The self-rating, 0–8.
  int get outOf8 => drillScore(checks);

  /// The self-rating on the 1–5 rubric scale.
  int get of5 => rubricOf5(outOf8);

  /// Done: no high-risk row untouched and a self-rating of at least
  /// [scenarioPassOutOf8].
  bool get passed => findings.untouchedHigh.isEmpty && outOf8 >= scenarioPassOutOf8;

  int get touched => picks.where((p) => p.isNotEmpty).length;

  String encode() => jsonEncode({
    'kind': scenarioKind,
    'scenario': scenario.toJson(),
    'picks': picks,
    'reasons': reasons,
    'checks': checks,
    'outOf8': outOf8,
    if (seconds > 0) 'seconds': seconds,
    if (timedOut) 'timedOut': true,
    'untouchedHigh': findings.untouchedHigh.length,
    'matched': findings.matched.length,
    'mismatched': findings.mismatched.length,
    'passed': passed,
  });

  /// Reads a detail, or null when it is not a stress-test attempt.
  static ScenarioAttempt? parse(String detail) {
    if (detail.isEmpty) return null;
    Object? j;
    try {
      j = jsonDecode(detail);
    } on FormatException {
      return null;
    }
    if (j is! Map || j['kind'] != scenarioKind) return null;
    final s = Scenario.fromJson(j['scenario']);
    if (s == null) return null;
    List<String> strings(Object? v) => [
      for (var k = 0; k < s.rows.length; k++)
        v is List && k < v.length && v[k] is String ? v[k] as String : '',
    ];
    return ScenarioAttempt(
      scenario: s,
      picks: [for (final p in strings(j['picks'])) s.actions.contains(p) ? p : ''],
      reasons: strings(j['reasons']),
      checks: [
        for (final c in j['checks'] is List ? j['checks'] as List : const [])
          if (c is int) c.clamp(0, 2),
      ].take(scenarioChecks.length).toList(),
      seconds: j['seconds'] is int ? j['seconds'] as int : 0,
      timedOut: j['timedOut'] == true,
    );
  }
}

/// A stress test started but not yet saved, kept in this device's local
/// settings (never synced), as an exam's is, so closing or killing the app
/// loses nothing. The time keeps running from [start]; [handedIn] (seconds
/// taken) is set once the clock stopped and only the rating is left.
class ScenarioProgress {
  const ScenarioProgress({
    required this.start,
    required this.picks,
    required this.reasons,
    this.handedIn,
    this.timedOut = false,
  });

  final DateTime start;
  final List<String> picks, reasons;
  final int? handedIn;
  final bool timedOut;

  String encode() => jsonEncode({
    'start': start.toUtc().toIso8601String(),
    'picks': picks,
    'reasons': reasons,
    'handedIn': ?handedIn,
    if (timedOut) 'timedOut': true,
  });

  /// Reads saved progress for a table of [rows] rows, or null when there is
  /// none or it is unreadable.
  static ScenarioProgress? parse(String? raw, int rows) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['start'] is! String) return null;
      final start = DateTime.tryParse(j['start'] as String);
      if (start == null) return null;
      List<String> strings(Object? v) => [
        for (var k = 0; k < rows; k++) v is List && k < v.length && v[k] is String ? v[k] as String : '',
      ];
      return ScenarioProgress(
        start: start.toLocal(),
        picks: strings(j['picks']),
        reasons: strings(j['reasons']),
        handedIn: j['handedIn'] is int ? j['handedIn'] as int : null,
        timedOut: j['timedOut'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}

/// The local setting that holds a stress test's [ScenarioProgress].
String scenarioProgressKey(String itemId) => 'scenario.progress.$itemId';

// ---- reads and writes ----

extension Scenarios on LearningBook {
  /// The attempts of [itemId], oldest first, with their rows.
  Future<List<(Assessment, ScenarioAttempt)>> scenarioAttempts(String itemId) async {
    final rows = await (db.select(
      db.learnAssessments,
    )..where((a) => a.itemId.equals(itemId) & a.deleted.not())).get();
    rows.sort((a, b) {
      final d = a.day.compareTo(b.day);
      return d != 0 ? d : a.hlc.compareTo(b.hlc);
    });
    return [
      for (final r in rows)
        if (ScenarioAttempt.parse(r.detail) case final s?) (r, s),
    ];
  }

  /// Saves an attempt of [item]: a result on its topic and course (the
  /// self-rating on the 1–5 scale) with the attempt as its detail. A passed
  /// attempt marks the item done. Returns the result's id.
  Future<String> recordScenario(StudyItem item, ScenarioAttempt attempt, {required String today}) =>
      db.transaction(() async {
        final topic = await (db.select(
          db.learnTopics,
        )..where((t) => t.id.equals(item.topicId))).getSingleOrNull();
        final id = newId();
        await save(
          db.learnAssessments,
          LearnAssessmentsCompanion.insert(
            id: id,
            courseId: Value(topic?.courseId),
            topicId: Value(topic?.id),
            itemId: Value(item.id),
            title: item.title.length > 200 ? item.title.substring(0, 200) : item.title,
            day: today,
            score: attempt.of5.toDouble(),
            max: const Value(5),
            detail: Value(attempt.encode()),
            deleted: const Value(false),
          ),
          id,
        );
        final fresh = await (db.select(db.learnItems)..where((i) => i.id.equals(item.id))).getSingleOrNull();
        if (fresh != null && fresh.done == null && attempt.passed) {
          await save(db.learnItems, fresh.copyWith(done: Value(today)), fresh.id);
        }
        return id;
      });
}
