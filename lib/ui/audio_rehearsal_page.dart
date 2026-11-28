/// Hands-free review (C4): the on-device Kokoro voice reads each due card's
/// question, pauses, reads the answer, then waits for a tap grade or, when
/// chosen, moves on without grading. See `domain/audio_rehearsal.dart`.
library;

import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' show InterviewerVoice, SpeechModel, formatBytes;

import '../app/interview_providers.dart';
import '../app/providers.dart';
import '../db/database.dart';
import '../domain/audio_rehearsal.dart';
import '../domain/review.dart';
import '../domain/udyoga_link.dart' show ProgressReporter;
import 'common.dart';
import 'review_page.dart' show recordGrade;
import 'zen.dart';

Future<void> startAudioRehearsal(BuildContext context, {String? deck}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AudioRehearsalPage(deck: deck)));

/// Big enough for a thumb on a moving train.
const _target = Size(64, 64);

class AudioRehearsalPage extends ConsumerStatefulWidget {
  const AudioRehearsalPage({super.key, this.deck});
  final String? deck;

  @override
  ConsumerState<AudioRehearsalPage> createState() => _AudioRehearsalPageState();
}

class _AudioRehearsalPageState extends ConsumerState<AudioRehearsalPage> {
  List<Flashcard>? _cards;
  SpeechModel? _missing;
  var _checked = false, _opening = false;
  double? _progress;
  String? _error;
  InterviewerVoice? _voice;
  AudioRehearsal? _run;
  late final ProgressReporter _reporter;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(progressReporterProvider);
    ref.read(statsProvider.future).then((s) {
      if (mounted) {
        setState(
          () => _cards = [
            for (final c in s.dueCards)
              if (widget.deck == null || c.deck == widget.deck) c,
          ],
        );
      }
    });
    unawaited(_check());
  }

  Future<void> _check() async {
    try {
      final src = await ref.read(rehearsalVoiceProvider.future);
      final m = await src.missing();
      if (mounted) {
        setState(() {
          _missing = m;
          _checked = true;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = describeError(e);
          _checked = true;
        });
      }
    }
  }

  @override
  void dispose() {
    final run = _run, voice = _voice;
    if (run != null) {
      unawaited(run.stop().whenComplete(() => voice?.close()));
      run.removeListener(_changed);
      // The grades go back to Udyoga together, as after a typed review.
      if (run.graded > 0) unawaited(_reporter.request());
    } else {
      unawaited(voice?.close());
    }
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final run = _run;
    if (run == null) return;
    // Screen readers hear where it stands without looking.
    if (run.phase == RehearsalPhase.paused || run.phase == RehearsalPhase.done) {
      unawaited(SemanticsService.sendAnnouncement(View.of(context), _status(run), TextDirection.ltr));
    }
  }

  Future<void> _download(SpeechModel m) async {
    final ok = await askSure(
      context,
      'Download ${m.label}?',
      '${formatBytes(m.bytes)} from ${Uri.parse(m.url).host} (${m.source}). Licence: ${m.licence}. It is '
          'checked against its published SHA-256, kept on this device only and also used by the spoken '
          'interviewer. After that, hands-free review needs no network.',
      action: 'Download ${formatBytes(m.bytes)}',
    );
    if (!ok || !mounted) return;
    setState(() => _progress = 0);
    try {
      final src = await ref.read(rehearsalVoiceProvider.future);
      await src.download(m, progress: (p) => mounted ? setState(() => _progress = p) : null);
    } on Object catch (e) {
      if (mounted) notify(context, describeError(e), status: KitStatus.warning);
    } finally {
      if (mounted) setState(() => _progress = null);
      await _check();
    }
  }

  Future<void> _start() async {
    final cards = _cards;
    if (cards == null || cards.isEmpty || _opening) return;
    final choice =
        ref.read(rehearsalSettingsProvider).value ??
        (pauseSeconds: defaultRehearsalPause.inSeconds, autoAdvance: false);
    setState(() => _opening = true);
    try {
      final src = await ref.read(rehearsalVoiceProvider.future);
      final voice = _voice = await src.open([
        for (final c in cards) ...[spokenQuestion(c), spokenAnswer(c)],
      ]);
      if (!mounted) return;
      final run = AudioRehearsal(
        voice: voice,
        cards: cards,
        grade: (c, g) => recordGrade(ref, c, g),
        pause: Duration(seconds: choice.pauseSeconds),
        autoAdvance: choice.autoAdvance,
      )..addListener(_changed);
      setState(() => _run = run);
      unawaited(run.start());
    } on Object catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Backdrop(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            run == null || run.phase == RehearsalPhase.done ? 'Hands-free review' : '${run.left} left',
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (run == null)
                    _setup()
                  else if (run.phase == RehearsalPhase.done)
                    _summary(run)
                  else
                    _playing(run),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _setup() {
    final t = Theme.of(context).textTheme;
    final cards = _cards;
    final choice = ref.watch(rehearsalSettingsProvider).value;
    if (cards == null || !_checked || choice == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final missing = _missing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          cards.isEmpty ? 'Nothing due' : '${cards.length} ${cards.length == 1 ? 'card' : 'cards'} due',
          style: t.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          'The voice reads each question, pauses so you can answer in your head, then reads the answer. '
          'Tap a grade, or let it move on. Moving on never grades a card: it stays due. The voice runs on '
          'this device, with no network.',
          style: t.bodyLarge?.copyWith(color: muted(context)),
        ),
        const SizedBox(height: 20),
        if (_error case final e?)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              'The voice could not start: $e',
              style: t.bodyLarge?.copyWith(color: StatusColors.warning),
            ),
          ),
        if (missing != null) ...[
          Text(
            'Hands-free review needs the ${missing.label} voice on this device. It downloads only when you '
            'ask, then works offline.',
            style: t.bodyLarge,
          ),
          const SizedBox(height: 8),
          if (_progress != null)
            Semantics(
              label: 'Downloading the voice',
              value: '${((_progress ?? 0) * 100).round()} percent',
              child: LinearProgressIndicator(value: _progress),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: _target),
                onPressed: () => _download(missing),
                icon: const Icon(Icons.download_outlined),
                label: Text('Download ${formatBytes(missing.bytes)}'),
              ),
            ),
          const SizedBox(height: 20),
        ],
        Text('Pause before the answer: ${choice.pauseSeconds} seconds', style: t.titleMedium),
        Slider(
          value: choice.pauseSeconds.toDouble(),
          min: rehearsalPauseMin.toDouble(),
          max: rehearsalPauseMax.toDouble(),
          divisions: rehearsalPauseMax - rehearsalPauseMin,
          label: '${choice.pauseSeconds} s',
          semanticFormatterCallback: (v) => '${v.round()} seconds',
          onChanged: (v) => ref.read(rehearsalSettingsProvider.notifier).set(pauseSeconds: v.round()),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Move on by itself'),
          subtitle: Text(
            'After the answer, waits ${defaultAdvanceAfter.inSeconds} seconds for a grade, then goes to the next '
            'card without grading this one.',
          ),
          value: choice.autoAdvance,
          onChanged: (v) => ref.read(rehearsalSettingsProvider.notifier).set(autoAdvance: v),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: _target),
          onPressed: cards.isEmpty || missing != null || _opening ? null : _start,
          icon: const Icon(Icons.headphones_outlined),
          label: Text(_opening ? 'Loading the voice…' : 'Start listening'),
        ),
      ],
    );
  }

  String _status(AudioRehearsal run) => switch (run.phase) {
    RehearsalPhase.done =>
      '${run.graded} graded'
          '${run.notGraded.isEmpty ? '' : ', ${run.notGraded.length} not graded and still due'}.',
    final p => p.label,
  };

  Widget _playing(AudioRehearsal run) {
    final t = Theme.of(context).textTheme;
    final card = run.current;
    final showAnswer =
        run.phase == RehearsalPhase.answer || run.phase == RehearsalPhase.waiting || run.isPaused;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            _status(run),
            style: t.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        const SizedBox(height: 12),
        if (card != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(card.deck, style: t.labelLarge?.copyWith(color: muted(context))),
                  const SizedBox(height: 8),
                  Text(spokenQuestion(card), style: t.headlineSmall),
                  if (showAnswer) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Divider(color: hairline(context)),
                    ),
                    Text(spokenAnswer(card), style: t.titleMedium),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final g in Grade.values)
              if (g == Grade.good)
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: _target),
                  onPressed: run.canGrade ? () => run.gradeCurrent(g) : null,
                  child: Text(g.label),
                )
              else
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: _target),
                  onPressed: run.canGrade ? () => run.gradeCurrent(g) : null,
                  child: Text(g.label),
                ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: _target),
              onPressed: run.isPaused ? run.resume : run.pauseNow,
              icon: Icon(run.isPaused ? Icons.play_arrow : Icons.pause),
              label: Text(run.isPaused ? 'Resume' : 'Pause'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: _target),
              onPressed: () => unawaited(run.stop()),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summary(AudioRehearsal run) {
    final t = Theme.of(context).textTheme;
    final skipped = run.notGraded.length;
    return Column(
      children: [
        Icon(Icons.spa_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text('Done listening.', style: t.headlineSmall),
        const SizedBox(height: 6),
        Text(
          '${run.graded} graded.'
          '${skipped == 0 ? '' : ' $skipped not graded: ${skipped == 1 ? 'it keeps its' : 'they keep their'} '
                    'schedule and ${skipped == 1 ? 'is' : 'are'} still due.'}',
          style: t.bodyLarge?.copyWith(color: muted(context)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: _target),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
