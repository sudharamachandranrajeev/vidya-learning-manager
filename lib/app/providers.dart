import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../domain/achievements.dart';
import '../domain/next_up.dart';
import '../domain/quiz.dart';
import '../domain/resources.dart';
import '../domain/review.dart';
import '../domain/stats.dart';
import '../domain/time_fit.dart';
import '../domain/udyoga_link.dart';
import '../ui/hints.dart';
import 'session.dart';

/// The open session; main() overrides this before the first frame.
final sessionProvider = Provider<AppSession>((ref) => throw StateError('No session'));

/// What main() and the tests override: the session, under both its Vidya
/// and its shared type, and the app's identity and hints.
List<Override> vidyaOverrides(AppSession session) => [
  sessionProvider.overrideWithValue(session),
  coreSessionProvider.overrideWithValue(session),
  appIdentityProvider.overrideWithValue(vidyaIdentity),
  hintTextsProvider.overrideWithValue({...coreHints, ...vidyaHints}),
  sentinelChecksProvider.overrideWithValue([...coreChecks, lockCheck]),
];

/// Whether streaks are shown: the days-in-a-row count on Home, Progress and
/// the suite summary. Off until the learner opts in, so nothing nags about a
/// broken chain. Achievements are unaffected. Device-only.
class ShowStreaks extends AsyncNotifier<bool> {
  static const _key = 'ui.streaks';

  @override
  Future<bool> build() async => await ref.watch(sessionProvider).db.localSetting(_key) == 'on';

  Future<void> set(bool on) async {
    state = AsyncData(on);
    await ref.read(sessionProvider).db.setLocalSetting(_key, on ? 'on' : 'off');
  }
}

final showStreaksProvider = AsyncNotifierProvider<ShowStreaks, bool>(ShowStreaks.new);

/// How hard the flashcard schedule works (see [ReviewPace]). Device-only,
/// like the other Settings choices; cards keep the gaps they already have.
class Pace extends AsyncNotifier<ReviewPace> {
  static const _key = 'review.pace';

  @override
  Future<ReviewPace> build() async =>
      ReviewPace.named(await ref.watch(sessionProvider).db.localSetting(_key));

  Future<void> set(ReviewPace pace) async {
    state = AsyncData(pace);
    await ref.read(sessionProvider).db.setLocalSetting(_key, pace.name);
  }
}

final reviewPaceProvider = AsyncNotifierProvider<Pace, ReviewPace>(Pace.new);

/// Achievements reached by the latest write, waiting to be celebrated.
class Celebrations extends Notifier<List<Achievement>> {
  @override
  List<Achievement> build() => const [];
  void add(List<Achievement> a) => state = [...state, ...a];
  void clear() => state = const [];
}

final celebrationsProvider = NotifierProvider<Celebrations, List<Achievement>>(Celebrations.new);

/// Progress back to Udyoga, at most once per ten minutes (see
/// [ProgressReporter]).
final progressReporterProvider = Provider<ProgressReporter>((ref) {
  final book = ref.watch(sessionProvider).book;
  final r = ProgressReporter((now) => book.reportToUdyoga(now: now));
  ref.onDispose(r.dispose);
  return r;
});

extension Mutate on WidgetRef {
  /// Runs a write, refreshes the screens, queues a sync, and unlocks any
  /// achievement the write earned. Progress for Udyoga follows through the
  /// reporter; a review grade passes [report] false, as the session's end
  /// reports for all its grades at once.
  Future<T> mutate<T>(Future<T> Function(AppSession s) write, {bool report = true}) async {
    final s = read(sessionProvider);
    final result = await write(s);
    final fresh = await s.book.unlockNew(today());
    if (fresh.isNotEmpty) read(celebrationsProvider.notifier).add(fresh);
    if (report) unawaited(read(progressReporterProvider).request());
    changed();
    return result;
  }
}

