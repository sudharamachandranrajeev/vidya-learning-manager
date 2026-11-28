import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/achievements.dart';
import '../domain/next_up.dart';
import '../domain/stats.dart';
import '../domain/udyoga_link.dart';
import 'charts.dart';
import 'common.dart';
import 'course_page.dart';
import 'dialogs.dart';
import 'focus_page.dart';
import 'next_up_card.dart';
import 'notes_page.dart';
import 'readiness_page.dart';
import 'ready_by_card.dart';
import 'review_page.dart';
import 'zen.dart';

String _greeting() {
  final h = DateTime.now().hour;
  return h < 5
      ? 'Rest well'
      : h < 12
      ? 'Good morning'
      : h < 18
      ? 'Good afternoon'
      : 'Good evening';
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: 'Vidya',
    banner: 'page.home',
    actions: [
      HintIconButton(
        'action.focus',
        icon: Icons.self_improvement,
        label: 'Focus',
        onPressed: () => openFocus(context),
      ),
      HintIconButton(
        'nav.home',
        icon: Icons.timer_outlined,
        label: 'Log study time',
        onPressed: () => logSessionDialog(context, ref),
      ),
    ],
    body: AsyncView(
      ref.watch(statsProvider),
      onRetry: () => ref.invalidate(statsProvider),
      builder: (s) => _Body(s),
    ),
  );
}

