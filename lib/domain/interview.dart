/// Interview training (role study plan V5): practise a drill out loud
/// against a timer and rate yourself, hand a drill to Udyoga's voice
/// simulator, keep a story bank (each story shown as STAR or CAR), answer
/// scenario questions with a guided frame, review before an interview, and
/// log how a real interview went so its weak spots become study items.
///
/// Privacy: nothing here records sound. Attempts, stories and feedback logs
/// are ordinary rows, so they stay on this device or travel only through
/// the learner's own sync, and each can be deleted. Nothing is sent to any
/// other service.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'quiz.dart' show lastQuizPercents;
import 'readiness.dart';
import 'study_items.dart';

// ---- self-rating ----

/// The four checks a spoken answer is rated on, each 0 (no), 1 (partly) or
/// 2 (yes): key, label, and the question the learner asks themself.
const drillChecks = [
  ('situation', 'Situation clear', 'Could someone who was not there picture it and what was at stake?'),
  ('action', 'Own actions', 'Did you say what you did yourself ("I", not "we")?'),
  ('result', 'Result or impact', 'Did you say what changed, with a number or an example if you can?'),
  ('link', 'Linked back to the criterion', 'Did you end by tying it to what the question tests?'),
];

/// The best score: four checks of 2 each.
const drillMax = 8;

/// A drill scored under this (out of 8) is weak and comes up first in the
/// "before the interview" session.
const drillWeakBelow = 5;

/// The practice timer's default length, in seconds.
const drillDefaultSeconds = 120;

/// The total of four check ratings, each kept between 0 and 2.
int drillScore(List<int> checks) => checks.take(drillChecks.length).fold(0, (a, c) => a + c.clamp(0, 2));

/// Whether a score out of 8 is weak.
bool drillWeak(num outOf8) => outOf8 < drillWeakBelow;

// ---- scenario frame ----

/// A guided answer for a scenario question ("What would you do if…"): what
/// you would check first, how you would stay within your role, when you
/// would escalate, and how you would write it down or hand it over.
class ScenarioFrame {
  const ScenarioFrame({this.check = '', this.scope = '', this.escalate = '', this.handover = ''});

  final String check, scope, escalate, handover;

  /// Each part's key and label, in the order an answer takes.
  static const parts = [
    ('check', 'What I\'d check first'),
    ('scope', 'Staying within my role\'s scope'),
    ('escalate', 'When I\'d escalate'),
    ('handover', 'How I\'d document or hand over'),
  ];

  bool get isEmpty => [check, scope, escalate, handover].every((s) => s.trim().isEmpty);

  String part(String key) => switch (key) {
    'check' => check,
    'scope' => scope,
    'escalate' => escalate,
    _ => handover,
  };

  Map<String, String> toJson() => {
    for (final (k, _) in parts)
      if (part(k).trim().isNotEmpty) k: part(k).trim(),
  };

  factory ScenarioFrame.fromJson(Object? j) {
    if (j is! Map) return const ScenarioFrame();
    String s(String k) => j[k] is String ? j[k] as String : '';
    return ScenarioFrame(
      check: s('check'),
      scope: s('scope'),
      escalate: s('escalate'),
      handover: s('handover'),
    );
  }
}

/// Whether [question] reads like a scenario ("What would you do if…",
/// "How would you handle…", "Imagine…"), so the runner offers the scenario
/// frame first. The learner can switch the frame on or off either way, and
/// a drill can say so itself with `"scenario": true` in its content.
bool isScenarioQuestion(String question) {
  final q = question.trim().toLowerCase();
  return RegExp(
        r'^(imagine|suppose|picture this|you are|you\x27re|if you|a (patient|colleague|customer|client|service user|manager)\b)',
      ).hasMatch(q) ||
      RegExp(r'\b(what would you do|how would you (handle|respond|deal|manage|approach))\b').hasMatch(q) ||
      q.contains('scenario');
}

/// Whether [drill] is a scenario question: its content says so, or its
/// question reads like one.
bool isScenarioDrill(StudyItem drill) {
  final c = itemContent(drill);
  if (c['scenario'] is bool) return c['scenario'] as bool;
  return isScenarioQuestion(drillQuestion(drill));
}

/// The drill's question: its content's `question`, else its title.
String drillQuestion(StudyItem drill) => switch (itemContent(drill)['question']) {
  final String q when q.trim().isNotEmpty => q.trim(),
  _ => drill.title,
};

// ---- one attempt ----

/// One practice of a drill: the four check ratings, the seconds used, the
/// scenario frame (empty when not used), the story used (a [Story.id], ''
/// when none) and a note. Kept as an assessment's detail (see
/// `LearnAssessments.detail`).
class DrillAttempt {
  const DrillAttempt({
    required this.checks,
    this.seconds = 0,
    this.frame = const ScenarioFrame(),
    this.story = '',
    this.note = '',
  });

  final List<int> checks;
  final int seconds;
  final ScenarioFrame frame;
  final String story;
  final String note;

  int get score => drillScore(checks);
  bool get weak => drillWeak(score);

