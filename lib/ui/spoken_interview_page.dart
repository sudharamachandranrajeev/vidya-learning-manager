/// The spoken interviewer (journey plan J3): pick drills, the panel and
/// the level, then the interviewer asks each drill aloud in Kokoro's voice,
/// hears the answer and writes it down with Moonshine, on this device. It
/// follows up on what an answer leaves out and may stop an answer that runs
/// over time. With no microphone or no speech models, every answer can be
/// typed. The debrief (interview_debrief_page.dart) scores the round.
///
/// Recordings stay in a temporary folder on this device and are deleted
/// when this screen closes; only the text is kept with the round.
///
/// Video takes (J7) are opt-in per round: "Record video for this round"
/// is off every time the screen opens. With it on (and the camera on), the
/// camera records while the microphone is open, with no sound of its own;
/// each clip is kept with the answer's audio in Vidya's own folder for the
/// days set in Settings, never synced, backed up or sent to an AI.
library;

import 'dart:async';
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' hide Criterion;

import '../app/interview_providers.dart';
import '../app/providers.dart';
import '../db/database.dart';
import '../domain/interview.dart';
import '../domain/spoken_interview.dart';
import 'camera_setup.dart';
import 'common.dart';
import 'interview_debrief_page.dart';
import 'video_review_page.dart' show videoTakePrivacy;
import 'zen.dart';

/// Opens the interviewer on a program's drills, or on one drill.
Future<void> openSpokenInterview(BuildContext context, {String? programId, String? itemId}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SpokenInterviewPage(programId: programId, itemId: itemId),
      ),
    );

/// What the setup shows: the program's drills (or the one drill), their
/// topics, the criteria and each drill's practice so far.
typedef InterviewSetup = ({
  String? programId,
  String role,
  List<StudyItem> drills,
  Map<String, Topic> topics,
  List<Criterion> criteria,
  Map<String, DrillEvidence> evidence,
});

final interviewSetupProvider = FutureProvider.family<InterviewSetup, ({String? programId, String? itemId})>((
  ref,
  key,
) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  var pid = key.programId;
  StudyItem? only;
  if (key.itemId case final id?) {
    only = await (db.select(
      db.learnItems,
    )..where((i) => i.id.equals(id) & i.deleted.not())).getSingleOrNull();
    if (only != null && pid == null) {
      final t = await (db.select(db.learnTopics)..where((t) => t.id.equals(only!.topicId))).getSingleOrNull();
      final c = t == null
          ? null
          : await (db.select(db.learnCourses)..where((c) => c.id.equals(t.courseId))).getSingleOrNull();
      pid = c?.programId;
    }
  }
  final drills = pid == null ? [?only] : (await book.programDrills(pid)).drills;
  if (only != null && !drills.any((d) => d.id == only!.id)) drills.insert(0, only);
  final topicIds = {for (final d in drills) d.topicId};
  final topics = topicIds.isEmpty
      ? const <Topic>[]
      : await (db.select(db.learnTopics)..where((t) => t.id.isIn(topicIds))).get();
  final program = pid == null
      ? null
      : await (db.select(db.learnPrograms)..where((p) => p.id.equals(pid!))).getSingleOrNull();
  return (
    programId: pid,
    role: program == null ? 'Interview practice' : (program.role.isNotEmpty ? program.role : program.title),
    drills: drills,
    topics: {for (final t in topics) t.id: t},
    criteria: pid == null ? const <Criterion>[] : await book.programCriteria(pid),
    evidence: await book.drillEvidence(drills.map((d) => d.id)),
  );
});

/// Saves each answer's text with the round as soon as it is in.
class _RoundSink implements AnswerSink {
  _RoundSink(this.ref, this.roundId);
  final WidgetRef ref;
  final String roundId;

  @override
  Future<void> saveTranscript(int question, String text) =>
      ref.read(sessionProvider).book.saveRoundAnswer(roundId, question, text);
}

