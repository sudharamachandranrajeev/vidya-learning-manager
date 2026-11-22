/// A spoken round's debrief (J3). With an AI: each criterion's score on
/// the framework's real scale, quoting your own words, with the anchor for
/// that level and for the next one up. The round is scored twice with the
/// criteria shuffled; where the runs disagree it says "uncertain, check
/// yourself". Disputing a score re-checks its quote and criterion and never
/// moves it on pushback. Without an AI: what each criterion's words covered,
/// read on this device, and your own rating on the four drill checks.
///
/// One strength (quoting the line that earned it) and one fix per answer;
/// never a single readiness percentage. Each answer shows what the panel,
/// the organisation and the manager expected, tied to a criterion or a
/// fact card, and what it did not cover. "Improve my answer" rewrites only
/// from your own words and story bank, and is refused when the rewrite adds
/// anything (J6). Results go to the drills (and so Job readiness); a fix
/// can go to spaced review and an answer to the story bank.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' as ie;

import '../app/interview_providers.dart';
import '../app/providers.dart';
import '../app/research_providers.dart';
import '../db/database.dart' show FactCard;
import '../domain/answer_checker.dart';
import '../domain/interview.dart';
import '../domain/spoken_interview.dart';
import 'common.dart';
import 'zen.dart';

final savedRoundProvider = FutureProvider.family<SavedRound?, String>((ref, id) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.savedRound(id);
});

final _storyBankProvider = FutureProvider<List<Story>>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.storyBank();
});

final savedRoundsProvider = FutureProvider.family<List<SavedRound>, String?>((ref, programId) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.savedRounds(programId: programId);
});

/// The program's past rounds, newest first, each opening its debrief.
class PastRounds extends ConsumerWidget {
  const PastRounds({super.key, this.programId, this.limit = 5});
  final String? programId;
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rounds = ref.watch(savedRoundsProvider(programId)).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rounds.take(limit))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(r.typed ? Icons.keyboard_outlined : Icons.record_voice_over_outlined),
            title: Text(
              '${niceDate(r.row.day)} · ${r.questions.length} '
              '${r.questions.length == 1 ? 'question' : 'questions'}',
            ),
            subtitle: Text(r.scored ? 'Scored on the ${r.framework.scale.name}' : 'Not scored by an AI'),
            onTap: () => openInterviewDebrief(context, r.id),
          ),
      ],
    );
  }
}

Future<void> openInterviewDebrief(BuildContext context, String roundId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => InterviewDebriefPage(roundId)));

class InterviewDebriefPage extends ConsumerStatefulWidget {
  const InterviewDebriefPage(this.roundId, {super.key});
  final String roundId;

  @override
  ConsumerState<InterviewDebriefPage> createState() => _InterviewDebriefPageState();
}

class _InterviewDebriefPageState extends ConsumerState<InterviewDebriefPage> {
  var _scoring = false;
  int? _improving;
  String? _scoreError;
  final _checks = <int, List<int?>>{};
  // Kept for the page's life: a dialog still animating out may read it.
  final _push = TextEditingController();

  @override
  void dispose() {
    _push.dispose();
    super.dispose();
  }

  bool get _offline => ref.watch(interviewDeviceProvider).value?.offline ?? false;

  Future<void> _score(SavedRound r) async {
    setState(() {
      _scoring = true;
      _scoreError = null;
    });
    final offline = _offline;
    var held = false;
    try {
      // Offline, even the local AI's connection is made under the guard.
      if (offline) {
        ie.OfflineGuard.instance.hold();
        held = true;
      }
      final brain = await ref.read(interviewBrainProvider)(offline: offline);
      if (brain == null) throw const FormatException('No AI may score here.');
      final runs = await ie.scoreTwice(
        brain: brain,
        role: r.row.title,
        framework: r.framework,
        round: r.debriefRound,
      );
      await ref.mutate((s) async {
        await s.book.saveRoundScoring(r.id, runs);
        final fresh = await s.book.savedRound(r.id);
        if (fresh != null) await s.book.recordRoundResults(fresh, today: today());
      });
      if (mounted) notify(context, 'Scored twice and saved on the drills.', status: KitStatus.good);
    } on Object catch (e) {
      if (mounted) setState(() => _scoreError = describeError(e));
    } finally {
      if (held) ie.OfflineGuard.instance.release();
      if (mounted) setState(() => _scoring = false);
    }
  }

