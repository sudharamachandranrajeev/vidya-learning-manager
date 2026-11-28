import 'dart:math' as math;

import 'package:brahma_core/brahma_core.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

import '../db/database.dart';

/// How well a card was remembered.
enum Grade {
  again('Again'),
  hard('Hard'),
  good('Good'),
  easy('Easy');

  const Grade(this.label);
  final String label;
}

/// A card's schedule after one review.
typedef Schedule = ({int interval, double ease, int reps, int lapses, String due});

/// How hard the schedule works: one named choice instead of raw ease and
/// interval settings. It stretches or shrinks every gap after a remembered
/// card; a forgotten card comes back the same day whatever the pace.
enum ReviewPace {
  light(
    'Light',
    'Longer gaps, fewer reviews a day. For keeping up with little time; you will forget a little more.',
    1.4,
  ),
  standard('Standard', 'The usual spacing: each card returns just before you would forget it.', 1),
  intensive(
    'Intensive',
    'Shorter gaps, more reviews a day. Before an exam, or for things you must not forget.',
    0.7,
  );

  const ReviewPace(this.label, this.about, this.factor);
  final String label, about;
  final double factor;

  static ReviewPace named(String? name) => values.firstWhere((p) => p.name == name, orElse: () => standard);
}

/// Which algorithm spaces the reviews. A synced choice (see
/// `LearningBook.reviewScheduler`), so every device schedules alike.
enum ReviewScheduler {
  fsrs(
    'FSRS (recommended)',
    'Models how strong each memory is from all your past grades, and brings a card back when you '
        'are about 90% likely to still remember it. Fewer reviews for the same recall.',
  ),
  sm2(
    'SM-2 (classic)',
    'The older rule: each Good multiplies the gap by the card\'s ease. Simple and predictable.',
  );

  const ReviewScheduler(this.label, this.about);
  final String label, about;

  /// FSRS unless SM-2 was picked.
  static ReviewScheduler named(String? name) => name == sm2.name ? sm2 : fsrs;
}

/// The next schedule for [c] graded [g] on [today], by [scheduler]. A
/// forgotten card comes back today either way; a remembered one waits as
/// the algorithm says, scaled by the [pace]. FSRS reads the card's past
/// grades from [history] (see [memoryState]); SM-2 needs only the card.
/// Either way SM-2's ease, reps and lapses are kept up to date, so
/// switching back to SM-2 loses nothing. With [readyBy] (the card's
/// interview or exam day) the result goes through [capSchedule], so no
/// review lands on or after it.
Schedule nextSchedule(
  Flashcard c,
  Grade g,
  String today, {
  ReviewPace pace = ReviewPace.standard,
  String? readyBy,
  ReviewScheduler scheduler = ReviewScheduler.fsrs,
  List<CardReview> history = const [],
}) {
  final s = _sm2(c, g);
  final int days;
  if (scheduler == ReviewScheduler.sm2) {
    days = s.interval;
  } else {
    final m = nextMemory(memoryState(c, history), g, today);
    days = g == Grade.again ? 0 : fsrsInterval(m.stability);
  }
  final interval = days == 0 ? 0 : math.max(1, (days * pace.factor).round());
  return capSchedule(
    (interval: interval, ease: s.ease, reps: s.reps, lapses: s.lapses, due: addDays(today, interval)),
    today: today,
    readyBy: readyBy,
    slot: dueSlot(c.id),
  );
}

// ---- FSRS ----
//
// The Free Spaced Repetition Scheduler, through the `fsrs` package
// (open-spaced-repetition/dart-fsrs 2.x, MIT; FSRS-6 with its published
// default parameters, `fsrs.defaultParameters`). It is used day-granular:
// no learning or relearning steps (a forgotten card simply comes back the
// same day, as with SM-2) and no random fuzz, so a review gives the same
// result on every device.
//
// A card's memory state (stability and difficulty) is not stored: it is
// replayed from the card's review log every time. That makes switching to
// FSRS a migration that writes nothing (idempotent, and SM-2's ease and
// interval stay as they were), and keeps devices in agreement because the
// log syncs like any other row.

/// The recall probability FSRS aims for when a card comes back.
const desiredRetention = 0.9;

/// The longest gap FSRS gives, in days.
const fsrsMaxInterval = 36500;

final _fsrs = fsrs.Scheduler(
  desiredRetention: desiredRetention,
  learningSteps: const [],
  relearningSteps: const [],
  maximumInterval: fsrsMaxInterval,
  enableFuzzing: false,
);