// For a typed round: no voice, no microphone, nothing recorded.
class _SilentVoice implements InterviewerVoice {
  @override
  void prepare(String text) {}
  @override
  Future<void> say(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> close() async {}
}

class _NoMicrophone implements AnswerListener {
  @override
  Future<AnswerCapture> listen({Duration? endSilence}) =>
      Future.error(StateError('this round is typed, so the microphone stays off'));
  @override
  Future<void> close() async {}
}

class _NoTakes implements TakeStore {
  @override
  Future<String> save(int question, int take, Pcm audio) async =>
      throw StateError('A typed round keeps no audio');
  @override
  Future<void> remove(String key) async {}
  @override
  Future<void> removeAll() async {}
}

/// Most drills a round asks.
const maxRoundDrills = 6;

class SpokenInterviewPage extends ConsumerStatefulWidget {
  const SpokenInterviewPage({super.key, this.programId, this.itemId});
  final String? programId;
  final String? itemId;

  @override
  ConsumerState<SpokenInterviewPage> createState() => _SpokenInterviewPageState();
}

class _SpokenInterviewPageState extends ConsumerState<SpokenInterviewPage> {
  Set<String>? _picked;
  RoundSettings _settings = const RoundSettings();
  String _framework = 'private';
  List<SpeechModel>? _missing;
  final _progress = <String, double>{};
  double? _micPeak;
  double _micLevel = -160;
  bool _checkingMic = false;
  bool _opening = false;
  String _openingStep = '';
  String? _openError;
  String _planSource = '';
  bool _held = false;

  SpokenEngines? _engines;
  SpokenRound? _round;
  String? _roundId;

  /// Off every time the screen opens; never remembered.
  bool _recordVideo = false;
  RoundVideo? _video;
  bool _typedRound = false;
  StreamSubscription<void>? _sub;
  final _typed = TextEditingController();

  /// Off at the start of every round; only its switches are remembered.
  late final _coach = CameraCoach(
    onPrefs: (p) =>
        unawaited(ref.read(sessionProvider).db.setLocalSetting(coachPrefsKey, jsonEncode(p.toJson()))),
  );

  ({String? programId, String? itemId}) get _key => (programId: widget.programId, itemId: widget.itemId);

  @override
  void initState() {
    super.initState();
    _refreshModels();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final db = ref.read(sessionProvider).db;
    final saved = await readLocalJson(db, roundSettingsKey);
    final coach = await readLocalJson(db, coachPrefsKey);
    if (!mounted) return;
    _coach.usePrefs(CoachPrefs.fromJson(coach));
    setState(() {
      if (saved['round'] case final Map r) _settings = RoundSettings.fromJson(r.cast<String, Object?>());
      if (saved['framework'] case final String f when frameworks.any((x) => x.id == f)) _framework = f;
    });
  }

  void _save({RoundSettings? settings, String? framework}) {
    setState(() {
      _settings = settings ?? _settings;
      _framework = framework ?? _framework;
    });
    unawaited(
      ref
          .read(sessionProvider)
          .db
          .setLocalSetting(
            roundSettingsKey,
            jsonEncode({'round': _settings.toJson(), 'framework': _framework}),
          ),
    );
  }

  /// Offline practice holds the guard while this screen is open.
  void _hold(bool on) {
    if (on && !_held) OfflineGuard.instance.hold();
    if (!on && _held) OfflineGuard.instance.release();
    _held = on;
  }

  @override
  void dispose() {
    _hold(false);
    _sub?.cancel();
    _typed.dispose();
    // A clip still recording is not kept; kept clips stay for their days.
    _video?.dispose();
    _coach.dispose();
    final round = _round, engines = _engines;
    // Recordings go when the round screen closes.
    unawaited(() async {
      await engines?.stopPlaying();
      await round?.deleteRecordings();
      await round?.close();
    }());
    super.dispose();
  }