  /// The detail JSON. `kind` marks it as a drill attempt.
  String encode() => jsonEncode({
    'kind': 'drill',
    'checks': [for (final c in checks.take(drillChecks.length)) c.clamp(0, 2)],
    if (seconds > 0) 'seconds': seconds,
    if (!frame.isEmpty) 'frame': frame.toJson(),
    if (story.isNotEmpty) 'story': story,
    if (note.trim().isNotEmpty) 'note': note.trim(),
  });

  /// Reads a detail, or null when it is not a drill attempt.
  static DrillAttempt? parse(String detail) {
    if (detail.isEmpty) return null;
    Object? j;
    try {
      j = jsonDecode(detail);
    } on FormatException {
      return null;
    }
    if (j is! Map || j['kind'] != 'drill') return null;
    return DrillAttempt(
      checks: [
        for (final c in j['checks'] is List ? j['checks'] as List : const [])
          if (c is int) c,
      ],
      seconds: j['seconds'] is int ? j['seconds'] as int : 0,
      frame: ScenarioFrame.fromJson(j['frame']),
      story: j['story'] is String ? j['story'] as String : '',
      note: j['note'] is String ? j['note'] as String : '',
    );
  }
}

// ---- Udyoga hand-off ----

/// The `bridge_study_progress` row Vidya writes to ask Udyoga to practise
/// drills in its voice simulator. Udyoga reads progress rows only by its
/// own plan ids, so today's Udyoga ignores this one; it is a request
/// Udyoga can read later (see README, "Practise in Udyoga").
const practiseRequestsId = 'vidya.practise-requests';

/// The `format` of [practiseRequestsId]'s JSON.
const practiseRequestsFormat = 'vidya-practise-requests';

/// The `bridge_study_plans` row Udyoga is to write with its simulator
/// scores, read by [parsePractiseResults]. Its format is not a Vidya plan,
/// so it is never offered as one.
const practiseResultsId = 'udyoga.practise-results';

/// The `format` of [practiseResultsId]'s JSON.
const practiseResultsFormat = 'udyoga-practise-results';

/// At most this many requests are kept, newest first.
const maxPractiseRequests = 30;

/// A drill Vidya asked Udyoga to practise.
class PractiseRequest {
  const PractiseRequest({
    required this.id,
    required this.question,
    required this.asked,
    this.ref = '',
    this.criterion = '',
    this.role = '',
    this.topic = '',
    this.story = '',
  });

  /// The drill's row id in Vidya; Udyoga's result names it back.
  final String id;

  /// The plan's id for the drill ('' for the learner's own), so Udyoga can
  /// match a drill it sent itself.
  final String ref;
  final String question;

  /// What the drill tests, in words.
  final String criterion;

  /// The job role (the program's role, else its title).
  final String role;
  final String topic;

  /// The Udyoga story id linked to the drill (from `udyoga.story.<id>`), ''
  /// when none. Only the id goes: Udyoga already holds its stories.
  final String story;

  /// When it was asked (UTC, ISO 8601).
  final String asked;

  Map<String, String> toJson() => {
    'id': id,
    if (ref.isNotEmpty) 'ref': ref,
    'question': question,
    if (criterion.isNotEmpty) 'criterion': criterion,
    if (role.isNotEmpty) 'role': role,
    if (topic.isNotEmpty) 'topic': topic,
    if (story.isNotEmpty) 'story': story,
    'asked': asked,
  };

  static PractiseRequest? fromJson(Object? j) {
    if (j is! Map) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    if (s('id').isEmpty || s('question').isEmpty) return null;
    return PractiseRequest(
      id: s('id'),
      ref: s('ref'),
      question: s('question'),
      criterion: s('criterion'),
      role: s('role'),
      topic: s('topic'),
      story: s('story'),
      asked: s('asked'),
    );
  }
}

/// The progress JSON of [practiseRequestsId]. It also holds empty
/// `learning` and `skills`, so it is a valid study progress for any reader.
String practiseRequestsJson(List<PractiseRequest> requests) => jsonEncode({
  'learning': const <Object>[],
  'skills': const <Object>[],
  'format': practiseRequestsFormat,
  'version': 1,
  'requests': [for (final r in requests.take(maxPractiseRequests)) r.toJson()],
});

/// The requests in a [practiseRequestsJson] text; unreadable ones are
/// skipped.
List<PractiseRequest> parsePractiseRequests(String text) {
  Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    return const [];
  }
  if (j is! Map || j['requests'] is! List) return const [];
  return [for (final r in j['requests'] as List) ?PractiseRequest.fromJson(r)];
}

/// A score Udyoga's voice simulator gave a drill.
class UdyogaScore {
  const UdyogaScore({required this.day, required this.score, required this.max, this.summary = ''});
  final String day;
  final num score, max;
  final String summary;

  /// The score on the 0–8 scale of the self-rating.
  double get outOf8 => max <= 0 ? 0 : score * drillMax / max;

  String get text => '${score % 1 == 0 ? score.toInt() : score}/${max % 1 == 0 ? max.toInt() : max}';
}