/// A card's FSRS memory: [stability] is the days until recall drops to
/// 90%, [difficulty] runs 1 (easy) to 10 (hard), as of [lastDay], the day
/// of its last review.
typedef MemoryState = ({double stability, double difficulty, String lastDay});

/// Days until recall of a memory with [stability] falls to
/// [desiredRetention] (the FSRS forgetting curve, R = (1 + F·t/S)^-w20).
/// At 90% it equals the stability. At least a day, at most
/// [fsrsMaxInterval].
int fsrsInterval(double stability) {
  final decay = -_fsrs.parameters[20];
  final factor = math.pow(0.9, 1 / decay) - 1;
  final days = stability / factor * (math.pow(desiredRetention, 1 / decay) - 1);
  return days.round().clamp(1, fsrsMaxInterval);
}

DateTime _utc(String day) => DateTime.parse('${day}T00:00:00Z');

/// [m] after one review graded [g] on [day]; a new card's first memory
/// when [m] is null.
MemoryState nextMemory(MemoryState? m, Grade g, String day) {
  final card = m == null
      ? fsrs.Card(cardId: 0, due: _utc(day))
      : fsrs.Card(
          cardId: 0,
          state: fsrs.State.review,
          stability: m.stability,
          difficulty: m.difficulty,
          due: _utc(day),
          lastReview: _utc(m.lastDay),
        );
  final next = _fsrs.reviewCard(card, fsrs.Rating.values[g.index], reviewDateTime: _utc(day)).card;
  return (stability: next.stability!, difficulty: next.difficulty!, lastDay: day);
}

/// [c]'s FSRS memory before its next review, replayed from [history] (its
/// reviews; other cards' are ignored), or null for a card never reviewed.
///
/// When the log holds less than the card shows (more lapses, or a longer
/// run of recalls, than were logged: reviews made before a sync finished,
/// say), the memory starts from the card itself instead: stability from
/// its current interval (at 90% retention FSRS's interval is the
/// stability) and difficulty from its SM-2 ease, dated the day its
/// interval began.
MemoryState? memoryState(Flashcard c, List<CardReview> history) {
  final log = [
    for (final r in history)
      if (r.cardId == c.id && !r.deleted && r.grade >= 0 && r.grade < Grade.values.length) r,
  ]..sort((a, b) => a.day != b.day ? a.day.compareTo(b.day) : a.hlc.compareTo(b.hlc));
  final again = Grade.again.index;
  var run = 0;
  for (final r in log.reversed) {
    if (r.grade == again) break;
    run++;
  }
  final lapses = log.where((r) => r.grade == again).length;
  if (lapses < c.lapses || run < c.reps || (log.isEmpty && c.interval > 0)) return seedMemory(c);
  MemoryState? m;
  for (final r in log) {
    m = nextMemory(m, Grade.values[r.grade], r.day);
  }
  return m;
}

/// A memory for [c] read from its SM-2 schedule alone: stability from the
/// interval (the first Again stability when it has none), difficulty from
/// the ease (2.5, the starting ease, is the middle; 1.3 the hardest).
MemoryState seedMemory(Flashcard c) => (
  stability: c.interval > 0 ? c.interval.toDouble() : _fsrs.parameters[0],
  difficulty: (5 - (c.ease - 2.5) * 25 / 6).clamp(1.0, 10.0),
  lastDay: addDays(c.due, -c.interval),
);

/// How likely [m] is still recalled on [day] (the FSRS forgetting curve).
double recallOn(MemoryState m, String day) {
  final decay = -_fsrs.parameters[20];
  final factor = math.pow(0.9, 1 / decay) - 1;
  final t = math.max(0, daysBetween(m.lastDay, day));
  return math.pow(1 + factor * t / m.stability, decay).toDouble();
}

// ---- leeches ----

/// Lapses at which a card counts as a leech: forgotten this often, it
/// probably needs rewriting or splitting rather than more reviews.
const leechLapses = 4;

/// Whether [c] is a leech. [keptAt] is its lapse count when the learner
/// last chose to keep it as it is (0 if never): it is flagged again only
/// after [leechLapses] more. A leech is never suspended.
bool isLeech(Flashcard c, {int keptAt = 0}) => c.lapses >= leechLapses && c.lapses >= keptAt + leechLapses;

// ---- the ready-by limit ----
//
// The seam every scheduler shares: work out the interval as the algorithm
// likes (SM-2 or FSRS), then pass the schedule through [capSchedule].
// Only the due day and the interval it implies change; ease, reps and
// lapses (and FSRS's memory, replayed from the log) are the algorithm's.

