/// The spoken interviewer (journey plan J3): Vidya asks its interview
/// drills aloud through the interview engine shared with Udyoga, hears the
/// answers on the device, and scores them against the program's criteria.
///
/// What needs an AI, and what does not:
/// - On the device, always: the questions in the interviewer's voice, the
///   transcript, follow-ups for what an answer leaves out, the panel's
///   manner and level, interruptions, coverage of each criterion read from
///   the words, one strength and one fix from the words, and the self-rating
///   on the four drill checks.
/// - With an AI (the one set in Ask AI; offline, only a local server on
///   this computer): verified-quote scores on the framework's own scale,
///   scored twice with the criteria shuffled, and follow-ups planned from
///   the questions. Only the questions, the criteria and the transcripts are
///   sent; never audio.
///
/// Results feed the drills (an attempt per answered drill), Job readiness
/// (through the drills), the story bank (an answer saved as a story) and
/// spaced review (a fix saved as a card). A round is kept as text only.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';
import 'package:interview_engine/interview_engine.dart' as ie;

import '../db/database.dart';
import 'book.dart';
import 'interview.dart';
import 'study_items.dart';

// ---- the AI ----

/// The engine's instructions with the reply format spelled out: Vidya's
/// AI connection returns text, so the schema goes in the prompt and the
/// JSON is read back out of the reply ([parseBrainReply]). Every quote in a
/// score is still checked against the transcript before it counts. The
/// same words as for any text-only model ([ie.textInstructions]).
String brainInstructions(ie.BrainRequest r) => ie.textInstructions(r);

/// The JSON object in an AI's reply, even with text or a code fence around
/// it ([ie.replyJson]). Throws a [FormatException] in plain words when there
/// is none.
Map<String, Object?> parseBrainReply(String reply) => ie.replyJson(reply);

/// The interview engine's AI steps over Vidya's AI connection (brahma_core's
/// Ask AI, which includes a local Ollama server). [send] takes the system
/// prompt and the user's text and returns the reply. It is the engine's
/// text-only brain, so a local and a cloud model go through the same
/// parsing and the same checks (honesty rule 12).
class VidyaInterviewBrain extends ie.TextPromptedInterviewBrain {
  const VidyaInterviewBrain(this._send);
  final Future<String> Function(String system, String text) _send;

  @override
  Future<String> send(String system, String text) => _send(system, text);
}

/// True when [setup] names an AI that can score: any connected AI, or with
/// [offline] on, only a local server on this computer.
bool interviewAiUsable(HelpAiSetup setup, {required bool offline}) {
  if (setup.via == HelpAi.chat) return false;
  if (!offline) return true;
  return setup.via == HelpAi.local && ie.isLoopbackHost(Uri.tryParse(setup.effectiveBase)?.host ?? '');
}

/// What the screens say about the AI, in one sentence.
String interviewAiNote(HelpAiSetup setup, {required bool offline}) {
  if (interviewAiUsable(setup, offline: offline)) {
    return 'Scores on the scale come from ${setup.via.label}. Only the questions, criteria and your words are '
        'sent, never the recording.';
  }
  if (offline && setup.via != HelpAi.chat) {
    return 'Offline practice: scoring on the scale needs a local AI server on this computer (Ask AI, '
        '"Local"). Everything else works here.';
  }
  return 'Scoring on the scale needs an AI connected in Ask AI. Without one, the interviewer, follow-ups, '
      'coverage of each criterion and your self-rating all work on this device.';
}

// ---- questions ----

/// The prefix of a stand-in criterion for a drill tagged with no program
/// criterion: the drill's own "tests" text is scored instead.
const drillCriterionPrefix = 'item:';