/// Udyoga's scores by drill row id, from its [practiseResultsId] row:
/// `{"format": "udyoga-practise-results", "version": 1, "results":
/// [{"id", "day", "score", "max", "summary"}]}`. The newest day wins per
/// drill; anything unreadable is skipped.
Map<String, UdyogaScore> parsePractiseResults(String text) {
  Object? j;
  try {
    j = jsonDecode(text);
  } on FormatException {
    return const {};
  }
  if (j is! Map || j['format'] != practiseResultsFormat || j['results'] is! List) return const {};
  final out = <String, UdyogaScore>{};
  for (final r in j['results'] as List) {
    if (r is! Map) continue;
    final id = r['id'], day = r['day'], score = r['score'], max = r['max'];
    if (id is! String || id.isEmpty || day is! String || score is! num || max is! num || max <= 0) continue;
    final had = out[id];
    if (had != null && had.day.compareTo(day) >= 0) continue;
    out[id] = UdyogaScore(
      day: day,
      score: score.clamp(0, max),
      max: max,
      summary: r['summary'] is String ? r['summary'] as String : '',
    );
  }
  return out;
}

// ---- what a drill has to show for itself ----

/// A drill's practice so far: its last self-rated score here, Udyoga's last
/// score, and whether it was handed to Udyoga.
class DrillEvidence {
  const DrillEvidence({this.own, this.ownDay = '', this.attempts = 0, this.udyoga, this.asked = false});

  /// The last self-rated score (0–8), null when never practised here.
  final int? own;
  final String ownDay;
  final int attempts;
  final UdyogaScore? udyoga;

  /// Whether it is waiting in the requests to Udyoga.
  final bool asked;

  /// The latest score on the 0–8 scale, from here or from Udyoga, whichever
  /// is newer (here wins a tie); null when never practised.
  double? get latest {
    final u = udyoga;
    if (own == null) return u?.outOf8;
    if (u == null || ownDay.compareTo(u.day) >= 0) return own!.toDouble();
    return u.outOf8;
  }

  bool get practised => latest != null;

  /// Flagged for the "before the interview" session: practised and under 5/8.
  bool get weak => latest != null && drillWeak(latest!);
}

// ---- stories ----

/// The card ref prefix of Udyoga's story cards.
const udyogaStoryPrefix = 'udyoga.story.';

/// The row id of the link row for a Udyoga story card: the same on every
/// device, so linking on two devices makes one row.
String udyogaStoryRowId(String cardRef) => 'story.${stableHash(cardRef)}';

/// One story in the bank. The four parts are stored once; [star] and [car]
/// are two views of the same text.
class Story {
  const Story({
    required this.id,
    required this.title,
    this.situation = '',
    this.task = '',
    this.action = '',
    this.result = '',
    this.cardRef = '',
    this.criteria = const [],
    this.drills = const [],
  });

  /// The story row's id. A Udyoga story without links yet has the id its
  /// link row will have ([udyogaStoryRowId]).
  final String id;
  final String title;
  final String situation, task, action, result;

  /// The Udyoga card it comes from, '' for the learner's own.
  final String cardRef;

  /// Criteria row ids and drill row ids it is linked to.
  final List<String> criteria, drills;

  bool get fromUdyoga => cardRef.isNotEmpty;

  /// Udyoga's own id for the story, '' for the learner's own.
  String get udyogaId => fromUdyoga ? cardRef.substring(udyogaStoryPrefix.length) : '';

  /// CAR's Context: the situation and the task together.
  String get context => [situation.trim(), task.trim()].where((s) => s.isNotEmpty).join(' ');

  /// Situation, Task, Action, Result (parts left empty are left out).
  List<(String, String)> get star => [
    for (final p in [('Situation', situation), ('Task', task), ('Action', action), ('Result', result)])
      if (p.$2.trim().isNotEmpty) (p.$1, p.$2.trim()),
  ];

  /// Context, Action, Result (parts left empty are left out).
  List<(String, String)> get car => [
    for (final p in [('Context', context), ('Action', action), ('Result', result)])
      if (p.$2.trim().isNotEmpty) (p.$1, p.$2.trim()),
  ];
}

