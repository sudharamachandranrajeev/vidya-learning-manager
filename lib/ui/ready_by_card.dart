import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/time_fit.dart';
import 'common.dart';
import 'course_page.dart';
import 'dialogs.dart';
import 'learn_page.dart';
import 'zen.dart';

/// How many cut suggestions show before "and N more".
const _shownCuts = 5;

/// "Ready by" on a plan ([programId]) or a course with no plan
/// ([courseId]): the day to set, whether the study left fits before it at
/// the weekly hours, what to skim or drop when it does not, and the
/// outcome to log once the day has passed.
class ReadyByCard extends ConsumerWidget {
  const ReadyByCard({super.key, this.programId, this.courseId})
    : assert((programId == null) != (courseId == null));
  final String? programId, courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(statsProvider).value;
    final fits = ref.watch(timeFitsProvider).value;
    final data = ref.watch(readyByProvider).value;
    if (s == null || fits == null || data == null) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final program = programId == null ? null : s.programs.where((p) => p.id == programId).firstOrNull;
    final course = courseId == null ? null : s.courses.where((c) => c.id == courseId).firstOrNull;
    final own = program?.target ?? course?.due;
    final fit = fits.where((f) => f.goal.id == (programId ?? courseId)).firstOrNull;
    final waiting = fit != null && awaitingOutcome([fit.goal], data.outcomes, s.today).isNotEmpty;
    final logged = fit == null
        ? null
        : data.outcomes.where((o) => o.goalId == fit.goal.id && o.target == fit.goal.day).lastOrNull;
    return SectionCard(
      title: 'Ready by',
      hint:
          'Set the day of the interview or exam. Vidya checks whether what is left fits at your weekly '
          'hours, and keeps flashcard reviews before that day.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DatePick(
            label: programId != null ? 'Target date (interview or exam)' : 'Due date (interview or exam)',
            value: own,
            onChanged: (d) => ref.mutate((x) async {
              if (programId != null) {
                await x.book.setProgramTarget(programId!, d);
              } else {
                await x.book.setCourseDue(courseId!, d);
              }
              await x.book.pullReviewsBefore(s.today);
            }),
          ),
          if (fit != null && fit.goal.source == ReadyBySource.interview)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Using the interview date, ${niceDate(fit.goal.day)}, as it comes first.',
                style: t.bodyMedium?.copyWith(color: muted(context)),
              ),
            ),
          if (fit == null)
            Text(
              'No date set. Add one to see whether the plan fits.',
              style: t.bodyMedium?.copyWith(color: muted(context)),
            )
          else ...[
            if (waiting)
              _OutcomePrompt(fit.goal)
            else if (logged != null && fit.passed)
              Text('Outcome logged: ${logged.result.label}.', style: t.bodyMedium)
            else
              FitSummary(fit),
          ],
        ],
      ),
    );
  }
}

/// The fit's headline, the numbers behind it and what to cut.
class FitSummary extends ConsumerWidget {
  const FitSummary(this.fit, {super.key, this.showCuts = true});
  final TimeFit fit;
  final bool showCuts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cuts = fit.suggestions;
    final status = fit.passed || fit.isToday || fit.needed == 0
        ? null
        : fit.fits
        ? StatusColors.good
        : StatusColors.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: '${fit.headline} for ${niceDate(fit.goal.day)}',
          excludeSemantics: true,
          child: Row(
            children: [
              if (status != null) ...[
                Icon(fit.fits ? Icons.check_circle_outline : Icons.schedule, color: status),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(fit.headline, style: t.titleMedium)),
            ],
          ),
        ),
        if (fit.detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(fit.detail, style: t.bodyMedium?.copyWith(color: muted(context))),
        ],
        if (showCuts && cuts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('To make it fit, lowest weight first:', style: t.bodyMedium),
          const SizedBox(height: 4),
          for (final c in cuts.take(_shownCuts))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(child: Text('•  ', style: t.bodyMedium)),
                  Expanded(child: Text(suggestionText(c), style: t.bodyMedium)),
                ],
              ),
            ),
          if (cuts.length > _shownCuts)
            Text(
              'And ${cuts.length - _shownCuts} more.',
              style: t.bodyMedium?.copyWith(color: muted(context)),
            ),
          if (fit.shortAfter > 0)
            Text(
              'Still ${hoursText(fit.shortAfter)} short after these: topics towards an essential '
              'criterion are never suggested for dropping. Move the date or add weekly hours.',
              style: t.bodyMedium?.copyWith(color: muted(context)),
            ),
        ],
        if (!fit.passed && !fit.isToday)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('Change weekly hours'),
              onPressed: () => weekTargetDialog(context, ref, ref.read(weekTargetProvider).value ?? 0),
            ),
          ),
      ],
    );
  }
}