/// A drill as an engine question: its question, what it tests (criterion
/// row ids, or a stand-in for an untagged drill) and its item id under
/// `item`, so results go back to the drill.
ie.EngineQuestion drillQuestionFor(StudyItem drill, Topic? topic, List<Criterion> criteria) {
  final tests = drillCriteria(drill, topic, criteria);
  final words = drillCriterionText(drill, criteria);
  final rubric = itemContent(drill)['rubric'];
  return ie.EngineQuestion({
    'question': drillQuestion(drill),
    'category': isScenarioDrill(drill) ? 'Situational' : 'Behavioural',
    'why': words.isNotEmpty ? words : (tests.isEmpty ? '' : tests.first.body),
    'lookFor': [if (rubric is String && rubric.trim().isNotEmpty) rubric.trim()],
    'criteria': tests.isEmpty ? ['$drillCriterionPrefix${drill.id}'] : [for (final c in tests) c.id],
    'item': drill.id,
  });
}

/// The criteria a round is scored against: the program's, plus a stand-in
/// for each untagged drill. Stored with the round, so its debrief reads the
/// same later whatever changes in the program.
List<Map<String, Object?>> roundCriteria(List<Criterion> criteria, List<ie.EngineQuestion> questions) {
  final out = [
    for (final c in criteria) {'id': c.id, 'text': c.body, 'essential': c.essential},
  ];
  for (final q in questions) {
    for (final id in ie.criteriaOf(q)) {
      if (id.startsWith(drillCriterionPrefix) && !out.any((c) => c['id'] == id)) {
        out.add({'id': id, 'text': q.why.isNotEmpty ? q.why : q.question, 'essential': false});
      }
    }
  }
  return out;
}

// ---- a saved round ----

/// A round read back from its row.
class SavedRound {
  SavedRound(this.row);
  final RoundRow row;

  String get id => row.id;

  late final Map<String, Object?> _settings = _map(row.settings);

  ie.RoundSettings get settings => ie.RoundSettings.fromJson(_map(_settings['round']));

  /// Typed round (no speech models used).
  bool get typed => _settings['typed'] == true;

  late final List<ie.EngineQuestion> questions = [
    for (final q in _list(row.questions))
      if (q is Map) ie.EngineQuestion(q.cast<String, Object?>()),
  ];

  late final Map<int, String> answers = {
    for (final e in _map(row.answers).entries)
      if (int.tryParse(e.key) case final i? when e.value is String) i: e.value as String,
  };

  ie.Framework get framework => ie.Framework.of(row.framework);

  late final ie.RoleProfile profile = ie.RoleProfile(
    id: row.programId ?? 'vidya',
    title: row.title,
    frameworkId: row.framework,
    criteria: [
      for (final c in _list(_settings['criteria']))
        if (c is Map && c['id'] is String && c['text'] is String)
          ie.Criterion(id: c['id'] as String, text: c['text'] as String, essential: c['essential'] == true),
    ],
  );

  /// The AI's two raw scoring runs, empty when not scored.
  late final List<List<ie.AnswerScore>> runs = [
    for (final r in _list(_map(row.scoring)['runs']))
      [
        for (final a in r is List ? r : const [])
          if (a is Map) ie.AnswerScore.fromJson(a.cast<String, Object?>()),
      ],
  ];

  bool get scored => runs.isNotEmpty;

  /// The drill (item id) question [i] came from.
  String? itemOf(int i) => i < questions.length ? questions[i].j['item'] as String? : null;

  late final ie.DebriefRound debriefRound = ie.DebriefRound.of(
    questions: questions,
    answers: answers,
    profile: profile.criteria.isEmpty ? null : profile,
  );

  /// Both runs checked against the transcripts and joined; null when not
  /// scored by an AI.
  late final ie.Verified? verified = scored ? ie.verifyRuns(runs, framework.scale, debriefRound) : null;

  /// The debrief: verified scores when there are any, else coverage read
  /// from the words on this device. Only the criteria this round asked
  /// about are listed.
  late final ie.Debrief debrief = ie.Debrief.build(
    framework: framework,
    round: debriefRound,
    verified: verified,
    wholeProfile: false,
  );
}