/// The rows of [table] that are not deleted, re-read after every write.
FutureProvider<List<D>> _rows<T extends SyncedRow, D>(
  TableInfo<T, D> Function(AppDatabase db) table, {
  List<OrderingTerm Function(T t)> orderBy = const [],
}) => FutureProvider<List<D>>((ref) {
  ref.watch(revisionProvider);
  final db = ref.watch(sessionProvider).db;
  final q = db.select(table(db))
    ..where((t) => t.deleted.not())
    ..orderBy(orderBy);
  return q.get();
});

final programsProvider = _rows<$LearnProgramsTable, Program>(
  (db) => db.learnPrograms,
  orderBy: [(p) => OrderingTerm.asc(p.status), (p) => OrderingTerm.desc(p.started)],
);

final coursesProvider = _rows<$LearnCoursesTable, Course>(
  (db) => db.learnCourses,
  orderBy: [(c) => OrderingTerm.asc(c.added)],
);

final skillsProvider = _rows<$LearnSkillsTable, Skill>(
  (db) => db.learnSkills,
  orderBy: [(s) => OrderingTerm.asc(s.category), (s) => OrderingTerm.asc(s.name)],
);

final portfolioProvider = _rows<$LearnPortfolioTable, PortfolioItem>(
  (db) => db.learnPortfolio,
  orderBy: [(p) => OrderingTerm.desc(p.day)],
);

final notesProvider = _rows<$LearnNotesTable, Note>(
  (db) => db.learnNotes,
  orderBy: [(n) => OrderingTerm.desc(n.updated), (n) => OrderingTerm.asc(n.title)],
);

final unlocksProvider = _rows<$LearnUnlocksTable, Unlock>((db) => db.learnUnlocks);

/// Every topic's study items still in use (not retired by a plan sent
/// again), in list order.
final itemsProvider = FutureProvider<List<StudyItem>>((ref) {
  ref.watch(revisionProvider);
  final db = ref.watch(sessionProvider).db;
  return (db.select(db.learnItems)
        ..where((i) => i.deleted.not() & i.retired.equals(''))
        ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
      .get();
});

/// The weekly study target in minutes (a synced pref), 0 when none.
final weekTargetProvider = FutureProvider<int>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.weekTarget();
});

/// The review scheduler (a synced pref): FSRS unless SM-2 was picked.
final reviewSchedulerProvider = FutureProvider<ReviewScheduler>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.reviewScheduler();
});

/// Leeches kept as they are (a synced pref): card id to lapses when kept.
final keptLeechesProvider = FutureProvider<Map<String, int>>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.keptLeeches();
});

/// Every card's reviews, by card id, oldest first: what FSRS replays.
final cardHistoriesProvider = FutureProvider<Map<String, List<CardReview>>>((ref) async {
  final s = await ref.watch(statsProvider.future);
  final by = <String, List<CardReview>>{};
  for (final r in s.reviews) {
    (by[r.cardId] ??= []).add(r);
  }
  for (final l in by.values) {
    l.sort((a, b) => a.day != b.day ? a.day.compareTo(b.day) : a.hlc.compareTo(b.hlc));
  }
  return by;
});

/// The one thing to study next, across everything ([courseId] null) or in
/// one course; null when nothing is waiting (see `nextUp`).
final nextUpProvider = FutureProvider.family<NextUp?, String?>((ref, courseId) async {
  final s = await ref.watch(statsProvider.future);
  final items = await ref.watch(itemsProvider.future);
  return nextUp(
    programs: s.programs,
    courses: s.courses,
    topics: s.topics,
    items: items,
    quizPercents: lastQuizPercents(s.assessments),
    courseId: courseId,
  );
});

/// The dated goals, their outcomes, the criteria (for topic weights) and
/// the weekly target, read again after every write (see time_fit.dart).
final readyByProvider = FutureProvider<ReadyByData>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.readyByData();
});

/// How each dated goal fits today, soonest first.
final timeFitsProvider = FutureProvider<List<TimeFit>>((ref) async {
  final d = await ref.watch(readyByProvider.future);
  final s = await ref.watch(statsProvider.future);
  final items = await ref.watch(itemsProvider.future);
  return [
    for (final g in d.goals)
      fitFor(
        g,
        today: s.today,
        courses: s.courses,
        topics: s.topics,
        items: items,
        criteria: d.criteria,
        sessions: s.sessions,
        weekMinutes: d.weekMinutes,
      ),
  ];
});