/// How many days before the ready-by day pulled-in reviews spread over,
/// so they do not all land on the eve.
const capWindowDays = 7;

/// A card's place in the spread (stable for a card, different across
/// cards).
int dueSlot(String cardId) => cardId.codeUnits.fold(0, (a, u) => (a * 31 + u) & 0x3fffffff);

/// [due], pulled in when it lands on or after [readyBy]: to one of the
/// last [capWindowDays] days before it (by [slot]), never today or
/// earlier. No limit when [readyBy] is null, or is less than two days
/// away (there is no day between tomorrow and it to move to), or when
/// [due] is already before it.
String capDue(String due, {required String today, String? readyBy, int slot = 0}) {
  if (readyBy == null || due.compareTo(readyBy) < 0 || readyBy.compareTo(today) <= 0) return due;
  final room = daysBetween(today, readyBy) - 1; // days from tomorrow to the eve
  if (room < 1) return due;
  final window = math.min(capWindowDays, room);
  return addDays(readyBy, -1 - slot % window);
}

/// [s] with its due day limited by [capDue], and its interval set to the
/// gap actually waited.
Schedule capSchedule(Schedule s, {required String today, String? readyBy, int slot = 0}) {
  final due = capDue(s.due, today: today, readyBy: readyBy, slot: slot);
  if (due == s.due) return s;
  return (interval: daysBetween(today, due), ease: s.ease, reps: s.reps, lapses: s.lapses, due: due);
}

/// Why [c] is due when it is, in plain words. Under FSRS the remembered
/// case speaks of memory strength, read from [history].
String dueReason(
  Flashcard c,
  String today, {
  ReviewScheduler scheduler = ReviewScheduler.sm2,
  List<CardReview> history = const [],
}) {
  final behind = c.due.compareTo(today) < 0 ? daysBetween(c.due, today) : 0;
  final overdue = behind == 0
      ? ''
      : ' It has waited $behind ${behind == 1 ? 'day' : 'days'} past that, which is fine: review it now.';
  if (c.reps == 0 && c.lapses == 0) {
    return 'A new card. New cards are due from the day they are added.$overdue';
  }
  if (c.reps == 0) {
    return 'You marked it Again last time, so it comes back the same day until you remember it '
        '(forgotten ${c.lapses} ${c.lapses == 1 ? 'time' : 'times'} so far).$overdue';
  }
  final gap = c.interval == 1 ? '1 day' : '${c.interval} days';
  final m = scheduler == ReviewScheduler.fsrs ? memoryState(c, history) : null;
  if (m != null) {
    final recall = (recallOn(m, today) * 100).round();
    return 'You have remembered it ${c.reps} ${c.reps == 1 ? 'time' : 'times'} in a row, so it waited $gap '
        'before coming back on ${niceDate(c.due)}. FSRS brings a card back when you are about '
        '${(desiredRetention * 100).round()}% likely to still remember it; today that is about $recall%. '
        'Each Good makes the memory stronger and the next gap longer; Hard and Again shorten it.$overdue';
  }
  return 'You have remembered it ${c.reps} ${c.reps == 1 ? 'time' : 'times'} in a row, so it waited $gap '
      'before coming back on ${niceDate(c.due)}. Each Good makes the next gap about '
      '${c.ease.toStringAsFixed(1)} times longer; Hard and Again shorten it.$overdue';
}

({int interval, double ease, int reps, int lapses}) _sm2(Flashcard c, Grade g) {
  var ease = c.ease, reps = c.reps, lapses = c.lapses;
  final int interval;
  switch (g) {
    case Grade.again:
      ease -= 0.2;
      reps = 0;
      lapses++;
      interval = 0;
    case Grade.hard:
      ease -= 0.15;
      interval = c.reps == 0 ? 1 : math.max(c.interval + 1, (c.interval * 1.2).round());
      reps++;
    case Grade.good:
      interval = _grown(c);
      reps++;
    case Grade.easy:
      ease += 0.15;
      interval = math.max(_grown(c) + 1, (_grown(c) * 1.3).round());
      reps++;
  }
  return (interval: interval, ease: ease.clamp(1.3, 3.0), reps: reps, lapses: lapses);
}

int _grown(Flashcard c) => switch (c.reps) {
  0 => 1,
  1 => 3,
  _ => math.max(c.interval + 1, (c.interval * c.ease).round()),
};

/// Cards with an interval this long are "mature": held in long-term memory.
const matureDays = 21;