Map<String, Object?> _map(Object? v) {
  if (v is String) {
    if (v.isEmpty) return const {};
    try {
      v = jsonDecode(v);
    } on FormatException {
      return const {};
    }
  }
  return v is Map ? v.cast<String, Object?>() : const {};
}

List<Object?> _list(Object? v) {
  if (v is String) {
    try {
      v = jsonDecode(v);
    } on FormatException {
      return const [];
    }
  }
  return v is List ? v : const [];
}

/// Question [i]'s AI score as a drill attempt: each criterion's verified
/// level, and the lowest placed on the 0–8 drill scale (so one criterion
/// with no evidence flags the drill). Null when the AI did not score it.
DrillAttempt? spokenAttempt(SavedRound r, int i) {
  final v = r.verified;
  if (v == null) return null;
  final scale = r.framework.scale;
  final ids = r.debriefRound.asked[i] ?? const [];
  if (ids.isEmpty || (r.answers[i] ?? '').trim().isEmpty) return null;
  final levels = <String, ie.ScaleLevel>{};
  var uncertain = false;
  for (final id in ids) {
    final mine = [
      for (final s in v.scores)
        if (s.question == i && s.criterionId == id) s,
    ];
    final best = mine.isEmpty
        ? null
        : (mine..sort((a, b) => scale.rank(b.level).compareTo(scale.rank(a.level)))).first;
    levels[id] = best?.level ?? scale.noEvidence;
    uncertain = uncertain || (best?.uncertain ?? false);
  }
  final low = levels.values.reduce((a, b) => scale.rank(a) <= scale.rank(b) ? a : b);
  final top = scale.levels.length - 1;
  return DrillAttempt(
    checks: const [],
    round: r.id,
    levels: {for (final e in levels.entries) e.key: e.value.code},
    levelNote:
        'interviewer: ${low.code} (${low.label}) on the ${scale.name}'
        '${uncertain ? ', uncertain' : ''}',
    uncertain: uncertain,
    outOf8: top <= 0 ? 0 : (scale.rank(low) * drillMax / top).round(),
  );
}

/// The deck spoken-round fixes go into for spaced review.
const interviewDeck = 'Interview practice';

extension SpokenRounds on LearningBook {
  /// Starts a round of [questions] (see [drillQuestionFor]) scored against
  /// [criteria] on [framework]. Returns its id.
  Future<String> startRound({
    String? programId,
    required String title,
    required String framework,
    required ie.RoundSettings settings,
    required List<ie.EngineQuestion> questions,
    required List<Criterion> criteria,
    bool typed = false,
    required String today,
  }) async {
    final id = newId();
    await save(
      db.learnRounds,
      LearnRoundsCompanion.insert(
        id: id,
        programId: Value(programId),
        title: title.trim().isEmpty ? 'Interview practice' : title.trim(),
        day: today,
        framework: Value(framework),
        settings: Value(
          jsonEncode({
            'round': settings.toJson(),
            'criteria': roundCriteria(criteria, questions),
            if (typed) 'typed': true,
          }),
        ),
        questions: jsonEncode([for (final q in questions) q.j]),
        deleted: const Value(false),
      ),
      id,
    );
    return id;
  }

  Future<RoundRow?> _roundRow(String id) =>
      (db.select(db.learnRounds)..where((r) => r.id.equals(id) & r.deleted.not())).getSingleOrNull();

  Future<SavedRound?> savedRound(String id) async => switch (await _roundRow(id)) {
    final r? => SavedRound(r),
    null => null,
  };

  /// The rounds, newest first; only [programId]'s when given.
  Future<List<SavedRound>> savedRounds({String? programId}) async {
    final q = db.select(db.learnRounds)..where((r) => r.deleted.not());
    if (programId != null) q.where((r) => r.programId.equals(programId));
    final rows = await q.get();
    rows.sort((a, b) {
      final d = b.day.compareTo(a.day);
      return d != 0 ? d : b.hlc.compareTo(a.hlc);
    });
    return [for (final r in rows) SavedRound(r)];
  }