/// Each card's ready-by day (see `cardReadyBy`), by card id: a review
/// graded now is kept before it.
final cardLimitsProvider = FutureProvider<Map<String, String>>((ref) async {
  final d = await ref.watch(readyByProvider.future);
  final s = await ref.watch(statsProvider.future);
  return cardLimits(s.cards, goals: d.goals, courses: s.courses);
});

/// Pulls reviews that would land on or after a ready-by day in before it,
/// when the app opens and after every write or sync that brings changes
/// (see `pullReviewsBefore`; a rerun moves nothing). Gives how many moved.
final reviewPullProvider = FutureProvider<int>((ref) async {
  ref.watch(revisionProvider);
  final n = await ref.watch(sessionProvider).book.pullReviewsBefore(ref.watch(todayProvider));
  if (n > 0) {
    Future.microtask(() {
      ref.read(revisionProvider.notifier).bump();
      ref.read(syncProvider.notifier).soon();
    });
  }
  return n;
});

/// The criteria plans brought, per program, in plan order.
final criteriaProvider = _rows<$LearnCriteriaTable, Criterion>(
  (db) => db.learnCriteria,
  orderBy: [(c) => OrderingTerm.asc(c.ord)],
);

/// Splits the study-guide notes older plans made into topic notes and link
/// items, once when the app opens (see `splitStudyGuides`; running again
/// changes nothing). Gives how many topics gained something.
final guideSplitProvider = FutureProvider<int>((ref) async {
  final n = await ref.watch(sessionProvider).book.splitStudyGuides(today: today());
  if (n > 0) {
    Future.microtask(() {
      ref.read(revisionProvider.notifier).bump();
      ref.read(syncProvider.notifier).soon();
    });
  }
  return n;
});

/// Every measure in one place; rebuilt after each write and at midnight's
/// next write (the day comes from [todayProvider]).
final statsProvider = FutureProvider<Stats>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.stats(ref.watch(todayProvider));
});

/// The career file's study plans, added by themselves when the learner
/// turned that on (Settings), after every write and every sync that brings
/// changes. Gives the titles added this time; empty when none.
final careerFileAutoAddProvider = FutureProvider<List<String>>((ref) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final added = await book.autoAddCareerFilePlans(
    today: today(),
    now: DateTime.now().toUtc().toIso8601String(),
  );
  if (added.isNotEmpty) {
    // Load the screens again and send the "added" report; the rerun finds
    // nothing left to add.
    Future.microtask(() {
      ref.read(revisionProvider.notifier).bump();
      ref.read(syncProvider.notifier).soon();
    });
  }
  return added;
});

// ---- free resource search ----

/// The web client the resource search and link reading use. Tests
/// override it with a mock that answers from fixtures.
final httpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// The no-key catalogues, kept for the life of the app so the Microsoft
/// Learn copy is read from the device only once a run. That copy lives in
/// this device's local settings (not synced).
final freeCataloguesProvider = Provider<List<ResourceCatalogue>>((ref) {
  final client = ref.watch(httpClientProvider);
  final db = ref.watch(sessionProvider).db;
  final cache = KeyValueResourceCache(db.localSetting, db.setLocalSetting);
  return [MicrosoftLearnCatalogue(client, cache), MitLearnCatalogue(client), OpenLibraryCatalogue(client)];
});

/// The learner's own YouTube key from this device's keychain, '' when none.
final youtubeKeyProvider = FutureProvider<String>(
  (ref) => ResourceSecrets.youtubeKey(ref.watch(sessionProvider).keys.store),
);

/// Every catalogue a search asks: the free ones, plus YouTube only when the
/// learner has added a key.
final resourceCataloguesProvider = FutureProvider<List<ResourceCatalogue>>((ref) async {
  final key = await ref.watch(youtubeKeyProvider.future);
  return [
    ...ref.watch(freeCataloguesProvider),
    if (key.isNotEmpty) YouTubeCatalogue(ref.watch(httpClientProvider), key),
  ];
});