  Future<void> _dispute(SavedRound r, ie.VerifiedScore score, String criterion) async {
    final push = _push..clear();
    final asked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Check this score again'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(criterion),
            const SizedBox(height: 8),
            const Text(
              'The check looks again at the quoted words and the criterion. Disagreeing does not change a score; '
              'answering again does.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: push,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'What do you think it missed? (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Check again')),
        ],
      ),
    );
    final pushback = push.text;
    if (asked != true || !mounted) return;
    final result = ie.recheckScore(
      score,
      round: r.debriefRound,
      scale: r.framework.scale,
      pushback: pushback,
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.stands ? 'The score stands' : 'The score is taken off'),
        content: Text(result.message),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _improve(SavedRound r, int i) async {
    final answer = r.answers[i] ?? '';
    final note = r.debrief.notes.where((n) => n.question == i).firstOrNull;
    final ids = r.debriefRound.asked[i] ?? const [];
    final criterion = [
      for (final c in r.debriefRound.criteria)
        if (ids.contains(c.id)) c.text,
    ].join('; ');
    setState(() => _improving = i);
    final offline = _offline;
    var held = false;
    ie.RewriteCheck? result;
    String? error;
    try {
      if (offline) {
        ie.OfflineGuard.instance.hold();
        held = true;
      }
      final brain = await ref.read(interviewBrainProvider)(offline: offline);
      if (brain == null) throw const FormatException('No AI may rewrite here.');
      final stories = await ref.read(_storyBankProvider.future);
      result = await ie.improveAnswer(
        brain: brain,
        question: r.questions[i].question,
        answer: answer,
        criterion: criterion,
        fix: note?.fix ?? '',
        storyBank: storyTexts(stories),
      );
    } on Object catch (e) {
      error = describeError(e);
    } finally {
      if (held) ie.OfflineGuard.instance.release();
      if (mounted) setState(() => _improving = null);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result?.ok == true ? 'Your answer, tightened' : 'No rewrite shown'),
        scrollable: true,
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result?.ok == true) ...[
                SelectableText(result!.text),
                const SizedBox(height: 8),
                const Text(
                  'Built only from your own words and your story bank: checked to add no number, name or '
                  'achievement you did not give. Say it in your own way; do not learn it by heart.',
                  style: TextStyle(fontSize: 12),
                ),
              ] else
                Text(error ?? result?.message ?? ''),
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _saveRatings(SavedRound r) async {
    final ready = {
      for (final e in _checks.entries)
        if (e.value.every((c) => c != null)) e.key: [for (final c in e.value) c!],
    };
    if (ready.isEmpty) return notify(context, 'Rate all four checks for an answer first.');
    final n = await ref.mutate((s) => s.book.recordRoundResults(r, selfChecks: ready, today: today()));
    if (mounted) {
      notify(context, 'Saved $n ${n == 1 ? 'rating' : 'ratings'} on the drills.', status: KitStatus.good);
    }
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(savedRoundProvider(widget.roundId)),
      builder: (r) {
        if (r == null) return const Scaffold(body: Center(child: Text('This round was deleted.')));
        return Scaffold(
          appBar: AppBar(
            title: const Text('Interview debrief'),
            actions: [
              IconButton(
                tooltip: 'Delete this round',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await askSure(
                        context,
                        'Delete this round?',
                        'Its text and scores are deleted. Results already saved on drills stay.',
                      ) &&
                      context.mounted) {
                    await ref.mutate((s) => s.book.deleteRound(r.id));
                    if (context.mounted) Navigator.of(context).maybePop();
                  }
                },
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _body(r)),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  List<Widget> _body(SavedRound r) {
    final t = Theme.of(context).textTheme;
    final d = r.debrief;
    final scale = r.framework.scale;
    final setup = ref.watch(helpAiProvider).value ?? const HelpAiSetup();
    final aiUsable = interviewAiUsable(setup, offline: _offline);
    final answered = [
      for (var i = 0; i < r.questions.length; i++)
        if ((r.answers[i] ?? '').trim().isNotEmpty) i,
    ];
    final pid = r.row.programId;
    final factCards = pid == null
        ? const <FactCard>[]
        : ref.watch(dossierProvider(pid)).value?.cards ?? const [];
    final expectations = {
      for (final e in ie.answerExpectations(
        round: r.debriefRound,
        framework: r.framework,
        verified: r.verified,
        cards: evidenceCards(factCards, today: today()),
      ))
        e.question: e,
    };
    return [
      Text(r.row.title, style: t.titleLarge),
      Text(
        '${niceDate(r.row.day)} · ${r.framework.name} · ${answered.length} of ${r.questions.length} answered',
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: d.aiScored ? 'Scored by your AI, twice' : 'Read from your words on this device',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              d.aiScored
                  ? 'Each score quotes your own words; a quote not in your answer is thrown out'
                        '${d.dropped > 0 ? ' (${d.dropped} were)' : ''}. The criteria were sent in a different '
                        'order each time. ${scale.passRule} ${ie.scaleCaveat}'
                  : 'Coverage reads words, not meaning, so it is approximate. ${interviewAiNote(setup, offline: _offline)}',
              style: t.bodySmall,
            ),
            if (!d.aiScored && aiUsable && answered.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _scoring ? null : () => _score(r),
                  icon: _scoring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.grading),
                  label: Text('Score on the scale with ${setup.via.label}'),
                ),
              ),
            ],
            if (_scoreError case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(e, style: TextStyle(color: KitStatus.warning.color)),
              ),
          ],
        ),
      ),
      SectionCard(
        title: 'Criteria',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (d.coverage.isEmpty) const Text('No answered question tested a criterion.'),
            for (final c in d.coverage) _criterion(r, c),
          ],
        ),
      ),
      for (final i in answered) _answer(r, i, expectations[i], aiUsable: aiUsable),
      if (!d.aiScored && answered.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _saveRatings(r),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save my ratings on the drills'),
          ),
        ),
    ];
  }

  Widget _criterion(SavedRound r, ie.CriterionCoverage c) {
    final t = Theme.of(context).textTheme;
    final scale = r.framework.scale;
    final best = c.best;
    final scored = r.debrief.aiScored;
    final level = best?.level ?? scale.noEvidence;
    final up = scale.next(level);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(c.criterion.text, style: t.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (scored)
                StatusPill(
                  '${level.code} · ${level.label}',
                  status: level == scale.noEvidence ? KitStatus.warning : KitStatus.info,
                )
              else
                StatusPill(
                  c.status.label,
                  status: switch (c.status) {
                    ie.Coverage.evidenced => KitStatus.good,
                    ie.Coverage.thin => KitStatus.warning,
                    ie.Coverage.missing => KitStatus.serious,
                  },
                ),
              if (c.uncertain) const StatusPill('Uncertain, check yourself', status: KitStatus.warning),
              if (c.criterion.essential) const StatusPill('Essential', quiet: true),
            ],
          ),
          if (c.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(c.note)),
          if (scored && best != null && best.quote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('"${best.quote}"', style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
            ),
          if (scored) ...[
            const SizedBox(height: 4),
            Text('This level: ${level.anchor}', style: t.bodySmall),
            if (up != null) Text('Next level (${up.code}): ${up.anchor}', style: t.bodySmall),
            if (best != null && best.level != scale.noEvidence)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _dispute(r, best, c.criterion.text),
                  child: const Text('Dispute this score'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _answer(SavedRound r, int i, ie.AnswerExpectations? expected, {required bool aiUsable}) {
    final t = Theme.of(context).textTheme;
    final q = r.questions[i];
    // One strength, quoting its line, and one fix: the engine's (rule 9).
    final note = r.debrief.notes.where((n) => n.question == i).firstOrNull;
    final strength = note?.strength ?? '';
    final strengthQuote = note?.strengthQuote ?? '';
    final fix = note?.fix ?? '';
    final checks = _checks.putIfAbsent(i, () => List<int?>.filled(drillChecks.length, null));
    final scale = r.framework.scale;
    final low = spokenAttempt(r, i);
    final nextAnchor = switch (low?.levels.values) {
      final codes? when codes.isNotEmpty =>
        scale
            .next(
              codes
                  .map((c) => scale.level(c) ?? scale.noEvidence)
                  .reduce((a, b) => scale.rank(a) <= scale.rank(b) ? a : b),
            )
            ?.anchor,
      _ => null,
    };
    return SectionCard(
      title: 'Question ${i + 1}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(q.question, style: t.titleSmall),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('What you said'),
            children: [SelectableText(r.answers[i] ?? '')],
          ),
          if (strength.isNotEmpty) Text('Strength: ${ie.taskLevelText(strength)}'),
          if (strengthQuote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Text(
                '"$strengthQuote"',
                key: Key('strength-quote-$i'),
                style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          if (fix.isNotEmpty) Text('Fix: ${ie.oneFix(fix)}'),
          if (expected != null) _Expectations(expected, key: Key('expectations-$i')),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (fix.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.style_outlined),
                  label: const Text('Add the fix to review'),
                  onPressed: () async {
                    await ref.mutate(
                      (s) => s.book.addFixToReview(
                        question: q.question,
                        fix: ie.taskLevelText(fix),
                        nextLevel: nextAnchor ?? '',
                        today: today(),
                      ),
                    );
                    if (mounted) notify(context, 'Added to review in the $interviewDeck deck.');
                  },
                ),
              if (aiUsable && ie.hasOwnAttempt(r.answers[i] ?? ''))
                OutlinedButton.icon(
                  key: Key('improve-$i'),
                  icon: _improving == i
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.edit_note),
                  label: const Text('Improve my answer'),
                  onPressed: _improving != null ? null : () => _improve(r, i),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_stories_outlined),
                label: const Text('Save as a story'),
                onPressed: () async {
                  await ref.mutate((s) => s.book.saveAnswerAsStory(r, i, today: today()));
                  if (mounted) {
                    notify(context, 'Saved to the story bank as a draft. Check it before you rely on it.');
                  }
                },
              ),
            ],
          ),
          if (!r.debrief.aiScored) ...[
            const SizedBox(height: 12),
            Text('Rate yourself', style: t.titleSmall),
            for (final (k, (_, label, help)) in drillChecks.indexed) ...[
              const SizedBox(height: 6),
              Text(label),
              Text(help, style: t.bodySmall),
              SegmentedButton<int>(
                key: Key('round-check-$i-$k'),
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('No')),
                  ButtonSegment(value: 1, label: Text('Partly')),
                  ButtonSegment(value: 2, label: Text('Yes')),
                ],
                selected: {?checks[k]},
                onSelectionChanged: (s) => setState(() => checks[k] = s.firstOrNull),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// What the panel, the organisation and the manager expected of one
/// answer: each covered one with the line that covered it, the rest as
/// not covered, and "no sources yet" where there are no cards.
class _Expectations extends StatelessWidget {
  const _Expectations(this.e, {super.key});
  final ie.AnswerExpectations e;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('What they expected'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in e.groups) ...[
          Text(g.source.label, style: t.titleSmall),
          Text(g.source.about, style: t.bodySmall),
          if (g.note.isNotEmpty) Text(g.note),
          for (final h in g.covered)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Covered: ${h.expectation.text}\n"${h.quote}"'),
            ),
          for (final h in g.notCovered)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Not covered: ${h.expectation.text}',
                style: TextStyle(color: KitStatus.warning.color),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
