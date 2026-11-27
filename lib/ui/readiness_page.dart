/// Job readiness screens (role study plan V6): the Readiness page for one
/// program and its compact card on Home. The rules live in
/// domain/readiness.dart.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/interview.dart';
import '../domain/readiness.dart';
import 'common.dart';
import 'dialogs.dart';
import 'framework_page.dart';
import 'interview_pages.dart';
import 'quiz_page.dart';
import 'topic_page.dart';
import 'zen.dart';

Future<void> openReadiness(BuildContext context, String programId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReadinessPage(programId)));

/// What the Readiness page shows: the program, its readiness and its
/// topics (for linking the learner's own criteria).
typedef ReadinessView = ({Program program, Readiness readiness, List<Topic> topics});

final readinessProvider = FutureProvider.family<ReadinessView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final p = await (db.select(
    db.learnPrograms,
  )..where((x) => x.id.equals(id) & x.deleted.not())).getSingleOrNull();
  if (p == null) return null;
  return (
    program: p,
    readiness: await book.readiness(id, today: ref.watch(todayProvider)),
    topics: (await book.programDrills(id)).topics,
  );
});

/// Home's readiness card: the program with the nearest interview, else the
/// latest role plan (see `pickReadinessProgram`); null when none has
/// criteria.
final homeReadinessProvider = FutureProvider<ReadinessView?>((ref) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final p = await book.readinessFocus(ref.watch(todayProvider));
  if (p == null) return null;
  return (
    program: p,
    readiness: await book.readiness(p.id, today: ref.watch(todayProvider)),
    topics: const <Topic>[],
  );
});

String _roleOf(Program p) => p.role.isNotEmpty ? p.role : p.title;

/// Runs a next action: opens the quiz, drill, topic or story bank.
Future<void> runReadinessAction(
  BuildContext context,
  WidgetRef ref,
  ReadinessAction a,
  String programId,
) async {
  switch (a.kind) {
    case ActionKind.quiz:
      final db = ref.read(sessionProvider).db;
      final q = await (db.select(db.learnItems)..where((i) => i.id.equals(a.id))).getSingleOrNull();
      if (q != null && context.mounted) await openQuiz(context, q);
    case ActionKind.drill:
      await openDrill(context, a.id);
    case ActionKind.topic:
      await openTopic(context, a.id);
    case ActionKind.story:
      await openStoryBank(context, programId: programId);
  }
}

