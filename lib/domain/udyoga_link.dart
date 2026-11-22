/// The live link with Udyoga, the career app, through sync: a study plan it
/// sends is offered here; what is finished here goes back. Both apps must
/// sync with the same account. Without sync the plan comes as a file
/// (Import a study plan) and progress goes back as the portfolio.
library;

import 'dart:async';
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'curriculum.dart';
import 'readiness.dart';
import 'review.dart' show Grade;

/// A plan another app sent that this one has not added in its latest form.
typedef OfferedPlan = ({StudyPlan row, CurriculumPlan plan});

/// Plans Udyoga sends from the candidate's career file (its
/// `settings/vidya-*.json`) have ids starting with this.
const careerFilePlanPrefix = 'udyoga.career-file.';

/// Device-only: 'on' when plans from the career file are added without
/// asking.
const autoAddCareerFileKey = 'vidya.careerfile.auto';

/// Whether [offer] came from the career file rather than Udyoga's own plans.
bool isCareerFilePlan(OfferedPlan offer) => offer.row.id.startsWith(careerFilePlanPrefix);

extension UdyogaLink on LearningBook {
  /// Plans sent and not yet added (or changed since). A plan that cannot be
  /// read is left out, not fatal: it may come from a newer Udyoga.
  Future<List<OfferedPlan>> offeredPlans() async {
    final plans = await (db.select(db.bridgeStudyPlans)..where((p) => p.deleted.not())).get();
    final added = {
      for (final p in await (db.select(db.bridgeStudyProgress)..where((p) => p.deleted.not())).get())
        p.id: p.planUpdated,
    };
    final out = <OfferedPlan>[];
    for (final row in plans) {
      if (added[row.id] == row.updated) continue;
      try {
        out.add((row: row, plan: parseCurriculum(row.plan)));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// Adds [offer] as the file import would (merging by title, so adding a
  /// re-sent plan updates the same program), and tells the sender it is in.
  Future<CurriculumImport> addOfferedPlan(OfferedPlan offer, {required String today, required String now}) =>
      db.transaction(() async {
        final r = await importCurriculum(offer.plan, today: today);
        await _report(offer.row.id, planUpdated: offer.row.updated, now: now, force: true);
        return r;
      });

  Future<bool> autoAddCareerFile() async => await db.localSetting(autoAddCareerFileKey) == 'on';

  Future<void> setAutoAddCareerFile(bool on) => db.setLocalSetting(autoAddCareerFileKey, on ? 'on' : 'off');

  /// Adds the career file's plans that are new or changed, when the learner
  /// turned that on; each goes through [addOfferedPlan], so a changed file
  /// updates its program in place. Udyoga's own plans still wait for a tap.
  /// Returns the titles added.
  Future<List<String>> autoAddCareerFilePlans({required String today, required String now}) async {
    if (!await autoAddCareerFile()) return const [];
    final added = <String>[];
    for (final offer in await offeredPlans()) {
      if (!isCareerFilePlan(offer)) continue;
      await addOfferedPlan(offer, today: today, now: now);
      added.add(offer.plan.title);
    }
    return added;
  }

  /// What was finished and the rated skills, as the portfolio lists them.
  Future<StudyProgress> studyProgress() async {
    final courses =
        await (db.select(db.learnCourses)
              ..where((c) => c.deleted.not() & c.status.equals('done'))
              ..orderBy([(c) => OrderingTerm.asc(c.title)]))
            .get();
    final skills =
        await (db.select(db.learnSkills)
              ..where((k) => k.deleted.not() & k.level.isBiggerThanValue(0))
              ..orderBy([(k) => OrderingTerm.asc(k.name)]))
            .get();
    return StudyProgress(
      learning: [
        for (final c in courses)
          (title: c.title, kind: c.kind, provider: c.provider, finished: c.finished ?? ''),
      ],
      skills: [for (final k in skills) (name: k.name, category: k.category, level: k.level)],
    );
  }

  /// Updates the progress for every plan received, only when it changed,
  /// so ordinary study does not fill the sync log. Nothing happens until a
  /// plan has come from Udyoga.
  Future<void> reportToUdyoga({required String now}) async {
    final plans = await (db.select(db.bridgeStudyPlans)..where((p) => p.deleted.not())).get();
    for (final p in plans) {
      await _report(p.id, now: now);
    }
  }

  /// How the plan's own cards and checklist items went, for the sender:
  /// each card (by its id) rehearsed at least once, with the day of the last
  /// review, its grade and how many reviews; each finished topic of the
  /// plan's courses. Sorted, so the report only changes when the work does.
  Future<List<Map<String, Object>>> planDrills(CurriculumPlan plan) async {
    final ids = {
      for (final c in plan.cards)
        if (c.id.isNotEmpty) c.id,
    };
    final out = <Map<String, Object>>[];
    if (ids.isNotEmpty) {
      final cards = await (db.select(db.learnCards)..where((c) => c.deleted.not() & c.ref.isIn(ids))).get();
      final byId = {for (final c in cards) c.id: c};
      final reviews =
          await (db.select(db.learnReviews)
                ..where((r) => r.deleted.not() & r.cardId.isIn(byId.keys))
                ..orderBy([(r) => OrderingTerm.asc(r.day), (r) => OrderingTerm.asc(r.hlc)]))
              .get();
      final last = <String, CardReview>{};
      final times = <String, int>{};
      for (final r in reviews) {
        last[r.cardId] = r;
        times[r.cardId] = (times[r.cardId] ?? 0) + 1;
      }
      for (final c in cards) {
        final r = last[c.id];
        if (r == null) continue;
        out.add({
          'id': c.ref,
          'title': c.front,
          'done': r.day,
          'rating': Grade.values[r.grade.clamp(0, Grade.values.length - 1)].name,
          'times': times[c.id]!,
        });
      }
    }
    final program = await planProgram(plan);
    if (program != null) {
      final titles = {for (final c in plan.courses) c.title.toLowerCase()};
      final courses =
          (await (db.select(
            db.learnCourses,
          )..where((c) => c.programId.equals(program.id) & c.deleted.not())).get()).where(
            (c) => titles.contains(c.title.toLowerCase()),
          );
      for (final c in courses) {
        for (final t in await (db.select(
          db.learnTopics,
        )..where((t) => t.courseId.equals(c.id) & t.deleted.not() & t.done.isNotNull())).get()) {
          out.add({'course': c.title, 'title': t.title, 'done': t.done!});
        }
      }
    }
    String sortKey(Map<String, Object> d) => '${d['id'] ?? ''}\u0000${d['course'] ?? ''}\u0000${d['title']}';
    return out..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  }

  /// The program a plan was added as (matched by title, as the import
  /// merges), or null when it has not been added.
  Future<Program?> planProgram(CurriculumPlan plan) async {
    final key = plan.title.toLowerCase();
    return (await (db.select(
      db.learnPrograms,
    )..where((p) => p.deleted.not())).get()).where((p) => p.title.toLowerCase() == key).firstOrNull;
  }

  Future<void> _report(String planId, {String? planUpdated, required String now, bool force = false}) async {
    final old = await (db.select(
      db.bridgeStudyProgress,
    )..where((p) => p.id.equals(planId))).getSingleOrNull();
    var progress = (await studyProgress()).encode();
    // The plan's drills ride along in the same JSON; readers that do not
    // know the field ignore it. Left out when empty.
    final row = await (db.select(db.bridgeStudyPlans)..where((p) => p.id.equals(planId))).getSingleOrNull();
    CurriculumPlan? plan;
    try {
      plan = row == null ? null : parseCurriculum(row.plan);
    } on FormatException {
      plan = null;
    }
    final drills = plan == null ? const <Map<String, Object>>[] : await planDrills(plan);
    if (drills.isNotEmpty) {
      progress = jsonEncode({...jsonDecode(progress) as Map<String, Object?>, 'drills': drills});
    }
    // The program's weak and missing criteria ride along too, as
    // `readiness` (see `readinessReport`), so Udyoga can turn them into
    // drill cards. Only for a program with criteria; an empty list then
    // means every criterion is covered.
    final program = plan == null ? null : await planProgram(plan);
    if (program != null) {
      final r = await readiness(program.id, today: reportDay(now));
      if (r.rows.isNotEmpty) {
        progress = jsonEncode({
          ...jsonDecode(progress) as Map<String, Object?>,
          'readiness': readinessReport(r),
        });
      }
    }
    final mark = planUpdated ?? old?.planUpdated ?? '';
    if (!force && old != null && !old.deleted && old.progress == progress && old.planUpdated == mark) return;
    if (!force && old == null) return; // Not added yet: nothing to report on.
    await save(
      db.bridgeStudyProgress,
      BridgeStudyProgressCompanion.insert(
        id: planId,
        planUpdated: Value(mark),
        progress: Value(progress),
        updated: now,
      ),
      planId,
    );
  }
}

/// The local calendar day (yyyy-MM-dd) of a report time in UTC ISO 8601,
/// the day the learner is living in (a report at 23:30 UTC is already the
/// next day in New Zealand); today on this device when [now] is not a time.
String reportDay(String now) {
  final t = DateTime.tryParse(now);
  return t == null ? today() : isoDate(t.toLocal());
}

/// Sends progress back to Udyoga at most once per [gap]: when a review
/// session ends, when the app comes back to the front, and after other
/// writes. A request inside the gap is not lost: it runs when the gap is
/// over (or at the next request after it, if the app was closed meanwhile).
/// The report itself writes only when something changed.
class ProgressReporter {
  ProgressReporter(
    this._report, {
    this.gap = const Duration(minutes: 10),
    DateTime Function()? clock,
    Timer Function(Duration, void Function())? timer,
  }) : _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new;

  final Future<void> Function(String now) _report;
  final Duration gap;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _timer;

  DateTime? _last;
  Timer? _waiting;
  Future<void>? _running;

  /// When the last report ran, null before the first.
  DateTime? get last => _last;

  /// Whether a request is waiting for the gap to pass.
  bool get pending => _waiting != null;

  /// Reports now, or once the gap since the last report has passed.
  Future<void> request() async {
    if (_running != null) return _running;
    final now = _clock();
    final last = _last;
    if (last != null && now.difference(last) < gap) {
      _waiting ??= _timer(gap - now.difference(last), () {
        _waiting = null;
        request();
      });
      return;
    }
    _waiting?.cancel();
    _waiting = null;
    _last = now;
    final run = _report(now.toUtc().toIso8601String());
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
  }

  void dispose() {
    _waiting?.cancel();
    _waiting = null;
  }
}