List<String> _ids(String csv) => [
  for (final s in csv.split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

/// A learner's story row as a [Story].
Story storyOf(StoryRow r) => Story(
  id: r.id,
  title: r.title,
  situation: r.situation,
  task: r.task,
  action: r.action,
  result: r.result,
  criteria: _ids(r.criteria),
  drills: _ids(r.drills),
);

/// A Udyoga story card as a [Story]: the title from its front ("Tell your
/// story: Title (competencies)"), the four parts from its back
/// ("Situation: …" lines), and the links from its link row, if any.
Story storyFromCard(Flashcard c, {StoryRow? links}) {
  var title = c.front.trim();
  const lead = 'Tell your story:';
  if (title.startsWith(lead)) title = title.substring(lead.length).trim();
  final paren = RegExp(r'\s*\([^()]*\)$').firstMatch(title);
  if (paren != null && paren.start > 0) title = title.substring(0, paren.start).trim();
  final parts = <String, StringBuffer>{};
  String? current;
  for (final line in c.back.split('\n')) {
    final m = RegExp(r'^(Situation|Task|Action|Result):\s?(.*)$').firstMatch(line);
    if (m != null) {
      current = m[1]!;
      parts[current] = StringBuffer(m[2]!);
    } else if (current != null) {
      parts[current]!.write('\n$line');
    }
  }
  String p(String k) => parts[k]?.toString().trim() ?? '';
  return Story(
    id: udyogaStoryRowId(c.ref),
    title: title.isEmpty ? c.front : title,
    situation: p('Situation'),
    task: p('Task'),
    // A card with no labelled parts keeps its whole back as the action.
    action: parts.isEmpty ? c.back.trim() : p('Action'),
    result: p('Result'),
    cardRef: c.ref,
    criteria: links == null ? const [] : _ids(links.criteria),
    drills: links == null ? const [] : _ids(links.drills),
  );
}

// ---- before the interview ----

/// How well a criterion is evidenced: the same status Job readiness gives
/// it (see readiness.dart), so both pages agree.
typedef CriterionState = ReadinessStatus;

/// A criterion with its status, why it is weak (Job readiness's reasons)
/// and its drill and quiz scores in words.
class CriterionCheck {
  const CriterionCheck(this.criterion, this.state, this.evidence, {this.reasons = const [], this.rank = 0});
  final Criterion criterion;
  final CriterionState state;
  final List<String> evidence;
  final List<WeakReason> reasons;

  /// How weak it is, 0 the weakest ([ReadinessRow.rank]).
  final int rank;
}

/// A drill in the session, with what it tests and how it went.
class DrillStep {
  const DrillStep(this.item, this.topic, this.criterion, this.evidence);
  final StudyItem item;
  final Topic? topic;
  final Criterion? criterion;
  final DrillEvidence evidence;
}

/// The "before the interview" session for one program: weak criteria first
/// (essential before desirable, then weakest first by Job readiness's
/// rules: missing, only planned, low scores, unchecked, old), then the
/// stories linked to them, then the drills (weak ones first). Covered
/// criteria are listed apart.
class BeforeInterview {
  const BeforeInterview({
    this.weak = const [],
    this.covered = const [],
    this.stories = const [],
    this.drills = const [],
    this.interviewDate,
  });
  final List<CriterionCheck> weak, covered;
  final List<Story> stories;
  final List<DrillStep> drills;

  /// The interview day the learner set (yyyy-MM-dd), null when not set.
  final String? interviewDate;
}

/// The criteria a drill counts for: the one its content names (by ref or
/// by text), else its topic's criteria.
List<Criterion> drillCriteria(StudyItem drill, Topic? topic, List<Criterion> criteria) {
  final named = itemContent(drill)['criterion'];
  if (named is String && named.trim().isNotEmpty) {
    final n = named.trim().toLowerCase();
    final hit = criteria
        .where((c) => c.ref.toLowerCase() == n || c.body.trim().toLowerCase() == n)
        .firstOrNull;
    return hit == null ? const [] : [hit];
  }
  if (topic == null) return const [];
  final refs = criteriaRefs(topic).toSet();
  return [
    for (final c in criteria)
      if (refs.contains(c.ref)) c,
  ];
}

/// What a drill tests, in words: the matching criterion's text, else what
/// its content says, else ''.
String drillCriterionText(StudyItem drill, List<Criterion> criteria) {
  final named = itemContent(drill)['criterion'];
  if (named is! String || named.trim().isEmpty) return '';
  final n = named.trim().toLowerCase();
  return criteria.where((c) => c.ref.toLowerCase() == n).firstOrNull?.body ?? named.trim();
}

/// Builds the session from rows already read (see [BeforeInterview]).
/// [topics] are the program's topics and [drills] its interview drills, in
/// course and topic order; [evidence] is by drill id and [quizPercents] by
/// topic id. [readiness] is the program's Job readiness rows: each
/// criterion's status and order come from them, so this page and Job
/// readiness never disagree. A criterion without a row counts as missing.
BeforeInterview planBeforeInterview({
  required List<Criterion> criteria,
  required List<Topic> topics,
  required List<StudyItem> drills,
  required Map<String, DrillEvidence> evidence,
  required Map<String, int> quizPercents,
  required List<Story> stories,
  required List<ReadinessRow> readiness,
  String? interviewDate,
}) {
  final topicById = {for (final t in topics) t.id: t};
  final drillsFor = <String, List<StudyItem>>{};
  for (final d in drills) {
    for (final c in drillCriteria(d, topicById[d.topicId], criteria)) {
      (drillsFor[c.id] ??= []).add(d);
    }
  }
  final rowFor = {for (final r in readiness) r.criterion.id: r};
  final checks = <CriterionCheck>[];
  for (final c in criteria) {
    final lines = <String>[];
    for (final d in drillsFor[c.id] ?? const <StudyItem>[]) {
      final s = evidence[d.id]?.latest;
      if (s == null) continue;
      lines.add('Drill ${_outOf8(s)}/8: ${d.title}');
    }
    for (final t in topics) {
      if (!criteriaRefs(t).contains(c.ref)) continue;
      final q = quizPercents[t.id];
      if (q == null) continue;
      lines.add('Quiz $q%: ${t.title}');
    }
    final row = rowFor[c.id];
    checks.add(
      CriterionCheck(
        c,
        row?.status ?? ReadinessStatus.missing,
        lines,
        reasons: row?.reasons ?? const [],
        rank: row?.rank ?? 0,
      ),
    );
  }
  final order = {for (final (k, c) in criteria.indexed) c.id: k};
  final weak =
      [
        for (final c in checks)
          if (c.state != CriterionState.covered) c,
      ]..sort((a, b) {
        if (a.criterion.essential != b.criterion.essential) return a.criterion.essential ? -1 : 1;
        if (a.rank != b.rank) return a.rank.compareTo(b.rank);
        return order[a.criterion.id]!.compareTo(order[b.criterion.id]!);
      });
  final weakIds = {for (final c in weak) c.criterion.id};

  final seen = <String>{};
  final linked = [
    for (final c in weak)
      for (final s in stories)
        if (s.criteria.contains(c.criterion.id) && seen.add(s.id)) s,
  ];

  int rank(StudyItem d) {
    final e = evidence[d.id] ?? const DrillEvidence();
    if (e.weak) return 0;
    final onWeak = drillCriteria(d, topicById[d.topicId], criteria).any((c) => weakIds.contains(c.id));
    if (!e.practised) return onWeak ? 1 : 2;
    return 3;
  }

  final steps =
      [
        for (final (k, d) in drills.indexed)
          (
            k: k,
            rank: rank(d),
            score: evidence[d.id]?.latest ?? 0,
            step: DrillStep(
              d,
              topicById[d.topicId],
              drillCriteria(d, topicById[d.topicId], criteria).firstOrNull,
              evidence[d.id] ?? const DrillEvidence(),
            ),
          ),
      ]..sort((a, b) {
        if (a.rank != b.rank) return a.rank.compareTo(b.rank);
        if ((a.rank == 0 || a.rank == 3) && a.score != b.score) return a.score.compareTo(b.score);
        return a.k.compareTo(b.k);
      });

  return BeforeInterview(
    weak: weak,
    covered: [
      for (final c in checks)
        if (c.state == CriterionState.covered) c,
    ],
    stories: linked,
    drills: [for (final s in steps) s.step],
    interviewDate: interviewDate,
  );
}

String _outOf8(double s) => s % 1 == 0 ? '${s.toInt()}' : s.toStringAsFixed(1);

/// "Interview today", "Interview tomorrow", "Interview in 6 days",
/// "Interview was 3 days ago".
String interviewCountdown(String date, String today) {
  final days = DateTime.parse('${date}T00:00Z').difference(DateTime.parse('${today}T00:00Z')).inDays;
  return switch (days) {
    0 => 'Interview today',
    1 => 'Interview tomorrow',
    -1 => 'Interview was yesterday',
    > 1 => 'Interview in $days days',
    _ => 'Interview was ${-days} days ago',
  };
}

// ---- after a real interview ----

/// What the learner writes after a real interview.
class InterviewFeedback {
  const InterviewFeedback({
    required this.day,
    this.role = '',
    this.criteria = const [],
    this.questions = const [],
    this.notes = '',
  });

  /// The interview day (yyyy-MM-dd).
  final String day;

  /// The employer and role, in the learner's words.
  final String role;

  /// Row ids of the criteria that went badly.
  final List<String> criteria;

  /// Questions that went badly, one each.
  final List<String> questions;
  final String notes;
}

/// The tag on feedback-log notes.
const feedbackTag = 'interview feedback';

/// The topic (and course) weak spots go to when no topic of the program is
/// linked to the criterion.
const followUpsTitle = 'Interview follow-ups';

/// What logging feedback did: the note's id and the study items added.
typedef FeedbackSaved = ({String noteId, List<String> items});

String _clip(String s, int max) => s.length > max ? '${s.substring(0, max - 1)}…' : s;

/// The note text of a feedback log.
String feedbackMarkdown(InterviewFeedback f, List<Criterion> bad, List<String> followUps) {
  final out = StringBuffer('Interview on ${niceDate(f.day)}');
  if (f.role.trim().isNotEmpty) out.write(': ${f.role.trim()}');
  out.write('.\n');
  if (bad.isNotEmpty || f.questions.isNotEmpty) {
    out.write('\n## What went badly\n\n');
    for (final c in bad) {
      out.write('- Criterion: ${c.body}\n');
    }
    for (final q in f.questions) {
      out.write('- Question: $q\n');
    }
  }
  if (f.notes.trim().isNotEmpty) out.write('\n## Notes\n\n${f.notes.trim()}\n');
  if (followUps.isNotEmpty) {
    out.write('\n## Follow-ups added\n\n');
    for (final t in followUps) {
      out.write('- $t\n');
    }
  }
  return out.toString();
}

// ---- reads and writes ----

/// Interview training on Vidya's write path.
extension InterviewTraining on LearningBook {
  /// Saves one practice of [drill]: a result linked to its topic, course
  /// and the drill itself (score out of 8, with the checks, timer, scenario
  /// frame, story and note as its detail), and the drill marked done today.
  /// Returns the result's id.
  Future<String> recordDrill(StudyItem drill, DrillAttempt attempt, {required String today}) =>
      db.transaction(() async {
        final topic = await (db.select(
          db.learnTopics,
        )..where((t) => t.id.equals(drill.topicId))).getSingleOrNull();
        final course = topic == null
            ? null
            : await (db.select(db.learnCourses)..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
        final id = newId();
        await save(
          db.learnAssessments,
          LearnAssessmentsCompanion.insert(
            id: id,
            courseId: Value(course?.id),
            topicId: Value(topic?.id),
            itemId: Value(drill.id),
            title: _clip('Drill: ${drill.title}', 200),
            day: today,
            score: attempt.score.toDouble(),
            max: const Value(drillMax * 1.0),
            detail: Value(attempt.encode()),
          ),
          id,
        );
        final fresh = await (db.select(db.learnItems)..where((i) => i.id.equals(drill.id))).getSingleOrNull();
        if (fresh != null && fresh.done != today) {
          await save(db.learnItems, fresh.copyWith(done: Value(today)), drill.id);
        }
        return id;
      });

  /// The drill's attempts, newest first.
  Future<List<Assessment>> drillAttempts(String itemId) async {
    final rows = await (db.select(
      db.learnAssessments,
    )..where((a) => a.itemId.equals(itemId) & a.deleted.not() & a.detail.equals('').not())).get();
    return rows..sort((a, b) {
      final d = b.day.compareTo(a.day);
      return d != 0 ? d : b.hlc.compareTo(a.hlc);
    });
  }

  /// Adds the learner's own drill to a topic: the question, what it tests
  /// (a criterion ref or words) and whether it is a scenario question.
  Future<String> addDrill(String topicId, String question, {String criterion = '', bool? scenario}) =>
      addItem(
        topicId,
        'interview drill',
        _clip(question.trim(), 200),
        content: jsonEncode({
          'question': question.trim(),
          if (criterion.trim().isNotEmpty) 'criterion': criterion.trim(),
          'scenario': ?scenario,
        }),
      );

  /// Each drill's practice so far, by drill id (see [DrillEvidence]).
  Future<Map<String, DrillEvidence>> drillEvidence(Iterable<String> itemIds) async {
    final ids = itemIds.toSet();
    if (ids.isEmpty) return const {};
    final rows = await (db.select(
      db.learnAssessments,
    )..where((a) => a.itemId.isIn(ids) & a.deleted.not() & a.detail.equals('').not())).get();
    final last = <String, Assessment>{};
    final count = <String, int>{};
    for (final a in rows) {
      final k = a.itemId!;
      count[k] = (count[k] ?? 0) + 1;
      final had = last[k];
      if (had == null || a.day.compareTo(had.day) > 0 || (a.day == had.day && a.hlc.compareTo(had.hlc) > 0)) {
        last[k] = a;
      }
    }
    final udyoga = await udyogaScores();
    final asked = {for (final r in await practiseRequests()) r.id};
    return {
      for (final id in ids)
        id: DrillEvidence(
          own: last[id]?.score.round(),
          ownDay: last[id]?.day ?? '',
          attempts: count[id] ?? 0,
          udyoga: udyoga[id],
          asked: asked.contains(id),
        ),
    };
  }

  // ---- Udyoga ----

  /// The drills waiting for Udyoga, newest first.
  Future<List<PractiseRequest>> practiseRequests() async {
    final row = await (db.select(
      db.bridgeStudyProgress,
    )..where((p) => p.id.equals(practiseRequestsId))).getSingleOrNull();
    return row == null || row.deleted ? const [] : parsePractiseRequests(row.progress);
  }

  /// Udyoga's simulator scores by drill id, from its results row; empty
  /// until Udyoga writes one.
  Future<Map<String, UdyogaScore>> udyogaScores() async {
    final row = await (db.select(
      db.bridgeStudyPlans,
    )..where((p) => p.id.equals(practiseResultsId))).getSingleOrNull();
    return row == null || row.deleted ? const {} : parsePractiseResults(row.plan);
  }

  /// Hands [drill] to Udyoga's voice simulator: adds it (or moves it to the
  /// top) in the [practiseRequestsId] progress row, which syncs to Udyoga
  /// like the rest of the progress. [now] is UTC ISO 8601.
  Future<PractiseRequest> askUdyogaToPractise(
    StudyItem drill, {
    required String now,
  }) => db.transaction(() async {
    final topic = await (db.select(
      db.learnTopics,
    )..where((t) => t.id.equals(drill.topicId))).getSingleOrNull();
    final course = topic == null
        ? null
        : await (db.select(db.learnCourses)..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
    final pid = course?.programId;
    final program = pid == null
        ? null
        : await (db.select(db.learnPrograms)..where((p) => p.id.equals(pid))).getSingleOrNull();
    final criteria = pid == null
        ? const <Criterion>[]
        : await (db.select(db.learnCriteria)..where((c) => c.programId.equals(pid) & c.deleted.not())).get();
    final story = (await storyBank()).where((s) => s.fromUdyoga && s.drills.contains(drill.id)).firstOrNull;
    final request = PractiseRequest(
      id: drill.id,
      ref: drill.ref,
      question: drillQuestion(drill),
      criterion: drillCriterionText(drill, criteria),
      role: program == null ? '' : (program.role.isNotEmpty ? program.role : program.title),
      topic: topic?.title ?? '',
      story: story?.udyogaId ?? '',
      asked: now,
    );
    final rest = [
      for (final r in await practiseRequests())
        if (r.id != drill.id) r,
    ];
    await save(
      db.bridgeStudyProgress,
      BridgeStudyProgressCompanion.insert(
        id: practiseRequestsId,
        progress: Value(practiseRequestsJson([request, ...rest])),
        updated: now,
        deleted: const Value(false),
      ),
      practiseRequestsId,
    );
    return request;
  });

  // ---- stories ----

  /// The story bank: the learner's own stories, then Udyoga's story cards
  /// (those still in use), each with its links. Sorted by title.
  Future<List<Story>> storyBank() async {
    final rows = await (db.select(db.learnStories)..where((s) => s.deleted.not())).get();
    final links = {
      for (final r in rows)
        if (r.ref.isNotEmpty) r.ref: r,
    };
    final cards = await (db.select(
      db.learnCards,
    )..where((c) => c.deleted.not() & c.retired.equals('') & c.ref.like('$udyogaStoryPrefix%'))).get();
    int byTitle(Story a, Story b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return [
      ...[
        for (final r in rows)
          if (r.ref.isEmpty) storyOf(r),
      ]..sort(byTitle),
      ...[for (final c in cards) storyFromCard(c, links: links[c.ref])]..sort(byTitle),
    ];
  }

  /// Adds or changes one of the learner's own stories. Returns its id.
  Future<String> saveStory({
    String? id,
    required String title,
    String situation = '',
    String task = '',
    String action = '',
    String result = '',
    List<String> criteria = const [],
    List<String> drills = const [],
    required String today,
  }) async {
    final rowId = id ?? newId();
    final old = await (db.select(db.learnStories)..where((s) => s.id.equals(rowId))).getSingleOrNull();
    await save(
      db.learnStories,
      LearnStoriesCompanion.insert(
        id: rowId,
        title: title.trim(),
        situation: Value(situation.trim()),
        task: Value(task.trim()),
        action: Value(action.trim()),
        result: Value(result.trim()),
        criteria: Value(criteria.join(',')),
        drills: Value(drills.join(',')),
        created: old?.created ?? today,
        updated: today,
        deleted: const Value(false),
      ),
      rowId,
    );
    return rowId;
  }

  /// Sets which criteria and drills [story] is linked to. A Udyoga story
  /// keeps its links in its own link row; its text stays on the card.
  Future<void> linkStory(
    Story story, {
    List<String>? criteria,
    List<String>? drills,
    required String today,
  }) async {
    final c = criteria ?? story.criteria, d = drills ?? story.drills;
    if (!story.fromUdyoga) {
      final row = await (db.select(db.learnStories)..where((s) => s.id.equals(story.id))).getSingle();
      await save(
        db.learnStories,
        row.copyWith(criteria: c.join(','), drills: d.join(','), updated: today),
        row.id,
      );
      return;
    }
    final old = await (db.select(db.learnStories)..where((s) => s.id.equals(story.id))).getSingleOrNull();
    await save(
      db.learnStories,
      LearnStoriesCompanion.insert(
        id: story.id,
        title: story.title,
        ref: Value(story.cardRef),
        criteria: Value(c.join(',')),
        drills: Value(d.join(',')),
        created: old?.created ?? today,
        updated: today,
        deleted: const Value(false),
      ),
      story.id,
    );
  }

  /// Deletes one of the learner's own stories, or a Udyoga story's links
  /// (the card itself belongs to Udyoga's plan and stays).
  Future<void> deleteStory(Story story) => remove(db.learnStories, story.id);

  // ---- interview date ----

  static String _dateKey(String programId) => 'vidya.interviewDate.$programId';

  /// The interview day set for a program (yyyy-MM-dd), null when none.
  Future<String?> interviewDate(String programId) async {
    final row = await (db.select(db.prefs)..where((p) => p.id.equals(_dateKey(programId)))).getSingleOrNull();
    return row == null || row.deleted || row.value.isEmpty ? null : row.value;
  }

  /// Sets or clears (null) the program's interview day. A synced pref, so
  /// every device counts down to the same day.
  Future<void> setInterviewDate(String programId, String? day) => save(
    db.prefs,
    PrefsCompanion.insert(id: _dateKey(programId), value: day ?? '', deleted: const Value(false)),
    _dateKey(programId),
  );

  // ---- before the interview ----

  /// The program's topics (course order, then topic order) and its interview
  /// drills still in use.
  Future<({List<Topic> topics, List<StudyItem> drills})> programDrills(String programId) async {
    final courses =
        await (db.select(db.learnCourses)
              ..where((c) => c.programId.equals(programId) & c.deleted.not())
              ..orderBy([(c) => OrderingTerm.asc(c.added), (c) => OrderingTerm.asc(c.id)]))
            .get();
    final topics = <Topic>[];
    for (final c in courses) {
      topics.addAll(
        await (db.select(db.learnTopics)
              ..where((t) => t.courseId.equals(c.id) & t.deleted.not())
              ..orderBy([(t) => OrderingTerm.asc(t.ord), (t) => OrderingTerm.asc(t.id)]))
            .get(),
      );
    }
    final ids = [for (final t in topics) t.id];
    final items = ids.isEmpty
        ? const <StudyItem>[]
        : await (db.select(db.learnItems)
                ..where(
                  (i) =>
                      i.topicId.isIn(ids) &
                      i.deleted.not() &
                      i.type.equals('interview drill') &
                      i.retired.equals(''),
                )
                ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
              .get();
    final pos = {for (final (k, t) in topics.indexed) t.id: k};
    final drills = items.toList()..sort((a, b) => pos[a.topicId]!.compareTo(pos[b.topicId]!));
    return (topics: topics, drills: drills);
  }

  /// The program's criteria in order.
  Future<List<Criterion>> programCriteria(String programId) =>
      (db.select(db.learnCriteria)
            ..where((c) => c.programId.equals(programId) & c.deleted.not())
            ..orderBy([(c) => OrderingTerm.asc(c.ord), (c) => OrderingTerm.asc(c.id)]))
          .get();

  /// The "before the interview" session for a program on [day] (today on
  /// this device when not given; see [planBeforeInterview]).
  Future<BeforeInterview> beforeInterview(String programId, {String? day}) async {
    final (:topics, :drills) = await programDrills(programId);
    final tests = await (db.select(db.learnAssessments)..where((a) => a.deleted.not())).get();
    return planBeforeInterview(
      criteria: await programCriteria(programId),
      topics: topics,
      drills: drills,
      evidence: await drillEvidence(drills.map((d) => d.id)),
      quizPercents: lastQuizPercents(tests),
      stories: await storyBank(),
      readiness: (await readiness(programId, today: day ?? today())).rows,
      interviewDate: await interviewDate(programId),
    );
  }

  // ---- after a real interview ----

  /// Logs how a real interview went as a note (tagged
  /// [feedbackTag], so it syncs like any other note and nowhere else), and
  /// turns each criterion that went badly into an interview drill on a
  /// topic linked to it; with no such topic, on an "Interview follow-ups"
  /// topic (made once, in a course of the same name). Questions that went
  /// badly become drills there too.
  Future<FeedbackSaved> logInterviewFeedback(
    String programId,
    InterviewFeedback f, {
    required String today,
  }) => db.transaction(() async {
    final criteria = await programCriteria(programId);
    final bad = [
      for (final c in criteria)
        if (f.criteria.contains(c.id)) c,
    ];
    final (:topics, drills: _) = await programDrills(programId);
    String? followUps;
    Future<String> followUpTopic(List<String> refs) async {
      followUps ??= topics.where((t) => t.title == followUpsTitle).firstOrNull?.id;
      if (followUps == null) {
        final course = await addCourse(followUpsTitle, today: today, programId: programId, kind: 'practice');
        followUps = await addTopic(course, followUpsTitle);
      }
      final t = await (db.select(db.learnTopics)..where((x) => x.id.equals(followUps!))).getSingle();
      final have = criteriaRefs(t);
      final more = [
        for (final r in refs)
          if (!have.contains(r)) r,
      ];
      if (more.isNotEmpty) {
        await save(db.learnTopics, t.copyWith(criteria: [...have, ...more].join(',')), t.id);
      }
      return t.id;
    }

    final titles = {for (final t in topics) t.id: t.title};
    final added = <String>[], lines = <String>[];
    for (final c in bad) {
      final linked = topics
          .where((t) => t.title != followUpsTitle && criteriaRefs(t).contains(c.ref))
          .firstOrNull;
      final topicId = linked?.id ?? await followUpTopic([c.ref]);
      final q = 'Tell me about a time you showed: ${c.body}';
      final id = await addItem(
        topicId,
        'interview drill',
        _clip(q, 200),
        source: 'Interview feedback',
        content: jsonEncode({'question': q, 'criterion': c.ref}),
      );
      added.add(id);
      lines.add('${_clip(q, 200)} (on ${titles[topicId] ?? followUpsTitle})');
    }
    final questions = [
      for (final q in f.questions)
        if (q.trim().isNotEmpty) q.trim(),
    ];
    for (final q in questions) {
      final topicId = await followUpTopic(const []);
      final id = await addItem(
        topicId,
        'interview drill',
        _clip(q, 200),
        source: 'Interview feedback',
        content: jsonEncode({'question': q, if (bad.length == 1) 'criterion': bad.single.ref}),
      );
      added.add(id);
      lines.add('${_clip(q, 200)} (on $followUpsTitle)');
    }
    final noteId = newId();
    final role = f.role.trim();
    await save(
      db.learnNotes,
      LearnNotesCompanion.insert(
        id: noteId,
        title: _clip(
          'Interview feedback: ${role.isEmpty ? niceDate(f.day) : '$role (${niceDate(f.day)})'}',
          200,
        ),
        body: Value(
          feedbackMarkdown(
            InterviewFeedback(
              day: f.day,
              role: role,
              criteria: f.criteria,
              questions: questions,
              notes: f.notes,
            ),
            bad,
            lines,
          ),
        ),
        tags: const Value(feedbackTag),
        created: today,
        updated: today,
      ),
      noteId,
    );
    return (noteId: noteId, items: added);
  });
}