  /// Saves the text of question [index]'s answer (follow-ups included).
  Future<void> saveRoundAnswer(String id, int index, String text) => db.transaction(() async {
    final r = await _roundRow(id);
    if (r == null) return;
    final answers = {..._map(r.answers), '$index': text};
    await save(db.learnRounds, r.copyWith(answers: jsonEncode(answers)), id);
  });

  Future<void> finishRound(String id, {required String now}) async {
    final r = await _roundRow(id);
    if (r == null || r.finished != null) return;
    await save(db.learnRounds, r.copyWith(finished: Value(now)), id);
  }

  /// Keeps the AI's raw scoring runs with the engine version that will
  /// check them.
  Future<void> saveRoundScoring(String id, List<List<ie.AnswerScore>> runs) async {
    final r = await _roundRow(id);
    if (r == null) return;
    await save(
      db.learnRounds,
      r.copyWith(
        scoring: jsonEncode({
          'engine': ie.engineVersion,
          'runs': [
            for (final run in runs) [for (final a in run) a.toJson()],
          ],
        }),
      ),
      id,
    );
  }

  /// Deletes the round's text and scores. Attempts already saved on drills
  /// stay (each can be deleted on its drill).
  Future<void> deleteRound(String id) => remove(db.learnRounds, id);

  /// Saves each answered drill's result as an attempt on the drill: the
  /// AI's verified levels when the round was scored, else the learner's
  /// four check ratings in [selfChecks] (by question). Saving again
  /// replaces the round's earlier results. Returns how many were saved.
  Future<int> recordRoundResults(
    SavedRound r, {
    Map<int, List<int>> selfChecks = const {},
    required String today,
  }) async {
    var saved = 0;
    for (var i = 0; i < r.questions.length; i++) {
      final itemId = r.itemOf(i);
      if (itemId == null || (r.answers[i] ?? '').trim().isEmpty) continue;
      final checks = selfChecks[i];
      final attempt =
          spokenAttempt(r, i) ??
          (checks != null && checks.length == drillChecks.length
              ? DrillAttempt(checks: checks, round: r.id, note: 'Spoken round')
              : null);
      if (attempt == null) continue;
      final drill = await (db.select(
        db.learnItems,
      )..where((x) => x.id.equals(itemId) & x.deleted.not())).getSingleOrNull();
      if (drill == null) continue;
      await recordDrill(drill, attempt, today: today, id: 'round.${r.id}.$i');
      saved++;
    }
    return saved;
  }

  /// A fix from the debrief as a review card: the question on the front,
  /// what to do better (and what the next level needs) on the back.
  Future<void> addFixToReview({
    required String question,
    required String fix,
    String nextLevel = '',
    required String today,
  }) => saveCard(
    'Interview: $question\n\nWhat would make this answer stronger?',
    [fix.trim(), if (nextLevel.trim().isNotEmpty) 'Next level: ${nextLevel.trim()}'].join('\n\n'),
    deck: interviewDeck,
    today: today,
  );

  /// Question [i]'s answer as a draft story in the story bank, linked to
  /// the drill and to the program criteria it tests. Returns its id.
  Future<String> saveAnswerAsStory(SavedRound r, int i, {required String today}) {
    final q = r.questions[i];
    final criteria = [
      for (final id in ie.criteriaOf(q))
        if (!id.startsWith(drillCriterionPrefix)) id,
    ];
    final s = ie.storyFromAnswer(title: q.question, answer: r.answers[i] ?? '');
    final title = q.question.length > 80 ? '${q.question.substring(0, 79)}…' : q.question;
    return saveStory(
      title: 'From practice: $title',
      situation: s.situation,
      action: s.action,
      result: s.result,
      criteria: criteria,
      drills: [?r.itemOf(i)],
      today: today,
    );
  }
}