  Future<void> _refreshModels() async {
    try {
      final SpokenEngines e = _engines ?? await ref.read(spokenEnginesProvider.future);
      _engines = e;
      final missing = await e.missing();
      if (mounted) setState(() => _missing = missing);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _openError = 'The speech engines are not available here: ${describeError(e)}');
      }
    }
  }

  bool get _offline => ref.watch(interviewDeviceProvider).value?.offline ?? false;

  Future<void> _download(SpeechModel m) async {
    final note = await ref.read(modelSharingProvider.future).catchError((_) => '');
    if (!mounted) return;
    final ok = await askSure(
      context,
      'Download ${m.label}?',
      '${formatBytes(m.bytes)} from ${Uri.parse(m.url).host} (${m.source}). Licence: ${m.licence}. It is '
          'checked against its published SHA-256 and kept on this device only. $note',
      action: 'Download ${formatBytes(m.bytes)}',
    );
    if (!ok || !mounted) return;
    setState(() => _progress[m.id] = 0);
    try {
      await _engines!.download(
        m,
        progress: (share) => mounted ? setState(() => _progress[m.id] = share) : null,
      );
    } on Object catch (e) {
      if (mounted) notify(context, describeError(e), status: KitStatus.warning);
    } finally {
      _progress.remove(m.id);
      await _refreshModels();
    }
  }

  Future<void> _checkMic() async {
    setState(() {
      _checkingMic = true;
      _micPeak = null;
    });
    try {
      final peak = await _engines!.micCheck(
        const Duration(seconds: 3),
        level: (db) => mounted ? setState(() => _micLevel = db) : null,
      );
      if (mounted) setState(() => _micPeak = peak);
    } on Object catch (e) {
      if (mounted) notify(context, describeError(e), status: KitStatus.warning);
    } finally {
      if (mounted) setState(() => _checkingMic = false);
    }
  }

  List<StudyItem> _chosen(InterviewSetup s) {
    final picked = _picked ?? _defaultPick(s);
    return [
      for (final d in s.drills)
        if (picked.contains(d.id)) d,
    ];
  }

  /// The drill asked for, else weak drills first, then ones not practised,
  /// up to three.
  Set<String> _defaultPick(InterviewSetup s) {
    if (widget.itemId case final id? when s.drills.any((d) => d.id == id)) return {id};
    int rank(StudyItem d) => switch (s.evidence[d.id]) {
      final e? when e.weak => 0,
      final e? when !e.practised => 1,
      null => 1,
      _ => 2,
    };
    final order = [...s.drills]..sort((a, b) => rank(a).compareTo(rank(b)));
    return {for (final d in order.take(3)) d.id};
  }

  Future<void> _start(InterviewSetup s, {required bool typed}) async {
    final drills = _chosen(s);
    if (drills.isEmpty) return notify(context, 'Pick at least one drill.');
    final offline = _offline;
    final settings = _settings;
    setState(() {
      _opening = true;
      _openingStep = 'Getting ready…';
      _openError = null;
    });
    try {
      final questions = [for (final d in drills) drillQuestionFor(d, s.topics[d.topicId], s.criteria)];
      final book = ref.read(sessionProvider).book;
      final roundId = await book.startRound(
        programId: s.programId,
        title: s.role,
        framework: _framework,
        settings: settings,
        questions: questions,
        criteria: s.criteria,
        typed: typed,
        today: today(),
      );
      final saved = (await book.savedRound(roundId))!;
      var plans = [for (final q in questions) templatePlan(q)];
      var source = 'Built-in follow-ups';
      final brain = settings.aiPlan ? await ref.read(interviewBrainProvider)(offline: offline) : null;
      if (brain != null) {
        if (mounted) setState(() => _openingStep = 'Planning the follow-ups…');
        try {
          final fromAi = await brain
              .planRound(role: s.role, questions: questions)
              .timeout(const Duration(seconds: 120));
          plans = mergePlans(questions, fromAi);
          source = 'Follow-ups planned by your AI';
        } on Object catch (e) {
          source = 'Built-in follow-ups (your AI did not answer: ${describeError(e)})';
        }
      }
      plans = withCriteria(questions, plans, saved.profile.criteria.isEmpty ? null : saved.profile);
      final persona = Persona.of(settings.persona);
      final level = Ladder.of(settings.level);
      final opening = roundOpening(persona, level);
      final interviewer = Interviewer(
        persona: persona,
        level: level,
        plans: plans,
        budgets: [for (final q in questions) answerBudget(q, level)],
        opening: opening,
      );
      final InterviewerVoice voice;
      final AnswerListener listener;
      final TakeStore takes;
      if (typed) {
        (voice, listener, takes) = (_SilentVoice(), _NoMicrophone(), _NoTakes());
      } else {
        if (mounted) setState(() => _openingStep = 'Loading the voice…');
        final e = _engines!;
        // Everything the voice may say, so its word list covers every word.
        (voice, listener) = await e.open([
          opening,
          for (final q in questions) q.question,
          for (final p in plans) ...p.probes.map((x) => x.text),
          for (final list in builtInProbes.values) ...list,
          ...persona.acknowledgements,
          persona.probeLead,
          interruptLine,
        ]);
        takes = await e.takes(roundId);
      }
      RoundVideo? video;
      if (!typed && _recordVideo) {
        if (_coach.feed case final RecordingFeed feed) {
          video = RoundVideo(
            roundId: roundId,
            recorder: feed.recorder,
            store: await ref.read(videoTakeStoreProvider.future),
          );
        } else if (mounted) {
          notify(context, 'The camera is off, so this round has no video.', status: KitStatus.warning);
        }
      }
      final round = SpokenRound(
        questions: [for (final q in questions) RoundQuestion(q.question, tests: q.why, lookFor: q.lookFor)],
        voice: voice,
        listener: listener,
        takes: takes,
        sink: _RoundSink(ref, roundId),
        interviewer: interviewer,
        video: video,
        endSilence: settings.endSilence,
      );
      if (!mounted) {
        video?.dispose();
        await round.close();
        return;
      }
      _sub = round.changes.listen((_) {
        if (round.phase == RoundPhase.finished) {
          if (_coach.on) unawaited(_coach.turnOff());
          unawaited(
            ref.mutate((s) => s.book.finishRound(roundId, now: DateTime.now().toUtc().toIso8601String())),
          );
        }
        // A typed round goes straight to the answer box.
        if (_typedRound && round.phase == RoundPhase.ready) unawaited(round.typeInstead());
        if (mounted) setState(() {});
      });
      _coach.roundStarted();
      setState(() {
        _round = round;
        _video = video;
        _roundId = roundId;
        _typedRound = typed;
        _planSource = source;
      });
      round.start();
      if (typed) await round.typeInstead();
    } on Object catch (e) {
      if (mounted) setState(() => _openError = 'The round did not start: ${describeError(e)}');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = _offline;
    _hold(offline);
    return Backdrop(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mock interview'),
          actions: [
            if (offline)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Center(child: StatusPill('Offline', icon: Icons.cloud_off)),
              ),
          ],
        ),
        body: AsyncView(
          ref.watch(interviewSetupProvider(_key)),
          builder: (s) => ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _round == null ? _setup(s, offline) : _during(_round!),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- before the round ----

  List<Widget> _setup(InterviewSetup s, bool offline) {
    final text = Theme.of(context).textTheme;
    final picked = _picked ?? _defaultPick(s);
    final setup = ref.watch(helpAiProvider).value ?? const HelpAiSetup();
    return [
      Text(s.role, style: text.titleLarge),
      const SizedBox(height: 4),
      Text(
        'The interviewer asks your drills aloud and writes down what you say, on this device. Audio recordings '
        'are deleted when you leave this screen; only the text is kept with the round, plus video if you turn '
        'it on below.',
        style: text.bodySmall,
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Drills to ask',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.drills.isEmpty) const Text('No interview drills here yet. Add drills to a topic first.'),
            for (final d in s.drills)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: picked.contains(d.id),
                title: Text(drillQuestion(d)),
                subtitle: Text(
                  [
                    if (drillCriterionText(d, s.criteria) case final c when c.isNotEmpty) 'Tests: $c',
                    if (s.evidence[d.id] case final e? when e.practised)
                      'last ${e.latest!.round()}/$drillMax',
                    if (s.evidence[d.id]?.weak ?? false) 'weak',
                  ].join(' · '),
                ),
                onChanged: (on) => setState(() {
                  final next = {...picked};
                  if (on ?? false) {
                    if (next.length >= maxRoundDrills) {
                      notify(context, 'A round asks at most $maxRoundDrills drills.');
                      return;
                    }
                    next.add(d.id);
                  } else {
                    next.remove(d.id);
                  }
                  _picked = next;
                }),
              ),
          ],
        ),
      ),
      _settingsCard(setup, offline),
      CameraSetupCard(_coach, offline: offline),
      _videoCard(),
      _before(s, offline),
    ];
  }

  Widget _settingsCard(HelpAiSetup setup, bool offline) {
    final r = _settings;
    final persona = Persona.of(r.persona);
    final level = Ladder.of(r.level);
    final fw = Framework.of(_framework);
    final muted = Theme.of(context).textTheme.bodySmall;
    final aiUsable = interviewAiUsable(setup, offline: offline);
    return SectionCard(
      title: 'The panel',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Choice<PersonaKind>(
            label: 'Panel',
            value: r.persona,
            options: {for (final p in personas.values) p.kind: p.label},
            onChanged: (v) => _save(settings: r.copyWith(persona: v)),
          ),
          Text(persona.about, style: muted),
          if (persona.silenceNote.isNotEmpty) Text(persona.silenceNote, style: muted),
          const SizedBox(height: 12),
          Choice<int>(
            label: 'Level',
            value: r.level,
            options: {for (final l in ladder) l.level: '${l.level} · ${l.label}'},
            onChanged: (v) => _save(settings: r.copyWith(level: v)),
          ),
          Text(level.about, style: muted),
          const SizedBox(height: 12),
          Choice<String>(
            label: 'Scored on',
            value: _framework,
            options: {for (final f in frameworks) f.id: f.name},
            onChanged: (v) => _save(framework: v),
          ),
          Text('${fw.about} $scaleCaveat', style: muted),
          const SizedBox(height: 12),
          Text('End an answer after ${r.endSilence.inSeconds} s of silence'),
          Slider(
            value: r.endSilence.inSeconds.toDouble(),
            min: RoundSettings.minSilence.inSeconds.toDouble(),
            max: RoundSettings.maxSilence.inSeconds.toDouble(),
            divisions: RoundSettings.maxSilence.inSeconds - RoundSettings.minSilence.inSeconds,
            label: '${r.endSilence.inSeconds} s',
            semanticFormatterCallback: (v) => '${v.round()} seconds of silence',
            onChanged: (v) => _save(
              settings: r.copyWith(endSilence: Duration(seconds: v.round())),
            ),
          ),
          Text('Shorter pauses to think never end your answer. You can always press Done.', style: muted),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Offline practice'),
            subtitle: const Text(
              'Nothing on this screen uses the network. Downloads are refused; only a local AI server on this '
              'computer may score.',
            ),
            value: offline,
            onChanged: (v) {
              final d = ref.read(interviewDeviceProvider).value ?? const InterviewDevice();
              unawaited(ref.read(interviewDeviceProvider.notifier).save(d.copyWith(offline: v)));
            },
          ),
          if (aiUsable)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Plan the follow-ups with my AI'),
              subtitle: const Text(
                'Only the questions are sent. The follow-up itself is chosen on this device from what your answer '
                'leaves out. Off: built-in follow-ups.',
              ),
              value: r.aiPlan,
              onChanged: (v) => _save(settings: r.copyWith(aiPlan: v)),
            ),
          const SizedBox(height: 4),
          Text(interviewAiNote(setup, offline: offline), style: muted),
        ],
      ),
    );
  }

  /// The per-round opt-in for video takes.
  Widget _videoCard() => ListenableBuilder(
    listenable: _coach,
    builder: (context, _) {
      final days = ref.watch(videoKeepDaysProvider).value ?? VideoTakeStore.defaultKeepDays;
      final camera = _coach.feed is RecordingFeed;
      final muted = Theme.of(context).textTheme.bodySmall;
      return SectionCard(
        title: 'Video of my answers (optional)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('record-video'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Record video for this round'),
              subtitle: Text(
                'Watch yourself back next to your words. Off at the start of every round. '
                '${videoTakePrivacy(days)}',
              ),
              value: _recordVideo && camera,
              onChanged: camera ? (v) => setState(() => _recordVideo = v) : null,
            ),
            if (!camera)
              Text(
                'Turn the camera on above first. The video uses the same camera and no second microphone.',
                style: muted,
              ),
          ],
        ),
      );
    },
  );

  static double _levelShare(double dbfs) => ((dbfs + 60) / 60).clamp(0.0, 1.0);

  Widget _before(InterviewSetup s, bool offline) {
    final missing = _missing;
    final ready = missing != null && missing.isEmpty;
    final peak = _micPeak;
    final sharing = ref.watch(modelSharingProvider).value;
    final canStart = !_opening && s.drills.isNotEmpty;
    return SectionCard(
      title: 'Before you start',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Speech models', style: Theme.of(context).textTheme.titleSmall),
          if (missing == null && _openError == null)
            const LinearProgressIndicator()
          else if (missing != null && missing.isEmpty)
            const Text('The interviewer voice, the speech detector and the transcriber are on this device.')
          else if (missing != null) ...[
            const Text(
              'Speaking needs these on this device. Each downloads only when you ask, from its publisher, and '
              'runs here with no network. You can type your answers without them.',
            ),
            if (offline)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(offlineDownloadMessage, style: TextStyle(color: KitStatus.warning.color)),
              ),
            for (final m in missing)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(m.label),
                subtitle: _progress.containsKey(m.id)
                    ? LinearProgressIndicator(value: _progress[m.id])
                    : Text('${formatBytes(m.bytes)} · ${m.licence}'),
                trailing: _progress.containsKey(m.id) || offline
                    ? null
                    : TextButton(
                        onPressed: () => _download(m),
                        child: Text('Download ${formatBytes(m.bytes)}'),
                      ),
              ),
          ],
          if (sharing != null && sharing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sharing, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (ready) ...[
            const SizedBox(height: 12),
            Text('Microphone', style: Theme.of(context).textTheme.titleSmall),
            const Text('Say a sentence at your normal volume for three seconds.'),
            if (_checkingMic)
              Semantics(
                label: 'Input level',
                child: LinearProgressIndicator(value: _levelShare(_micLevel), minHeight: 8),
              )
            else if (peak != null)
              Text(
                peak > -40
                    ? 'We can hear you (peak ${peak.toStringAsFixed(0)} dBFS).'
                    : 'Very quiet (peak ${peak.toStringAsFixed(0)} dBFS): move closer or check the input.',
                style: TextStyle(color: (peak > -40 ? KitStatus.good : KitStatus.warning).color),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _checkingMic ? null : _checkMic,
                icon: const Icon(Icons.mic_none),
                label: Text(peak == null ? 'Check the microphone' : 'Check again'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_openError case final e?) ...[
            Text(e, style: TextStyle(color: KitStatus.warning.color)),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: ready && canStart ? () => _start(s, typed: false) : null,
                icon: _opening
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.record_voice_over_outlined),
                label: Text(_opening ? _openingStep : 'Start speaking'),
              ),
              OutlinedButton.icon(
                onPressed: canStart ? () => _start(s, typed: true) : null,
                icon: const Icon(Icons.keyboard_outlined),
                label: const Text('Type my answers'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- the round ----

  List<Widget> _during(SpokenRound r) {
    if (r.phase == RoundPhase.finished) return [_finished(r)];
    final q = r.question;
    final t = Theme.of(context).textTheme;
    final iv = r.interviewer;
    return [
      CameraRoundBar(_coach),
      if (_video case final v?) _VideoBar(v),
      Text('Question ${r.index + 1} of ${r.questions.length}', style: t.labelLarge),
      if (iv != null)
        Text(
          '${iv.persona.label} panel · Level ${iv.level.level}, ${iv.level.label}'
          '${_planSource.isEmpty ? '' : ' · $_planSource'}',
          style: t.bodySmall,
        ),
      const SizedBox(height: 4),
      LinearProgressIndicator(value: (r.index + 1) / r.questions.length),
      const SizedBox(height: 12),
      SectionCard(
        title: 'The question',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(q.text, style: t.titleMedium),
            if (q.tests.isNotEmpty) Text('Tests: ${q.tests}', style: t.bodySmall),
            const SizedBox(height: 12),
            ..._controls(r),
            if (r.error case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(e, style: TextStyle(color: KitStatus.warning.color)),
              ),
          ],
        ),
      ),
      if (r.phase == RoundPhase.review && r.state.latest != null) ..._review(r),
    ];
  }

  List<Widget> _controls(SpokenRound r) {
    Widget row(List<Widget> buttons) => Wrap(spacing: 8, runSpacing: 8, children: buttons);
    final typeInstead = TextButton.icon(
      onPressed: r.typeInstead,
      icon: const Icon(Icons.keyboard_outlined),
      label: const Text('Type instead'),
    );
    final skip = TextButton(onPressed: r.skip, child: const Text('Skip'));
    final moveOn = TextButton(onPressed: r.moveOn, child: const Text('Move on'));
    final muted = Theme.of(context).textTheme.bodySmall;
    final followUp = [
      if (r.followingUp) ...[
        Text(r.wrappingUp ? 'Wrap-up' : 'Follow-up', style: Theme.of(context).textTheme.labelLarge),
        SelectableText(r.followUpQuestion, style: Theme.of(context).textTheme.titleSmall),
        if (r.wrappingUp) Text('One sentence: the result, and what it shows about you.', style: muted),
        const SizedBox(height: 8),
      ],
    ];
    switch (r.phase) {
      case RoundPhase.ready:
        return [
          row([
            FilledButton.icon(
              onPressed: r.ask,
              icon: const Icon(Icons.volume_up_outlined),
              label: Text(r.state.takes == 0 ? 'Ask me' : 'Ask again'),
            ),
            OutlinedButton.icon(
              onPressed: r.answerNow,
              icon: const Icon(Icons.mic_none),
              label: const Text('Answer without hearing it'),
            ),
            typeInstead,
            skip,
          ]),
        ];
      case RoundPhase.asking:
        final said = r.saying;
        return [
          Row(
            children: [
              const Icon(Icons.volume_up_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  said != null && said != r.question.text
                      ? '"$said"'
                      : 'The interviewer is asking… the microphone opens when the question ends.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          row([typeInstead, if (r.followingUp) moveOn, skip]),
        ];
      case RoundPhase.pausing:
        final quiet = r.interviewer?.persona.kind == PersonaKind.quiet;
        return [
          Text(quiet ? 'The panel is writing notes. Silence is normal.' : 'The panel is making a note…'),
          const SizedBox(height: 8),
          row([skip]),
        ];
      case RoundPhase.answering:
        final live = r.live;
        final budget = r.budget;
        final elapsed = live?.elapsed ?? Duration.zero;
        return [
          ...followUp,
          Text(
            'Listening · ${DeliveryMetrics.clock(elapsed)}'
            '${budget == null ? '' : ' of about ${DeliveryMetrics.clock(budget)}'}',
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Input level',
            child: LinearProgressIndicator(value: _levelShare(live?.level ?? -160), minHeight: 8),
          ),
          if (live != null && live.caption.isNotEmpty) ...[const SizedBox(height: 8), Text(live.caption)],
          if (budget != null && elapsed > budget)
            Text('Over the time: sum up and finish.', style: TextStyle(color: KitStatus.warning.color)),
          const SizedBox(height: 8),
          row([
            FilledButton.icon(onPressed: r.done, icon: const Icon(Icons.stop), label: const Text('Done')),
            typeInstead,
            if (r.followingUp) moveOn,
          ]),
        ];
      case RoundPhase.transcribing:
        return const [LinearProgressIndicator(), SizedBox(height: 4), Text('Writing it down…')];
      case RoundPhase.typing:
        return [
          ...followUp,
          TextField(
            controller: _typed,
            minLines: 4,
            maxLines: 12,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Your answer', alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          row([
            FilledButton(
              onPressed: () async {
                await r.submitTyped(_typed.text);
                if (r.phase != RoundPhase.typing) _typed.clear();
              },
              child: const Text('Save answer'),
            ),
            if (!_typedRound)
              TextButton.icon(
                onPressed: r.answerNow,
                icon: const Icon(Icons.mic_none),
                label: const Text('Answer by voice instead'),
              ),
            if (r.followingUp) moveOn else skip,
          ]),
        ];
      case RoundPhase.review:
        final last = r.index + 1 >= r.questions.length;
        return [
          row([
            FilledButton.icon(
              onPressed: r.next,
              icon: Icon(last ? Icons.flag_outlined : Icons.arrow_forward),
              label: Text(last ? 'Finish' : 'Next question'),
            ),
            OutlinedButton.icon(
              onPressed: _typedRound ? r.typeInstead : r.retake,
              icon: const Icon(Icons.replay),
              label: const Text('Answer again'),
            ),
          ]),
        ];
      case RoundPhase.finished:
        return const [];
    }
  }

  List<Widget> _review(SpokenRound r) {
    final s = r.state;
    final take = s.latest!;
    final t = Theme.of(context).textTheme;
    return [
      SectionCard(
        title: take.typed ? 'Your answer (typed)' : 'What you said (take ${take.number})',
        child: SelectableText(take.transcript),
      ),
      if (s.followUps.isNotEmpty || s.interrupted)
        SectionCard(
          title: s.interrupted ? 'Stopped to keep to time' : 'Follow-ups',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.interrupted)
                const Text(
                  'The interviewer stopped the answer at the time limit, as real panels do. The wrap-up is the '
                  'skill: one sentence with the result.',
                ),
              for (final f in s.followUps) ...[
                const SizedBox(height: 8),
                Text(f.kind == FollowUpKind.wrapUp ? 'Wrap-up: ${f.asked}' : f.asked, style: t.titleSmall),
                if (f.probe case final p?)
                  Text('Asked because the answer did not yet say ${p.element.meaning}.', style: t.bodySmall),
                SelectableText(f.take.transcript),
              ],
            ],
          ),
        ),
      if (r.coverage(r.index) case final c? when c.expected.isNotEmpty)
        SectionCard(
          title: 'What your answer covered',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Found in your words on this device, follow-ups included. Approximate: it reads words, not '
                'meaning. Scores come in the debrief.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in c.expected)
                    StatusPill(
                      c.heard.contains(e) ? '${e.label}: heard' : '${e.label}: not heard',
                      status: c.heard.contains(e) ? KitStatus.good : KitStatus.warning,
                    ),
                ],
              ),
            ],
          ),
        ),
      if (take.delivery case final d?)
        SectionCard(
          title: 'How you said it',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Measured on this device. Ranges most listeners find easy, not a score.',
                style: t.bodySmall,
              ),
              for (final x in d.readings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${x.label}: ${x.value} · ${switch (x.place) {
                      RangePlace.within => 'in the usual range',
                      RangePlace.below => 'below the usual range',
                      RangePlace.above => 'above the usual range',
                    }}',
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  Widget _finished(SpokenRound r) {
    final answered = r.states.where((s) => s.latest != null).length;
    return SectionCard(
      title: 'Round finished',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'You answered $answered of ${r.questions.length}. The text is saved with the round; the recordings '
            'are deleted when you leave this screen.',
          ),
          if (_video case final v? when v.saved.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${v.saved.length} video ${v.saved.length == 1 ? 'clip is' : 'clips are'} kept with this round. '
              'Watch them from the debrief. '
              '${videoTakePrivacy(ref.watch(videoKeepDaysProvider).value ?? VideoTakeStore.defaultKeepDays)}',
            ),
          ],
          if (_coach.setupNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Setup notes (not scored, not saved)', style: Theme.of(context).textTheme.titleSmall),
            for (final n in _coach.setupNotes) Text('• $n'),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _roundId == null
                  ? null
                  : () => Navigator.of(context)
                        .pushReplacement(MaterialPageRoute(builder: (_) => InterviewDebriefPage(_roundId!))),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('See the debrief'),
            ),
          ),
        ],
      ),
    );
  }
}

/// During a round with video on: the red "Recording video" pill while the
/// camera records, and why when it could not.
class _VideoBar extends StatelessWidget {
  const _VideoBar(this.video);
  final RoundVideo video;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: video,
    builder: (context, _) {
      final muted = Theme.of(context).textTheme.bodySmall;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (video.recording)
                  Semantics(
                    liveRegion: true,
                    label: 'Recording video',
                    excludeSemantics: true,
                    child: StatusPill(
                      'Recording video',
                      icon: Icons.fiber_manual_record,
                      status: KitStatus.critical,
                    ),
                  )
                else
                  const StatusPill('Video on for this round', icon: Icons.videocam_outlined, quiet: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    video.recording && video.recorder.pausesCues
                        ? 'Setup hints pause while this camera records.'
                        : 'Records only while the microphone is open.',
                    style: muted,
                  ),
                ),
              ],
            ),
            if (video.error case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(e, style: TextStyle(color: KitStatus.warning.color)),
              ),
          ],
        ),
      );
    },
  );
}