class _OutcomePrompt extends ConsumerWidget {
  const _OutcomePrompt(this.goal);
  final ReadyBy goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('How did ${niceDate(goal.day)} go?', style: t.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Log the outcome when you know it. It stays on this account and later shows how well '
          'readiness predicted it.',
          style: t.bodyMedium?.copyWith(color: muted(context)),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.flag_outlined),
            label: const Text('Log the outcome'),
            onPressed: () => outcomeDialog(context, ref, goal),
          ),
        ),
      ],
    );
  }
}

/// Asks how the real interview or exam on [goal]'s day went.
Future<void> outcomeDialog(BuildContext context, WidgetRef ref, ReadyBy goal) async {
  var result = OutcomeResult.passed;
  final percent = TextEditingController(), note = TextEditingController();
  await showFormDialog(
    context,
    title: 'Outcome: ${goal.title}',
    fields: (setState) => [
      Text('For ${niceDate(goal.day)} (the ${goal.source.label}).'),
      const SizedBox(height: 12),
      Choice<OutcomeResult>(
        label: 'How it went',
        value: result,
        options: {for (final r in OutcomeResult.values) r: r.label},
        onChanged: (v) => setState(() => result = v),
      ),
      Field(percent, 'Score in percent (optional)', number: true),
      Field(note, 'Note (optional)', lines: 2),
      if (result == OutcomeResult.didNotHappen)
        const Text('Set the new date on the plan or course afterwards, and the check starts again.'),
    ],
    onSave: () async {
      final p = percent.text.trim().isEmpty ? null : numberIn(percent);
      if (percent.text.trim().isNotEmpty && (p == null || p < 0 || p > 100)) {
        return 'The score must be a percent from 0 to 100.';
      }
      await ref.mutate(
        (s) => s.book.logOutcome(goal, result, today: today(), percent: p?.round(), note: note.text),
        report: false,
      );
      return null;
    },
  );
}

/// Home's "Ready by": outcomes waiting to be logged, then the next dated
/// goal's fit. Nothing when no goal has a date.
class ReadyByHomeCard extends ConsumerWidget {
  const ReadyByHomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fits = ref.watch(timeFitsProvider).value;
    final data = ref.watch(readyByProvider).value;
    if (fits == null || data == null || fits.isEmpty) return const SizedBox.shrink();
    final day = ref.watch(todayProvider);
    final t = Theme.of(context).textTheme;
    final waiting = awaitingOutcome([for (final f in fits) f.goal], data.outcomes, day);
    final next = fits.where((f) => f.goal.day.compareTo(day) >= 0).firstOrNull;
    if (waiting.isEmpty && next == null) return const SizedBox.shrink();
    void open(ReadyBy g) => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => g.programId != null ? ProgramPage(g.programId!) : CoursePage(g.courseId!),
      ),
    );
    return SectionCard(
      title: 'Ready by',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in waiting) ...[
            Text('${g.title}: how did ${niceDate(g.day)} go?', style: t.bodyLarge),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Log the outcome'),
                onPressed: () => outcomeDialog(context, ref, g),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (next != null) ...[
            Text(
              '${next.goal.title} · ${niceDate(next.goal.day)}',
              style: t.bodyLarge,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            FitSummary(next, showCuts: false),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => open(next.goal),
                child: Text(next.fits ? 'Open the plan' : 'See what to cut'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
