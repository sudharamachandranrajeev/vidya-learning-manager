/// Exam mode for a topic quiz: the rules a plan sets (time, pass mark,
/// retake wait, shuffle), the order questions are asked in, the report card
/// at the end, the retake lock and the "seen before" warning. Plain rules;
/// nothing here writes. An attempt is kept as an assessment whose detail is
/// [ExamResult.encode] (see `LearnAssessments.detail`).
library;

import 'dart:convert';
import 'dart:math';

import 'package:brahma_core/brahma_core.dart' show addDays;

import '../db/database.dart';
import 'quiz.dart';
import 'study_items.dart';

/// The pass mark when a plan's exam sets none (the practice quiz's).
const _defaultPass = passPercent;

/// The rules of a timed exam, from a plan's `exam` block on a topic.
class ExamRules {
  const ExamRules({
    required this.minutes,
    this.passPercent = 70,
    this.retakeDays = 0,
    this.shuffle = false,
    this.count,
  });

  static const minMinutes = 1, maxMinutes = 300;
  static const minPass = 1, maxPass = 100;
  static const minRetakeDays = 0, maxRetakeDays = 60;
  static const minCount = 1, maxCount = 100;

  /// How many questions each attempt draws from the pool; null for all.
  final int? count;

  /// The time allowed; the timer never pauses.
  final int minutes;

  /// The lowest score, in percent, that passes.
  final int passPercent;

  /// Days to wait after an attempt before the next counts; 0 for none.
  final int retakeDays;

  /// Whether the questions come in a new order each attempt.
  final bool shuffle;

  Duration get time => Duration(minutes: minutes);

