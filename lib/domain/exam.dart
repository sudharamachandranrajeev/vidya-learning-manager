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
  const ExamRules({required this.minutes, this.passPercent = 70, this.retakeDays = 0, this.shuffle = false});

  static const minMinutes = 1, maxMinutes = 300;
  static const minPass = 1, maxPass = 100;
  static const minRetakeDays = 0, maxRetakeDays = 60;

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
  /// time is 1.5 minutes a question (at least one minute).
  factory ExamRules.fromJson(Map j, {int questions = 0}) {
    int num0(Object? v, int fallback, int lo, int hi) =>
        (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? fallback).clamp(lo, hi);
    return ExamRules(
      minutes: num0(j['minutes'], (questions * 1.5).ceil(), minMinutes, maxMinutes),
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
  };

  @override
  bool operator ==(Object other) =>
      other is ExamRules &&
      other.minutes == minutes &&
      other.passPercent == passPercent &&
      other.retakeDays == retakeDays &&
      other.shuffle == shuffle;

  @override
  int get hashCode => Object.hash(minutes, passPercent, retakeDays, shuffle);
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

/// Why a score may look better than it is, or null: the pool is small
/// (no more than twice the questions asked, so they come round again and
/// may be remembered rather than known), or some questions were asked in
/// an earlier attempt.
({bool smallPool, int repeats})? seenBefore({
  required int pool,
  required int shown,
  required Iterable<String> asking,
  required Iterable<ExamResult> earlier,
}) {
  final before = {for (final r in earlier) ...r.asked};
  final repeats = asking.where(before.contains).length;
  final small = shown > 0 && pool <= shown * 2;
  if (!small && repeats == 0) return null;
  return (smallPool: small, repeats: repeats);
}

/// [seenBefore] in words for the learner.
String seenBeforeText(({bool smallPool, int repeats}) s) => [
  if (s.repeats > 0)
    '${s.repeats} of these ${s.repeats == 1 ? 'question was' : 'questions were'} in an earlier attempt.',
  if (s.smallPool) 'This exam has a small question pool, so you may have seen the questions in practice.',
  'A high score can come from remembering answers rather than knowing them.',
].join(' ');

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
