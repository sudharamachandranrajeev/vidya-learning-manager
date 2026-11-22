/// The review screen for a video take (J7): the picture with your own
/// recording of the answer, the transcript line by line (tap a line to go
/// to it) and the criteria the question tested. A quoted line in the
/// debrief opens this screen at the moment it was said.
///
/// The video stays on this device: never synced, backed up or sent to an AI
/// (only the transcript text is). It is deleted after the number of days
/// set in Settings. Nothing here reads your face, expression or eyes.
library;

import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' as ie;

import '../app/interview_providers.dart';
import '../domain/spoken_interview.dart';
import 'interview_debrief_page.dart' show savedRoundProvider;
import 'mpv_loader.dart';
import 'video_playback.dart';
import 'zen.dart';

/// The privacy line shown wherever video takes are.
String videoTakePrivacy(int days) =>
    'On this device only, deleted after $days ${days == 1 ? 'day' : 'days'}. Never synced, backed up or sent '
    'to an AI: only the transcript is. Nothing reads your face, expression or eyes.';

/// Opens the review of question [question]'s video, at [at] when given.
Future<void> openVideoReview(BuildContext context, String roundId, int question, {ie.VideoSeek? at}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoReviewPage(roundId: roundId, question: question, at: at),
      ),
    );

/// Finds [quote] in the round's video takes and opens the review there.
/// Returns false when no video holds it.
Future<bool> openVideoAtQuote(BuildContext context, List<ie.VideoTake> takes, String quote) async {
  final seek = ie.seekToQuote(takes, quote);
  if (seek == null) return false;
  await openVideoReview(context, seek.take.roundId, seek.take.question, at: seek);
  return true;
}

String clipLabel(ie.VideoTake t) => t.part == 0 ? 'Take ${t.take}' : 'Take ${t.take}, follow-up ${t.part}';

class VideoReviewPage extends ConsumerStatefulWidget {
  const VideoReviewPage({super.key, required this.roundId, required this.question, this.at});
  final String roundId;
  final int question;
  final ie.VideoSeek? at;

  @override
  ConsumerState<VideoReviewPage> createState() => _VideoReviewPageState();
}

