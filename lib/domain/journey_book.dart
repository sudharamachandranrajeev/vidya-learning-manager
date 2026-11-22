/// Job journeys in the database: one per program, saved when a plan with a
/// `journey` is added (or started by hand), shown merged with its dated
/// template, and the learner's stage and progress kept apart from what the
/// plan sends, so a plan sent again never loses them.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'interview.dart';
import 'journey.dart';
import 'journey_templates.dart';
import 'study_items.dart';

/// The most text a pasted draft keeps.
const maxDraft = 40000;

/// The local day (yyyy-MM-dd) of [now], a UTC ISO time; today when it is
/// not a time.
String _day(String now) => switch (DateTime.tryParse(now)) {
  final t? => isoDate(t.toLocal()),
  null => today(),
};

/// What the learner did on one stage.
class StageProgress {
  const StageProgress({
    this.produced = const {},
    this.notes = const {},
    this.ticked = const {},
    this.checkDone = '',
    this.checkResult = '',
    this.draft = '',
  });

  /// Artefact titles ticked, with the day.
  final Map<String, String> produced;

  /// Notes kept on artefacts, by title.
  final Map<String, String> notes;

  /// Checklist items ticked.
  final Set<String> ticked;

  /// The day the stage's check was last done, '' while not done.
  final String checkDone;

  /// What the check found, in a line ("3 of 4 right").
  final String checkResult;

  /// The draft pasted for a coverage check.
  final String draft;

  factory StageProgress.fromJson(Object? j) {
    if (j is! Map) return const StageProgress();
    Map<String, String> strings(Object? m) => {
      if (m is Map)
        for (final e in m.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
    };
    return StageProgress(
      produced: strings(j['produced']),
      notes: strings(j['notes']),
      ticked: {
        if (j['ticked'] is List)
          for (final t in j['ticked'] as List)
            if (t is String) t,
      },
      checkDone: j['checkDone'] is String ? j['checkDone'] as String : '',
      checkResult: j['checkResult'] is String ? j['checkResult'] as String : '',
      draft: j['draft'] is String ? j['draft'] as String : '',
    );
  }

  Map<String, Object> toJson() => {
    if (produced.isNotEmpty) 'produced': produced,
    if (notes.isNotEmpty) 'notes': notes,
    if (ticked.isNotEmpty) 'ticked': (ticked.toList()..sort()),
    if (checkDone.isNotEmpty) 'checkDone': checkDone,
    if (checkResult.isNotEmpty) 'checkResult': checkResult,
    if (draft.isNotEmpty) 'draft': draft,
  };

  /// Done when every artefact is ticked and the check is done.
  bool doneFor(JourneyStage s) =>
      s.produce.every((p) => produced.containsKey(p.title)) && checkDone.isNotEmpty;
}

/// A program's journey as the Journey page shows it.
class JourneyView {
  const JourneyView({
    required this.row,
    required this.journey,
    required this.current,
    required this.progress,
    this.suggested,
  });
  final JourneyRow row;

  /// Merged with its template and the program's criteria.
  final Journey journey;

  /// The stage the learner is on.
  final String current;

  /// The stage Udyoga's application status suggests, when it differs from
  /// [current].
  final String? suggested;
  final Map<String, StageProgress> progress;

  StageProgress of(String stage) => progress[stage] ?? const StageProgress();
}

extension JourneyBook on LearningBook {
  Future<JourneyRow?> journeyRow(String programId) async => (await (db.select(
    db.learnJourneys,
  )..where((j) => j.programId.equals(programId) & j.deleted.not())).get()).firstOrNull;

  /// Saves the journey a plan sent for [programId]: the job's data is
  /// replaced, the learner's stage and progress stay.
  Future<void> saveJourney(String programId, Journey journey, {required String now}) async {
    final old = await journeyRow(programId);
    final json = jsonEncode(journey.toJson());
    if (old != null) {
      if (old.journey == json) return;
      await save(db.learnJourneys, old.copyWith(journey: json, updated: now), old.id);
      return;
    }
    final id = newId();
    await save(
      db.learnJourneys,
      LearnJourneysCompanion.insert(id: id, programId: programId, journey: json, updated: now),
      id,
    );
  }