  /// Reads stored or plan rules, each value held to its range; a missing
  /// time is 1.5 minutes a question asked (at least one minute).
  factory ExamRules.fromJson(Map j, {int questions = 0}) {
    int num0(Object? v, int fallback, int lo, int hi) =>
        (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? fallback).clamp(lo, hi);
    final rawCount = j['count'];
    final count = rawCount is num || int.tryParse('${rawCount ?? ''}') != null
        ? num0(rawCount, maxCount, minCount, maxCount)
        : null;
    final asked = count != null && (questions == 0 || count < questions) ? count : questions;
    return ExamRules(
      count: count,
      minutes: num0(j['minutes'], (asked * 1.5).ceil(), minMinutes, maxMinutes),
      passPercent: num0(j['passPercent'], _defaultPass, minPass, maxPass),
      retakeDays: num0(j['retakeDays'], 0, minRetakeDays, maxRetakeDays),
      shuffle: j['shuffle'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'minutes': minutes,
    'passPercent': passPercent,
    'retakeDays': retakeDays,
    'shuffle': shuffle,
    'count': ?count,
  };

  /// How many questions an attempt asks from a pool of [pool].
  int askedOf(int pool) => count == null || count! > pool ? pool : count!;

  @override
  bool operator ==(Object other) =>
      other is ExamRules &&
      other.minutes == minutes &&
      other.passPercent == passPercent &&
      other.retakeDays == retakeDays &&
      other.shuffle == shuffle &&
      other.count == count;

  @override
  int get hashCode => Object.hash(minutes, passPercent, retakeDays, shuffle, count);
}

/// The exam rules of a quiz item, or null when it is a practice quiz.
ExamRules? examRules(StudyItem quiz) => switch (itemContent(quiz)['exam']) {
  final Map m => ExamRules.fromJson(m, questions: quizLength(quiz)),
  _ => null,
};

/// The order to ask [n] questions in: as written, or shuffled.
List<int> examOrder(int n, {required bool shuffle, Random? random}) {
  final order = List.generate(n, (i) => i);
  if (shuffle) order.shuffle(random ?? Random());
  return order;
}

/// The questions (indexes into [pool]) one attempt asks, in the order
/// asked. With the rules' `count`, that many are drawn: first those no
/// earlier attempt asked, then those asked longest ago (ties at random).
/// Without it, all of them. Shuffled when the rules say so; otherwise in
/// the pool's order. [earlier] are the past attempts, oldest first.
List<int> pickExamQuestions(
  List<QuizQuestion> pool,
  ExamRules rules, {
  List<ExamResult> earlier = const [],
  Random? random,
}) {
  final rnd = random ?? Random();
  final n = rules.askedOf(pool.length);
  var chosen = List.generate(pool.length, (i) => i);
  if (n < pool.length) {
    // The attempt each question was last asked in; -1 for never.
    final last = <String, int>{};
    for (final (k, r) in earlier.indexed) {
      for (final id in r.asked) {
        last[id] = k;
      }
    }
    final ids = [for (final q in pool) questionId(q)];
    chosen.shuffle(rnd);
    chosen.sort((a, b) => (last[ids[a]] ?? -1).compareTo(last[ids[b]] ?? -1));
    chosen = chosen.take(n).toList()..sort();
  }
  if (rules.shuffle) chosen.shuffle(rnd);
  return chosen;
}

/// A short id for a question, the same on every device, kept in an
/// attempt so a later one can tell which questions came before.
String questionId(QuizQuestion q) => stableHash(q.key);

/// How one topic went in an exam.
class ExamTopicScore {
  const ExamTopicScore(this.topic, this.right, this.total);
  final String topic;
  final int right, total;
  int get missed => total - right;
  int get percent => percentOf(right, total);

  Map<String, Object> toJson() => {'topic': topic, 'right': right, 'total': total};
}

/// One finished exam attempt: the report card.
class ExamResult {
  const ExamResult({
    required this.right,
    required this.total,
    required this.attempted,
    required this.seconds,
    required this.limitSeconds,
    required this.passPercent,
    this.timedOut = false,
    this.topics = const [],
    this.asked = const [],
  });

  final int right, total, attempted;

  /// Time taken, and the time allowed.
  final int seconds, limitSeconds;
  final int passPercent;

  /// The time ran out and the exam was handed in by itself.
  final bool timedOut;

  /// Per topic, in the order they first came up.
  final List<ExamTopicScore> topics;

  /// The [questionId]s asked, in the order asked.
  final List<String> asked;

  int get percent => percentOf(right, total);
  bool get passed => percent >= passPercent;

  /// The topics with a missed question, weakest first (lowest percent,
  /// then most missed), to study before the next attempt.
  List<String> get studyFirst {
    final weak = [
      for (final t in topics)
        if (t.missed > 0) t,
    ];
    weak.sort((a, b) {
      final p = a.percent.compareTo(b.percent);
      return p != 0 ? p : b.missed.compareTo(a.missed);
    });
    return [for (final t in weak) t.topic];
  }

  /// The detail JSON. `kind` marks it as an exam attempt.
  String encode() => jsonEncode({
    'kind': examKind,
    'attempted': attempted,
    'seconds': seconds,
    'limitSeconds': limitSeconds,
    'passPercent': passPercent,
    if (timedOut) 'timedOut': true,
    'topics': [for (final t in topics) t.toJson()],
    'asked': asked,
  });

  /// Reads an assessment as an exam attempt, or null when it is not one.
  static ExamResult? of(Assessment a) {
    if (!isExamDetail(a.detail)) return null;
    final j = jsonDecode(a.detail) as Map;
    int n(String k) => j[k] is num ? (j[k] as num).round() : 0;
    return ExamResult(
      right: a.score.round(),
      total: a.max.round(),
      attempted: n('attempted'),
      seconds: n('seconds'),
      limitSeconds: n('limitSeconds'),
      passPercent: j['passPercent'] is num ? (j['passPercent'] as num).round() : _defaultPass,
      timedOut: j['timedOut'] == true,
      topics: [
        for (final t in j['topics'] is List ? j['topics'] as List : const [])
          if (t is Map && t['topic'] is String && t['right'] is num && t['total'] is num)
            ExamTopicScore(t['topic'] as String, (t['right'] as num).round(), (t['total'] as num).round()),
      ],
      asked: [
        for (final x in j['asked'] is List ? j['asked'] as List : const [])
          if (x is String) x,
      ],
    );
  }
}

/// Marks an attempt. [shown] are the questions in the order asked; per
/// question, [right] says whether it was marked right and [attempted]
/// whether anything was given. A question with no `topic` counts under
/// [topicTitle] (the quiz's own topic).
ExamResult scoreExam({
  required List<QuizQuestion> shown,
  required List<bool> right,
  required List<bool> attempted,
  required int seconds,
  required ExamRules rules,
  required String topicTitle,
  bool timedOut = false,
}) {
  final n = shown.length;
  bool at(List<bool> l, int k) => k < l.length && l[k];
  final tally = <String, (int, int)>{};
  final names = <String, String>{};
  for (var k = 0; k < n; k++) {
    final name = shown[k].topic.isNotEmpty ? shown[k].topic : topicTitle;
    final key = name.trim().toLowerCase();
    names.putIfAbsent(key, () => name);
    final (r, t) = tally[key] ?? (0, 0);
    tally[key] = (r + (at(right, k) ? 1 : 0), t + 1);
  }
  final limit = rules.minutes * 60;
  return ExamResult(
    right: [for (var k = 0; k < n; k++) at(right, k)].where((x) => x).length,
    total: n,
    attempted: [for (var k = 0; k < n; k++) at(attempted, k)].where((x) => x).length,
    seconds: seconds.clamp(0, limit),
    limitSeconds: limit,
    passPercent: rules.passPercent,
    timedOut: timedOut,
    topics: [for (final e in tally.entries) ExamTopicScore(names[e.key]!, e.value.$1, e.value.$2)],
    asked: [for (final q in shown) questionId(q)],
  );
}

/// A topic's exam attempts, oldest first (by day, then as written).
List<Assessment> examAttempts(Iterable<Assessment> tests, String topicId) =>
    [
      for (final a in tests)
        if (a.topicId == topicId && !a.deleted && isExamDetail(a.detail)) a,
    ]..sort((a, b) {
      final d = a.day.compareTo(b.day);
      return d != 0 ? d : a.hlc.compareTo(b.hlc);
    });

/// The first day the next attempt counts: the last attempt's day plus the
/// rules' wait. Null when there is no wait or no attempt yet.
String? examNextDay(List<Assessment> attempts, ExamRules rules) {
  if (rules.retakeDays == 0 || attempts.isEmpty) return null;
  final last = attempts.map((a) => a.day).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  return addDays(last, rules.retakeDays);
}

/// Whether an attempt on [today] would be too early.
bool examLocked(String? nextDay, String today) => nextDay != null && today.compareTo(nextDay) < 0;

/// How much of an attempt came up before, or null when the exam asks the
/// whole pool each time (then every question repeats and it says nothing).
/// [repeats] of the [asked] questions were in an earlier attempt;
/// [smallPool] when the pool is under twice the questions drawn, so
/// questions come round again soon and may be remembered rather than known.
({bool smallPool, int repeats, int asked})? seenBefore({
  required int pool,
  required ExamRules rules,
  required Iterable<String> asking,
  required Iterable<ExamResult> earlier,
}) {
  final count = rules.count;
  if (count == null) return null;
  final before = {for (final r in earlier) ...r.asked};
  final ids = asking.toList();
  return (smallPool: pool < count * 2, repeats: ids.where(before.contains).length, asked: ids.length);
}

/// The warning before an attempt, or null when the pool is big enough.
String? smallPoolText(({bool smallPool, int repeats, int asked})? s) => s == null || !s.smallPool
    ? null
    : 'This exam draws from a small question pool, so questions come round again soon. A high score '
          'can come from remembering answers rather than knowing them.';

/// The share seen before, for the report card.
String seenBeforeText(({bool smallPool, int repeats, int asked}) s) {
  if (s.repeats == 0) return 'Every question was new to you in an exam.';
  return '${s.repeats} of ${s.asked} questions (${percentOf(s.repeats, s.asked)}%) were asked in an earlier '
      'attempt: a remembered answer can look like knowledge.';
}

/// The time left at which a screen reader is told: every five minutes,
/// then one minute, 30 and 10 seconds before the end.
bool isAnnounceMark(int secondsLeft) =>
    secondsLeft > 0 &&
    (secondsLeft % 300 == 0 || secondsLeft == 60 || secondsLeft == 30 || secondsLeft == 10);

/// The announce mark passed between two readings of the time left
/// ([before] > [now]), the lowest one when a slow frame skipped several,
/// or null. [total] itself is never announced (the start says it).
int? crossedAnnounceMark(int before, int now, {required int total}) {
  int? mark;
  for (var s = before - 1; s >= now && s > 0; s--) {
    if (s < total && isAnnounceMark(s)) mark = s;
  }
  return mark;
}

/// "5 minutes left", "1 minute left", "30 seconds left".
String timeLeftText(int seconds) {
  if (seconds >= 60 && seconds % 60 == 0) {
    final m = seconds ~/ 60;
    return '$m ${m == 1 ? 'minute' : 'minutes'} left';
  }
  if (seconds >= 60) return '${seconds ~/ 60} min ${seconds % 60} s left';
  return '$seconds ${seconds == 1 ? 'second' : 'seconds'} left';
}

/// mm:ss (or h:mm:ss) for a timer or a time taken.
String clockText(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '${m.toString().padLeft(2, '0')}:$ss';
}

/// The title an exam attempt is saved under: "Exam: Topic" for the
/// topic's "Quiz: Topic".
String examTitle(StudyItem quiz) =>
    'Exam: ${quiz.title.startsWith('Quiz: ') ? quiz.title.substring(6) : quiz.title}';

/// An exam started but not yet recorded, kept in this device's local
/// settings (never synced) so closing or killing the app loses nothing.
/// The time keeps running from [start]; [handedIn] (seconds taken) is set
/// once the timer stopped and only the learner's marking is left.
class ExamProgress {
  const ExamProgress({
    required this.start,
    required this.asked,
    required this.given,
    this.index = 0,
    this.handedIn,
    this.timedOut = false,
  });

  final DateTime start;

  /// The [questionId]s asked, in order, and what was given for each.
  final List<String> asked;
  final List<String> given;
  final int index;
  final int? handedIn;
  final bool timedOut;

  String encode() => jsonEncode({
    'start': start.toUtc().toIso8601String(),
    'asked': asked,
    'given': given,
    'index': index,
    'handedIn': ?handedIn,
    if (timedOut) 'timedOut': true,
  });

  /// Reads a saved attempt, or null when there is none or it is unreadable.
  static ExamProgress? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['start'] is! String || j['asked'] is! List) return null;
      final start = DateTime.tryParse(j['start'] as String);
      if (start == null) return null;
      final asked = [
        for (final x in j['asked'] as List)
          if (x is String) x,
      ];
      final given = [
        for (final x in j['given'] is List ? j['given'] as List : const []) x is String ? x : '',
      ];
      return ExamProgress(
        start: start.toLocal(),
        asked: asked,
        given: [for (var k = 0; k < asked.length; k++) k < given.length ? given[k] : ''],
        index: j['index'] is int ? j['index'] as int : 0,
        handedIn: j['handedIn'] is int ? j['handedIn'] as int : null,
        timedOut: j['timedOut'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  /// The pool indexes asked and what was given for each, for the
  /// questions still in [pool] (one deleted since is left out), or null
  /// when none are left.
  ({List<int> order, List<String> given})? against(List<QuizQuestion> pool) {
    final at = {for (final (i, q) in pool.indexed) questionId(q): i};
    final order = <int>[], kept = <String>[];
    for (final (k, id) in asked.indexed) {
      final i = at[id];
      if (i == null) continue;
      order.add(i);
      kept.add(given[k]);
    }
    return order.isEmpty ? null : (order: order, given: kept);
  }
}

/// The local setting that holds a quiz's [ExamProgress].
String examProgressKey(String quizId) => 'exam.progress.$quizId';