class _Body extends ConsumerWidget {
  const _Body(this.s);
  final Stats s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final streaks = ref.watch(showStreaksProvider).value ?? false;
    final unlocks = [...(ref.watch(unlocksProvider).value ?? const <Unlock>[])]
      ..sort((a, b) => b.day.compareTo(a.day));
    final byKey = {for (final a in achievements) a.key: a};
    final target = ref.watch(weekTargetProvider).value ?? 0;
    final sinceMonday = minutesThisWeek(s.sessions, s.today);
    final week = s.lastWeek;
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final labels = [
      for (var i = 6; i >= 0; i--) days[DateTime.parse('${addDays(s.today, -i)}T00:00:00').weekday - 1],
    ];
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 96 + MediaQuery.paddingOf(context).bottom),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BlurFadeIn(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_greeting()}.', style: t.headlineMedium),
                        const SizedBox(height: 4),
                        Text(
                          !streaks || s.streak == 0
                              ? 'One small step is enough to begin.'
                              : 'Unhurried, and unbroken for ${s.streak} ${s.streak == 1 ? 'day' : 'days'}.',
                          style: t.bodyLarge?.copyWith(color: muted(context)),
                        ),
                      ],
                    ),
                  ),
                ),
                const _OfferedPlans(),
                const BlurFadeIn(index: 1, child: NextUpCard()),
                const BlurFadeIn(index: 2, child: ReadinessCard()),
                const BlurFadeIn(index: 2, child: ReadyByHomeCard()),
                BlurFadeIn(index: 3, child: _LevelCard(s, streaks: streaks)),
                const SizedBox(height: 16),
                BlurFadeIn(index: 4, child: _Quests(s)),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'This week',
                  trailing: Text(
                    minutesText(week.fold(0, (a, b) => a + b)),
                    style: t.bodyMedium?.copyWith(color: muted(context)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      BarChart(values: week, labels: labels, unit: ' min', height: 90),
                      const SizedBox(height: 12),
                      if (target > 0) ...[
                        LinearProgressIndicator(value: (sinceMonday / target).clamp(0, 1).toDouble()),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                weekTargetText(sinceMonday, target),
                                style: t.bodyMedium?.copyWith(color: muted(context)),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Change weekly target',
                              icon: const Icon(Icons.tune),
                              onPressed: () => weekTargetDialog(context, ref, target),
                            ),
                          ],
                        ),
                      ] else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(Icons.flag_outlined),
                            label: const Text('Set a weekly time target'),
                            onPressed: () => weekTargetDialog(context, ref, 0),
                          ),
                        ),
                    ],
                  ),
                ),
                if (s.skills.any((k) => k.category == interviewCategory)) _InterviewReadiness(s),
                if (s.overdue.isNotEmpty)
                  SectionCard(
                    title: 'Past due',
                    child: Column(
                      children: [
                        for (final c in s.overdue)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.schedule, color: StatusColors.warning),
                            title: Text(c.title),
                            subtitle: Text(
                              'Was due ${relativeDay(c.due!, s.today)}. Move the date or let it go.',
                            ),
                            onTap: () =>
                                Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => CoursePage(c.id))),
                          ),
                      ],
                    ),
                  ),
                if (unlocks.isNotEmpty)
                  SectionCard(
                    title: 'Recently earned',
                    child: Column(
                      children: [
                        for (final u in unlocks.take(3))
                          if (byKey[u.id] case final a?)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(a.icon, color: clay),
                              title: Text(a.title),
                              subtitle: Text('${a.description} · ${relativeDay(u.day, s.today)}'),
                            ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Plans another app sent through sync, re-read after every write and
/// every sync that brings changes.
final _offeredProvider = FutureProvider<List<OfferedPlan>>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.offeredPlans();
});

/// A study plan from Udyoga, waiting to be added.
class _OfferedPlans extends ConsumerStatefulWidget {
  const _OfferedPlans();

  @override
  ConsumerState<_OfferedPlans> createState() => _OfferedPlansState();
}

class _OfferedPlansState extends ConsumerState<_OfferedPlans> {
  /// Put off until Vidya opens again.
  final _later = <String>{};

  @override
  Widget build(BuildContext context) {
    final offers = [
      for (final o in ref.watch(_offeredProvider).value ?? const <OfferedPlan>[])
        if (!_later.contains('${o.row.id}|${o.row.updated}')) o,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final o in offers)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SectionCard(
              title: isCareerFilePlan(o)
                  ? 'A study plan from your career file'
                  : 'A study plan from ${_appName(o.row.source)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${o.plan.title}: ${o.plan.courses.length} courses, ${o.plan.cards.length} review cards. '
                    'Adding it again later updates the same program; nothing is added twice.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add to Vidya'),
                        onPressed: () async {
                          final r = await ref.mutate(
                            (s) => s.book.addOfferedPlan(
                              o,
                              today: today(),
                              now: DateTime.now().toUtc().toIso8601String(),
                            ),
                          );
                          if (context.mounted) {
                            notify(
                              context,
                              '${o.plan.title}: ${r.courses} courses, ${r.topics} topics, ${r.cards} cards, '
                              '${r.skills} skills and ${r.notes} notes added.'
                              '${r.updatedCards > 0 ? ' ${r.updatedCards} changed cards updated, reviews kept.' : ''}'
                              '${retiredNote(r.retiredCards)}'
                              '${retiredItemsNote(r.retiredItems)}',
                            );
                          }
                        },
                      ),
                      TextButton(
                        onPressed: () => setState(() => _later.add('${o.row.id}|${o.row.updated}')),
                        child: const Text('Not now'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _appName(String id) =>
      id.isEmpty ? 'another app' : '${id[0].toUpperCase()}${id.substring(1)}';
}

class _LevelCard extends StatelessWidget {
  const _LevelCard(this.s, {required this.streaks});
  final Stats s;
  final bool streaks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // Each number rolls to its new value when it changes (still under
    // reduced motion).
    final stats = <(IconData, num, int, String)>[
      if (streaks) (Icons.local_fire_department_outlined, s.streak, 0, 'day streak'),
      (Icons.hourglass_bottom, s.hours, s.hours < 10 ? 1 : 0, 'hours'),
      (Icons.check_circle_outline, s.topicsDone, 0, 'topics'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 28,
          runSpacing: 20,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label: 'Level ${s.level}, ${(s.levelProgress * 100).round()} percent to the next',
              child: Ring(
                value: s.levelProgress,
                size: 132,
                stroke: 11,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${s.level}', style: t.displaySmall?.copyWith(fontSize: 38, height: 1)),
                    Text('level', style: t.labelMedium?.copyWith(color: muted(context))),
                  ],
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.rank, style: t.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '${s.xp - s.levelStart} of ${s.levelEnd - s.levelStart} to level ${s.level + 1}',
                    style: t.bodyMedium?.copyWith(color: muted(context)),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (final (icon, value, digits, label) in stats)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(icon, size: 18, color: muted(context)),
                              const SizedBox(height: 4),
                              RollingNumber(value, fractionDigits: digits, style: t.titleLarge),
                              Text(label, style: t.bodySmall?.copyWith(color: muted(context))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Quests extends ConsumerWidget {
  const _Quests(this.s);
  final Stats s;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Today’s quests',
    trailing: Text(
      '${s.quests.where((q) => q.done).length} of ${s.quests.length}',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: muted(context)),
    ),
    child: Column(
      children: [
        for (final q in s.quests)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              q.done ? Icons.check_circle : Icons.radio_button_unchecked,
              color: q.done ? Theme.of(context).colorScheme.primary : muted(context),
            ),
            title: Text(
              q.title,
              style: q.done ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
            ),
            subtitle: q.done || q.detail == null ? null : Text(q.detail!),
            trailing: Text('+${q.xp} xp', style: TextStyle(color: q.done ? null : clay)),
            onTap: q.done
                ? null
                : switch (q.id) {
                    'study' => () => openFocus(context),
                    'review' => () => startReview(context),
                    'note' => () => noteEditor(context, ref),
                    _ => null,
                  },
          ),
      ],
    ),
  );
}

/// The skill category and deck a plan from Udyoga (the career app) uses.
const interviewCategory = 'Interview', interviewDeck = 'Interview stories';

/// How ready the learner is to interview: each competency's level against
/// its target, and their own stories to rehearse on a spaced schedule.
class _InterviewReadiness extends StatelessWidget {
  const _InterviewReadiness(this.s);
  final Stats s;

  @override
  Widget build(BuildContext context) {
    final skills = s.skills.where((k) => k.category == interviewCategory).toList()
      ..sort((a, b) => (a.level / a.target).compareTo(b.level / b.target));
    final stories = s.cards.where((c) => c.deck == interviewDeck).length;
    final due = s.dueCards.where((c) => c.deck == interviewDeck).length;
    final t = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Interview readiness',
      trailing: due == 0
          ? null
          : FilledButton.tonalIcon(
              icon: const Icon(Icons.record_voice_over_outlined),
              label: Text('Rehearse $due'),
              onPressed: () => startReview(context, deck: interviewDeck),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            stories == 0
                ? 'Rate yourself on each competency on the Skills page as your stories get stronger.'
                : '$stories of your own stories to rehearse; say each one aloud in about two minutes. Rate '
                      'yourself on the Skills page as they get stronger.',
            style: t.bodyMedium?.copyWith(color: muted(context)),
          ),
          const SizedBox(height: 8),
          for (final k in skills.take(6))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(flex: 3, child: Text(k.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: LinearProgressIndicator(
                      value: k.target == 0 ? 0 : (k.level / k.target).clamp(0, 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${k.level}/${k.target}', style: t.labelMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