  /// The journey shown for [programId], or null when it has none.
  Future<JourneyView?> journeyView(String programId) async {
    final row = await journeyRow(programId);
    if (row == null) return null;
    Journey sent;
    try {
      sent = parseJourney(jsonDecode(row.journey));
    } on FormatException {
      sent = const Journey();
    }
    final criteria =
        await (db.select(db.learnCriteria)
              ..where((c) => c.programId.equals(programId) & c.deleted.not())
              ..orderBy([(c) => OrderingTerm.asc(c.ord)]))
            .get();
    final journey = mergeJourney(
      sent,
      templateFor(sent.sector),
      criteria: [
        for (final c in criteria)
          (id: c.ref, text: c.body, essential: c.essential, kind: c.kind, source: c.source, shown: c.shown),
      ],
    );
    final suggested = stageForApplication(sent.applicationStage);
    final current = journeyStages.containsKey(row.stage) ? row.stage : (suggested ?? 'decide');
    return JourneyView(
      row: row,
      journey: journey,
      current: current,
      suggested: suggested == current ? null : suggested,
      progress: _progress(row),
    );
  }

  static Map<String, StageProgress> _progress(JourneyRow row) {
    Object? j;
    try {
      j = jsonDecode(row.progress);
    } on FormatException {
      j = null;
    }
    return {
      if (j is Map)
        for (final e in j.entries)
          if (e.key is String && journeyStages.containsKey(e.key))
            e.key as String: StageProgress.fromJson(e.value),
    };
  }

  /// Starts a journey by hand for a program with none.
  Future<void> startJourney(
    String programId, {
    required String role,
    required String sector,
    required String now,
  }) => saveJourney(
    programId,
    Journey(role: role, sector: sector),
    now: now,
  );

  Future<void> setJourneyStage(String programId, String stage, {required String now}) async {
    final row = await journeyRow(programId);
    if (row == null || !journeyStages.containsKey(stage) || row.stage == stage) return;
    await save(db.learnJourneys, row.copyWith(stage: stage, updated: now), row.id);
  }

  Future<void> _update(
    String programId,
    String stage,
    StageProgress Function(StageProgress) change, {
    required String now,
  }) => db.transaction(() async {
    final row = await journeyRow(programId);
    if (row == null) return;
    final all = _progress(row);
    all[stage] = change(all[stage] ?? const StageProgress());
    final json = jsonEncode({
      for (final e in all.entries)
        if (e.value.toJson().isNotEmpty) e.key: e.value.toJson(),
    });
    if (json == row.progress) return;
    await save(db.learnJourneys, row.copyWith(progress: json, updated: now), row.id);
  });

  /// Ticks (or unticks) an artefact.
  Future<void> setProduced(String programId, String stage, String title, bool done, {required String now}) =>
      _update(
        programId,
        stage,
        (p) => StageProgress(
          produced: {
            for (final e in p.produced.entries)
              if (e.key != title) e.key: e.value,
            if (done) title: _day(now),
          },
          notes: p.notes,
          ticked: p.ticked,
          checkDone: p.checkDone,
          checkResult: p.checkResult,
          draft: p.draft,
        ),
        now: now,
      );

  /// Keeps a note on an artefact ('' removes it).
  Future<void> setProduceNote(
    String programId,
    String stage,
    String title,
    String note, {
    required String now,
  }) => _update(
    programId,
    stage,
    (p) => StageProgress(
      produced: p.produced,
      notes: {
        for (final e in p.notes.entries)
          if (e.key != title) e.key: e.value,
        if (note.trim().isNotEmpty)
          title: note.trim().length > maxDraft ? note.trim().substring(0, maxDraft) : note.trim(),
      },
      ticked: p.ticked,
      checkDone: p.checkDone,
      checkResult: p.checkResult,
      draft: p.draft,
    ),
    now: now,
  );