/// A small coloured chip for a row's status.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final ReadinessStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (status) {
      ReadinessStatus.covered => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      ReadinessStatus.weak => (scheme.tertiaryContainer, scheme.onTertiaryContainer, Icons.error_outline),
      ReadinessStatus.missing => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.radio_button_unchecked,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(status.label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// One program's job readiness: a summary in counts, the next action for
/// the weakest essential row, then each criterion (essential, then
/// desirable) with its status and, opened, its evidence. Criteria can be
/// typed in by hand for a program without any from Udyoga.
class ReadinessPage extends ConsumerWidget {
  const ReadinessPage(this.programId, {super.key});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(readinessProvider(programId)),
      builder: (v) {
        if (v == null) return const Scaffold(body: Center(child: Text('This program was deleted.')));
        final r = v.readiness;
        final text = Theme.of(context).textTheme;
        final day = ref.watch(todayProvider);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Readiness'),
            actions: [
              IconButton(
                tooltip: 'Add a criterion',
                icon: const Icon(Icons.playlist_add),
                onPressed: () => criterionDialog(context, ref, programId, v.topics),
              ),
              IconButton(
                tooltip: 'Interview training',
                icon: const Icon(Icons.record_voice_over_outlined),
                onPressed: () => openBeforeInterview(context, programId),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_roleOf(v.program), style: text.titleLarge),
                      const SizedBox(height: 4),
                      Text(r.summary.text(day), key: const Key('readiness-summary'), style: text.titleMedium),
                      const SizedBox(height: 12),
                      if (r.rows.isNotEmpty) _Counts(r.summary),
                      DatePick(
                        label: 'Interview date',
                        value: r.summary.interviewDate,
                        onChanged: (d) => ref.mutate((s) => s.book.setInterviewDate(programId, d)),
                      ),
                      if (r.next case final a?)
                        SectionCard(
                          title: 'Next',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${a.criterion.essential ? 'Essential' : 'Desirable'}: ${a.criterion.body}',
                                style: text.bodyMedium,
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.arrow_forward),
                                  label: Text(a.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  onPressed: () => runReadinessAction(context, ref, a, programId),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (r.rows.isEmpty)
                        SectionCard(
                          title: 'No criteria yet',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Plans from Udyoga bring the role\'s essential and desirable criteria. Without '
                                'one, type in the rows of the person specification yourself.',
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.playlist_add),
                                  label: const Text('Add a criterion'),
                                  onPressed: () => criterionDialog(context, ref, programId, v.topics),
                                ),
                              ),
                            ],
                          ),
                        ),
                      for (final (title, rows) in [('Essential', r.essential), ('Desirable', r.desirable)])
                        if (rows.isNotEmpty)
                          SectionCard(
                            title: title,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [for (final row in rows) _Row(row, v)],
                            ),
                          ),
                      Text(
                        'Covered needs a strong piece of your own work from the last $freshDays days: a done '
                        'topic with a quiz of 70% or more, a practice task with evidence, a drill of 5/8 or '
                        'more, or a story with a done topic. Older or lower results count as weak. AI never '
                        'marks a row covered.',
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// The summary as number tiles that roll to new counts as evidence comes
/// in (still under reduced motion).
class _Counts extends StatelessWidget {
  const _Counts(this.s);
  final ReadinessSummary s;

  @override
  Widget build(BuildContext context) => StatGrid(
    children: [
      StatTile(
        label: 'Essential covered',
        icon: Icons.verified_outlined,
        value: s.essentialCovered,
        suffix: ' of ${s.essential}',
        caption: s.essential > 0 && s.essentialCovered == s.essential ? 'All covered' : null,
        status: s.essential > 0 && s.essentialCovered == s.essential ? KitStatus.good : null,
      ),
      StatTile(
        label: 'Essential weak',
        icon: Icons.trending_flat,
        value: s.essentialWeak,
        caption: s.essentialWeak > 0 ? 'Strengthen' : null,
        status: s.essentialWeak > 0 ? KitStatus.warning : null,
      ),
      StatTile(
        label: 'Essential missing',
        icon: Icons.help_outline,
        value: s.essentialMissing,
        caption: s.essentialMissing > 0 ? 'No evidence yet' : null,
        status: s.essentialMissing > 0 ? KitStatus.serious : null,
      ),
      StatTile(
        label: 'Desirable covered',
        icon: Icons.star_outline,
        value: s.desirableCovered,
        suffix: ' of ${s.desirable}',
      ),
    ],
  );
}

IconData _evidenceIcon(EvidenceKind k) => switch (k) {
  EvidenceKind.topic => Icons.menu_book_outlined,
  EvidenceKind.quiz => Icons.quiz_outlined,
  EvidenceKind.task => Icons.build_outlined,
  EvidenceKind.drill => Icons.record_voice_over_outlined,
  EvidenceKind.story => Icons.auto_stories_outlined,
  EvidenceKind.portfolio => Icons.work_outline,
  EvidenceKind.skill => Icons.trending_up,
  EvidenceKind.cv => Icons.description_outlined,
  EvidenceKind.framework => Icons.assessment_outlined,
};

class _Row extends ConsumerWidget {
  const _Row(this.row, this.v);
  final ReadinessRow row;
  final ReadinessView v;

  Future<void> _open(BuildContext context, WidgetRef ref, Evidence e) async {
    final db = ref.read(sessionProvider).db;
    switch (e.kind) {
      case EvidenceKind.topic || EvidenceKind.quiz || EvidenceKind.task:
        await openTopic(context, e.id);
      case EvidenceKind.drill:
        await openDrill(context, e.id);
      case EvidenceKind.story:
        await openStoryBank(context, programId: v.program.id);
      case EvidenceKind.portfolio:
        final p = await (db.select(db.learnPortfolio)..where((x) => x.id.equals(e.id))).getSingleOrNull();
        if (p != null && context.mounted) await portfolioDialog(context, ref, item: p);
      case EvidenceKind.skill:
        final k = await (db.select(db.learnSkills)..where((x) => x.id.equals(e.id))).getSingleOrNull();
        if (k != null && context.mounted) await skillDialog(context, ref, skill: k);
      case EvidenceKind.framework:
        await openFramework(context, v.program.id);
      case EvidenceKind.cv:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final c = row.criterion;
    return ExpansionTile(
      key: PageStorageKey('criterion-${c.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      title: Text(c.body),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusChip(row.status),
            Text(
              [
                ...row.reasons.map((r) => r.label),
                if (row.status == ReadinessStatus.missing) 'No evidence yet',
                '${row.evidence.where((e) => e.weight != EvidenceWeight.info).length} pieces',
                if (isOwnCriterion(c)) 'typed in by you' else if (c.source.isNotEmpty) 'from ${c.source}',
              ].join(' · '),
              style: text.bodySmall,
            ),
          ],
        ),
      ),
      children: [
        if (row.evidence.isEmpty)
          const Text('Nothing linked yet. Link a topic, add a drill that tests it, or link a story.'),
        for (final e in row.evidence)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(_evidenceIcon(e.kind)),
            title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(e.detail),
            onTap: e.kind == EvidenceKind.cv ? null : () => _open(context, ref, e),
          ),
        if (isOwnCriterion(c))
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
                onPressed: () => criterionDialog(context, ref, v.program.id, v.topics, criterion: c),
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
                onPressed: () async {
                  if (await askSure(context, 'Delete criterion?', c.body) && context.mounted) {
                    await ref.mutate((s) => s.book.deleteOwnCriterion(c));
                  }
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// Adds or edits one criterion typed in by hand (a row of the person
/// specification): its words, essential or desirable, and the program's
/// topics that work towards it.
Future<void> criterionDialog(
  BuildContext context,
  WidgetRef ref,
  String programId,
  List<Topic> topics, {
  Criterion? criterion,
}) async {
  final body = TextEditingController(text: criterion?.body);
  var essential = criterion?.essential ?? true;
  final linked = {
    for (final t in topics)
      if (criterion != null && t.criteria.split(',').map((s) => s.trim()).contains(criterion.ref)) t.id,
  };
  await showFormDialog(
    context,
    title: criterion == null ? 'Add a criterion' : 'Edit criterion',
    fields: (setState) => [
      Field(
        body,
        'What the job asks for',
        autofocus: criterion == null,
        lines: 2,
        hint: 'Experience of delivering training to adults',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Essential'),
        subtitle: Text(essential ? 'Must have to be shortlisted' : 'Desirable: nice to have'),
        value: essential,
        onChanged: (on) => setState(() => essential = on),
      ),
      if (topics.isNotEmpty) ...[
        Text('Topics that work towards it', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in topics)
              FilterChip(
                label: Text(t.title, overflow: TextOverflow.ellipsis),
                selected: linked.contains(t.id),
                onSelected: (on) => setState(() => on ? linked.add(t.id) : linked.remove(t.id)),
              ),
          ],
        ),
      ],
    ],
    onSave: () async {
      if (body.text.trim().isEmpty) return 'Type what the job asks for.';
      await ref.mutate(
        (s) => s.book.saveOwnCriterion(
          programId,
          id: criterion?.id,
          body: body.text,
          essential: essential,
          topicIds: linked.toList(),
        ),
      );
      return null;
    },
  );
}

/// Home's compact readiness card for one program: the role, the summary in
/// counts, and the next action.
class ReadinessCard extends ConsumerWidget {
  const ReadinessCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(homeReadinessProvider).value;
    if (v == null) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final next = v.readiness.next;
    return SectionCard(
      title: 'Ready for ${_roleOf(v.program)}?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(v.readiness.summary.text(day), style: t.bodyMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (next != null)
                FilledButton.icon(
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(next.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onPressed: () => runReadinessAction(context, ref, next, v.program.id),
                ),
              TextButton(
                onPressed: () => openReadiness(context, v.program.id),
                child: const Text('See every criterion'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