class _VideoReviewPageState extends ConsumerState<VideoReviewPage> {
  TakePlayback? _player;
  ie.VideoTake? _take;
  String? _error;
  bool _opening = false;

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }

  List<ie.VideoTake> _clips(List<ie.VideoTake> all) => [
    for (final t in all)
      if (t.question == widget.question) t,
  ]..sort((a, b) => a.take != b.take ? b.take.compareTo(a.take) : a.part.compareTo(b.part));

  Future<void> _open(ie.VideoTake t, {Duration? at}) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    final old = _player;
    _player = null;
    await old?.dispose();
    final p = ref.read(takePlaybackProvider)();
    try {
      await p.open(t);
      if (at != null) await p.seek(at);
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {
        _player = p;
        _take = t;
      });
    } on Object catch (e) {
      await p.dispose();
      if (mounted) {
        setState(() {
          _take = t;
          _error = e is MpvMissing
              ? MpvMissing.message
              : 'This video could not be played here: ${describeError(e)}';
        });
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _seekAudio(Duration audio) async {
    final t = _take, p = _player;
    if (t == null || p == null) return;
    await p.seek(t.videoAt(audio));
    await p.play();
  }

  @override
  Widget build(BuildContext context) {
    final takes = ref.watch(videoTakesProvider(widget.roundId));
    final days = ref.watch(videoKeepDaysProvider).value ?? ie.VideoTakeStore.defaultKeepDays;
    final round = ref.watch(savedRoundProvider(widget.roundId)).value;
    return Scaffold(
      appBar: AppBar(title: Text('Question ${widget.question + 1} · video')),
      body: AsyncView(
        takes,
        builder: (all) {
          final clips = _clips(all);
          if (clips.isEmpty) {
            return const Center(child: Text('No video of this answer is kept on this device.'));
          }
          if (_take == null && !_opening && _error == null) {
            final start = widget.at;
            final first = start != null
                ? clips.firstWhere((c) => c.id == start.take.id, orElse: () => clips.first)
                : clips.first;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _open(first, at: start != null && start.take.id == first.id ? start.video : null),
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (round != null && widget.question < round.questions.length)
                        Text(
                          round.questions[widget.question].question,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      const SizedBox(height: 4),
                      Text(videoTakePrivacy(days), style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      if (clips.length > 1)
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final c in clips)
                              ChoiceChip(
                                label: Text(clipLabel(c)),
                                selected: _take?.id == c.id,
                                onSelected: (_) => _open(c),
                              ),
                          ],
                        ),
                      const SizedBox(height: 8),
                      _screen(),
                      if (_take case final t?) ...[const SizedBox(height: 12), _transcript(t)],
                      if (round != null) _criteria(round),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _screen() {
    final p = _player;
    if (_error case final e?) {
      return SectionCard(
        title: 'Playback',
        child: Text(e, style: TextStyle(color: KitStatus.warning.color)),
      );
    }
    if (p == null) return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
    return SectionCard(
      title: clipLabel(_take!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 300,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
                child: Center(child: p.view() ?? const SizedBox()),
              ),
            ),
          ),
          ValueListenableBuilder<Duration>(
            valueListenable: p.position,
            builder: (context, pos, _) {
              final total = p.duration > pos ? p.duration : pos;
              return Row(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: p.playing,
                    builder: (context, on, _) => IconButton(
                      tooltip: on ? 'Pause' : 'Play',
                      icon: Icon(on ? Icons.pause : Icons.play_arrow),
                      onPressed: on ? p.pause : p.play,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: total.inMilliseconds == 0 ? 0 : pos.inMilliseconds / total.inMilliseconds,
                      semanticFormatterCallback: (_) => ie.DeliveryMetrics.clock(pos),
                      onChanged: total.inMilliseconds == 0
                          ? null
                          : (v) => p.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
                    ),
                  ),
                  Text('${ie.DeliveryMetrics.clock(pos)} / ${ie.DeliveryMetrics.clock(total)}'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _transcript(ie.VideoTake t) {
    final p = _player;
    Widget lines(Duration video) {
      final audio = t.audioAt(video);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tap a line to go to it.', style: Theme.of(context).textTheme.bodySmall),
          for (final (i, s) in t.segments.indexed)
            ListTile(
              key: Key('video-line-$i'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              selected: audio >= s.start && audio < s.end,
              leading: Text(ie.DeliveryMetrics.clock(t.videoAt(s.start))),
              title: Text(s.text),
              onTap: () => _seekAudio(s.start),
            ),
        ],
      );
    }

    return SectionCard(
      title: 'What you said',
      child: p == null
          ? lines(Duration.zero)
          : ValueListenableBuilder<Duration>(valueListenable: p.position, builder: (_, v, _) => lines(v)),
    );
  }

  Widget _criteria(SavedRound r) {
    final t = Theme.of(context).textTheme;
    final q = r.debriefRound.questions.where((x) => x.index == widget.question).firstOrNull;
    if (q == null) return const SizedBox.shrink();
    final coverage = {for (final c in r.debrief.coverage) c.criterion.id: c};
    final take = _take;
    return SectionCard(
      title: 'Criteria',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (q.question.why.isNotEmpty) Text('Tests: ${q.question.why}', style: t.bodySmall),
          for (final id in q.criteria)
            if (coverage[id] case final c?) ...[
              const SizedBox(height: 8),
              Text(c.criterion.text, style: t.titleSmall),
              Text(
                r.debrief.aiScored
                    ? '${(c.best?.level ?? r.framework.scale.noEvidence).code} · '
                          '${(c.best?.level ?? r.framework.scale.noEvidence).label}'
                    : c.status.label,
              ),
              if (c.best?.quote case final quote? when quote.isNotEmpty)
                InkWell(
                  onTap: take == null
                      ? null
                      : () {
                          final seek = ie.seekToQuote([take], quote);
                          if (seek != null) unawaited(_seekAudio(seek.audio));
                        },
                  child: Text('"$quote"', style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
                ),
            ],
        ],
      ),
    );
  }
}