  /// Ticks a checklist item; the check is done once every item of
  /// [items] is ticked.
  Future<void> setTicked(
    String programId,
    String stage,
    String item,
    bool on, {
    required List<String> items,
    required String now,
  }) => _update(programId, stage, (p) {
    final ticked = {...p.ticked};
    on ? ticked.add(item) : ticked.remove(item);
    final all = items.isNotEmpty && items.every(ticked.contains);
    return StageProgress(
      produced: p.produced,
      notes: p.notes,
      ticked: ticked,
      checkDone: all ? (p.checkDone.isNotEmpty ? p.checkDone : _day(now)) : '',
      checkResult: all
          ? 'All ${items.length} ticked'
          : '${ticked.where(items.contains).length} of ${items.length} ticked',
      draft: p.draft,
    );
  }, now: now);

  /// Records the stage's check as done on [day] with what it found, or
  /// clears it when [day] is ''.
  Future<void> setCheck(
    String programId,
    String stage, {
    required String day,
    String result = '',
    required String now,
  }) => _update(
    programId,
    stage,
    (p) => StageProgress(
      produced: p.produced,
      notes: p.notes,
      ticked: p.ticked,
      checkDone: day,
      checkResult: day.isEmpty ? '' : result,
      draft: p.draft,
    ),
    now: now,
  );

  /// Keeps a pasted draft and the result of its coverage check; the check
  /// counts as done when every essential criterion uses its own words.
  Future<List<CoverageRow>> checkDraft(
    String programId,
    String stage,
    String draft,
    List<String> essentials, {
    required String now,
  }) async {
    final text = draft.length > maxDraft ? draft.substring(0, maxDraft) : draft;
    final rows = coverageCheck(text, essentials);
    final exact = rows.where((r) => r.coverage == Coverage.exact).length;
    final all = rows.isNotEmpty && exact == rows.length;
    await _update(
      programId,
      stage,
      (p) => StageProgress(
        produced: p.produced,
        notes: p.notes,
        ticked: p.ticked,
        checkDone: all ? _day(now) : '',
        checkResult: rows.isEmpty ? '' : '$exact of ${rows.length} essential criteria in their own words',
        draft: text,
      ),
      now: now,
    );
    return rows;
  }

  /// Adds an interview drill for each essential criterion that has none,
  /// so the interviewer has the job's criteria to ask about. They go in one
  /// practice course; the questions are a plain template, written by no AI.
  /// Returns how many were added.
  Future<int> addCriterionDrills(String programId, {required String today}) => db.transaction(() async {
    final drills = (await programDrills(programId)).drills;
    final tested = <String>{};
    for (final d in drills) {
      final c = itemContent(d)['criterion'];
      if (c is String) tested.addAll(c.split(',').map((x) => x.trim()));
    }
    final missing = [
      for (final c in await programCriteria(programId))
        if (c.essential && !tested.contains(c.ref)) c,
    ];
    if (missing.isEmpty) return 0;
    const course = 'Interview drills from the criteria';
    final have =
        (await (db.select(
              db.learnCourses,
            )..where((c) => c.programId.equals(programId) & c.deleted.not() & c.title.equals(course))).get())
            .firstOrNull;
    final courseId =
        have?.id ?? await addCourse(course, today: today, programId: programId, kind: 'practice');
    const title = 'One question for each essential criterion';
    final topic =
        (await (db.select(
              db.learnTopics,
            )..where((t) => t.courseId.equals(courseId) & t.deleted.not() & t.title.equals(title))).get())
            .firstOrNull;
    final topicId = topic?.id ?? await addTopic(courseId, title);
    for (final c in missing) {
      await addDrill(topicId, 'Tell me about a time you showed this: ${c.body}', criterion: c.ref);
    }
    return missing.length;
  });

  Future<void> removeJourney(String programId) async {
    final row = await journeyRow(programId);
    if (row != null) await remove(db.learnJourneys, row.id);
  }
}
