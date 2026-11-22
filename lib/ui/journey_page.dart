/// The Journey page (plan format 3): one job's stages from deciding to
/// growing in the post. A timeline across the top highlights the stage the
/// learner is on; the stage below shows what to learn (each line with its
/// source and date, or labelled general advice), what to produce, how it is
/// checked, and heads-ups; the Research stage also holds the job's dossier
/// (dossier_view.dart). The learner moves stages by hand; Udyoga's
/// application status only suggests one. The rules live in
/// domain/journey.dart and domain/journey_book.dart.
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart' hide Pace;
import '../db/database.dart';
import '../domain/interview.dart';
import '../domain/journey.dart';
import '../domain/journey_book.dart';
import '../domain/spoken_interview.dart';
import 'common.dart';
import 'dossier_view.dart';
import 'quiz_page.dart';
import 'readiness_page.dart';
import 'spoken_interview_page.dart';
import 'zen.dart';

Future<void> openJourney(BuildContext context, String programId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => JourneyPage(programId)));

/// What the page shows: the program, its journey, the essential criteria
/// (for the coverage check), how many drills it has and its last finished
/// round with the interviewer.
typedef JourneyData = ({
  Program program,
  JourneyView? view,
  List<String> essentials,
  int drills,
  String? lastRound,
});

final journeyProvider = FutureProvider.family<JourneyData?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final p = await (db.select(
    db.learnPrograms,
  )..where((x) => x.id.equals(id) & x.deleted.not())).getSingleOrNull();
  if (p == null) return null;
  final rounds = (await book.savedRounds(programId: id)).where((r) => r.row.finished != null);
  return (
    program: p,
    view: await book.journeyView(id),
    essentials: [
      for (final c in await book.programCriteria(id))
        if (c.essential) c.body,
    ],
    drills: (await book.programDrills(id)).drills.length,
    lastRound: rounds.firstOrNull?.row.day,
  );
});

String _now() => DateTime.now().toUtc().toIso8601String();

class JourneyPage extends ConsumerStatefulWidget {
  const JourneyPage(this.programId, {super.key});
  final String programId;

  @override
  ConsumerState<JourneyPage> createState() => _JourneyPageState();
}

class _JourneyPageState extends ConsumerState<JourneyPage> {
  /// The stage open below the timeline; the current one until a tap.
  String? _open;

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(journeyProvider(widget.programId)),
      builder: (d) {
        if (d == null) return const Scaffold(body: Center(child: Text('This program was deleted.')));
        final v = d.view;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Journey'),
            actions: [
              IconButton(
                tooltip: 'Readiness',
                icon: const Icon(Icons.fact_check_outlined),
                onPressed: () => openReadiness(context, widget.programId),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: v == null ? _Start(d.program) : _body(context, d, v),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _body(BuildContext context, JourneyData d, JourneyView v) {
    final t = Theme.of(context).textTheme;
    final j = v.journey;
    final open = j.stage(_open ?? v.current) ?? j.stages.first;
    final role = j.role.isNotEmpty ? j.role : (d.program.role.isNotEmpty ? d.program.role : d.program.title);
    final day = ref.watch(todayProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(j.employer.isEmpty ? role : '$role at ${j.employer}', style: t.titleLarge),
        const SizedBox(height: 4),
        Text(
          [
            journeySectors[j.sector] ?? j.sector,
            if (j.closes != null) 'closes ${niceDate(j.closes!)} (${relativeDay(j.closes!, day)})',
            '${j.template} template, sources checked ${niceDate(j.checked)}',
          ].join(' · '),
          style: t.bodySmall,
        ),
        if (j.advertUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open the advert'),
              onPressed: () => openLink(context, j.advertUrl),
            ),
          ),
        const SizedBox(height: 8),
        if (v.suggested case final s?)
          SectionCard(
            title: 'Udyoga says: ${applicationStageLabel(j.applicationStage)}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Your application in Udyoga suggests the stage "${journeyStages[s]}".'),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const Key('journey-suggested'),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Move to ${journeyStages[s]}'),
                    onPressed: () => _move(s),
                  ),
                ),
              ],
            ),
          ),
        _Timeline(v, open: open.id, onTap: (id) => setState(() => _open = id)),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: paced(context, Pace.base),
          switchInCurve: Ease.out,
          switchOutCurve: Ease.out,
          transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
          child: _StageView(
            key: ValueKey('stage-${open.id}'),
            data: d,
            view: v,
            stage: open,
            onMove: () => _move(open.id),
          ),
        ),
      ],
    );
  }

  Future<void> _move(String stage) async {
    await ref.mutate((s) => s.book.setJourneyStage(widget.programId, stage, now: _now()));
    if (mounted) setState(() => _open = stage);
  }
}

/// Starts a journey for a program without one: the learner picks the kind
/// of employer, which picks the template.
class _Start extends ConsumerStatefulWidget {
  const _Start(this.program);
  final Program program;

  @override
  ConsumerState<_Start> createState() => _StartState();
}

class _StartState extends ConsumerState<_Start> {
  var _sector = 'nhs';

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Start a job journey',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'A journey walks you through one job, from deciding to apply to your first months in the post: what to '
          'learn at each stage, what to write, and how to check it. Plans from Udyoga start one by themselves.',
        ),
        const SizedBox(height: 12),
        Choice<String>(
          label: 'Kind of employer',
          value: _sector,
          options: journeySectors,
          onChanged: (v) => setState(() => _sector = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('journey-start'),
            onPressed: () => ref.mutate(
              (s) => s.book.startJourney(
                widget.program.id,
                role: widget.program.role.isNotEmpty ? widget.program.role : widget.program.title,
                sector: _sector,
                now: _now(),
              ),
            ),
            child: const Text('Start'),
          ),
        ),
      ],
    ),
  );
}

/// The stages in a row that scrolls sideways: the current stage is filled
/// and ringed, done stages are ticked, and the open one is outlined. The
/// row scrolls the current stage into view when it opens.
class _Timeline extends StatefulWidget {
  const _Timeline(this.v, {required this.open, required this.onTap});
  final JourneyView v;
  final String open;
  final ValueChanged<String> onTap;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  final _keys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _keys[widget.v.current]?.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final stages = widget.v.journey.stages;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, s) in stages.indexed) ...[
            if (i > 0) Container(width: 16, height: 2, color: scheme.outlineVariant),
            _dot(context, s, i, scheme, t),
          ],
        ],
      ),
    );
  }

  Widget _dot(BuildContext context, JourneyStage s, int i, ColorScheme scheme, TextTheme t) {
    final current = s.id == widget.v.current;
    final open = s.id == widget.open;
    final done = widget.v.of(s.id).doneFor(s);
    final chip = AnimatedContainer(
      key: _keys.putIfAbsent(s.id, GlobalKey.new),
      duration: paced(context, Pace.base),
      curve: Ease.out,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: current ? scheme.primaryContainer : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: open ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            done
                ? Icons.check_circle
                : current
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 16,
            color: current ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '${i + 1}. ${s.title}',
            style: t.labelLarge?.copyWith(color: current ? scheme.onPrimaryContainer : null),
          ),
        ],
      ),
    );
    return Semantics(
      selected: open,
      label: '${s.title}${current ? ', you are here' : ''}${done ? ', done' : ''}',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        key: Key('journey-stage-${s.id}'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => widget.onTap(s.id),
        child: current ? BorderBeam(radius: 20, child: chip) : chip,
      ),
    );
  }
}

/// One stage: learn, produce, check, heads-up.
class _StageView extends ConsumerWidget {
  const _StageView({
    super.key,
    required this.data,
    required this.view,
    required this.stage,
    required this.onMove,
  });
  final JourneyData data;
  final JourneyView view;
  final JourneyStage stage;
  final VoidCallback onMove;

  String get _pid => data.program.id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final p = view.of(stage.id);
    final day = ref.watch(todayProvider);
    final current = view.current == stage.id;
    var n = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(stage.title, style: t.headlineSmall)),
            if (current)
              const StatusPill('You are here', status: KitStatus.good)
            else
              OutlinedButton(
                key: const Key('journey-move'),
                onPressed: onMove,
                child: const Text('Move here'),
              ),
          ],
        ),
        if (stage.due case final due?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Aim to finish by ${niceDate(due)} (${relativeDay(due, day)})', style: t.bodySmall),
          ),
        const SizedBox(height: 12),
        if (stage.teach.isNotEmpty)
          BlurFadeIn(
            index: n++,
            child: SectionCard(
              title: 'Learn',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final l in stage.teach) _Line(l, today: day)],
              ),
            ),
          ),
        if (stage.id == 'research')
          BlurFadeIn(
            index: n++,
            child: SectionCard(
              title: 'Dossier',
              child: DossierSection(programId: _pid, journey: view.journey),
            ),
          ),
        if (stage.produce.isNotEmpty)
          BlurFadeIn(
            index: n++,
            child: SectionCard(
              title: 'Produce',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final a in stage.produce) _produce(context, ref, a, p)],
              ),
            ),
          ),
        if (stage.check case final c?)
          BlurFadeIn(
            index: n++,
            child: SectionCard(
              title: 'Check: ${journeyCheckKinds[c.kind]}',
              child: _CheckView(data: data, stage: stage, check: c, progress: p),
            ),
          ),
        if (stage.headsUp.isNotEmpty)
          BlurFadeIn(
            index: n++,
            child: SectionCard(
              title: 'Heads-up',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final l in stage.headsUp) _Line(l, today: day)],
              ),
            ),
          ),
      ],
    );
  }

  Widget _produce(BuildContext context, WidgetRef ref, JourneyProduce a, StageProgress p) {
    final note = p.notes[a.title];
    return CheckboxListTile(
      key: Key('journey-produce-${a.title}'),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: p.produced.containsKey(a.title),
      title: Text(a.title),
      subtitle: note == null ? null : Text(note, maxLines: 3, overflow: TextOverflow.ellipsis),
      secondary: IconButton(
        tooltip: note == null ? 'Add a note' : 'Edit the note',
        icon: Icon(note == null ? Icons.note_add_outlined : Icons.edit_note),
        onPressed: () => _noteDialog(context, ref, a, note),
      ),
      onChanged: (on) =>
          ref.mutate((s) => s.book.setProduced(_pid, stage.id, a.title, on ?? false, now: _now())),
    );
  }

  Future<void> _noteDialog(BuildContext context, WidgetRef ref, JourneyProduce a, String? note) async {
    final c = TextEditingController(text: note);
    await showFormDialog(
      context,
      title: a.title,
      fields: (_) => [
        Field(c, 'Note', lines: 6, autofocus: true, hint: 'Where it is kept, a link, or the text itself'),
      ],
      onSave: () async {
        await ref.mutate((s) => s.book.setProduceNote(_pid, stage.id, a.title, c.text, now: _now()));
        return null;
      },
    );
    c.dispose();
  }
}

/// A line to learn or a heads-up: its source and the day it was checked,
/// or a "general advice" label. A line past its date says to check it.
class _Line extends StatelessWidget {
  const _Line(this.line, {required this.today});
  final JourneyLine line;
  final String today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = line.source;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line.text),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (s == null)
                const StatusPill('General advice', quiet: true, dot: false)
              else
                InkWell(
                  onTap: () => openLink(context, s.url),
                  child: Text(
                    [
                      'Source: ${s.title.isNotEmpty ? s.title : Uri.tryParse(s.url)?.host ?? s.url}',
                      if (s.date.isNotEmpty) 'checked ${niceDate(s.date)}',
                    ].join(' · '),
                    style: t.bodySmall?.copyWith(decoration: TextDecoration.underline),
                  ),
                ),
              if (line.staleOn(today))
                const StatusPill('May be out of date: check the source', status: KitStatus.warning),
            ],
          ),
        ],
      ),
    );
  }
}

/// How the stage is checked, by kind.
class _CheckView extends ConsumerStatefulWidget {
  const _CheckView({required this.data, required this.stage, required this.check, required this.progress});
  final JourneyData data;
  final JourneyStage stage;
  final JourneyCheck check;
  final StageProgress progress;

  @override
  ConsumerState<_CheckView> createState() => _CheckViewState();
}

class _CheckViewState extends ConsumerState<_CheckView> {
  late final _draft = TextEditingController(text: widget.progress.draft);
  List<CoverageRow>? _rows;

  String get _pid => widget.data.program.id;
  String get _stage => widget.stage.id;

  @override
  void initState() {
    super.initState();
    if (widget.progress.draft.isNotEmpty) {
      _rows = coverageCheck(widget.progress.draft, widget.data.essentials);
    }
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = widget.check;
    final p = widget.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.prompt.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(c.prompt)),
        ...switch (c.kind) {
          'quiz' => _quiz(context),
          'interviewer' => _interviewer(context),
          'checklist' => _checklist(),
          'coverage' => _coverage(context, t),
          _ => const <Widget>[],
        },
        if (p.checkDone.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: StatusPill(
              ['Done ${niceDate(p.checkDone)}', if (p.checkResult.isNotEmpty) p.checkResult].join(' · '),
              status: KitStatus.good,
            ),
          )
        else if (p.checkResult.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: StatusPill(p.checkResult)),
        if (c.kind == 'self' || c.kind == 'interviewer')
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('journey-check-done'),
              onPressed: () => ref.mutate(
                (s) => s.book.setCheck(
                  _pid,
                  _stage,
                  day: p.checkDone.isEmpty ? ref.read(todayProvider) : '',
                  result: c.kind == 'interviewer' && widget.data.lastRound != null
                      ? 'last round ${niceDate(widget.data.lastRound!)}'
                      : '',
                  now: _now(),
                ),
              ),
              child: Text(p.checkDone.isEmpty ? 'Mark the check done' : 'Mark not done'),
            ),
          ),
      ],
    );
  }

  List<Widget> _quiz(BuildContext context) => [
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        key: const Key('journey-quiz'),
        icon: const Icon(Icons.quiz_outlined),
        label: Text('Take the quiz (${widget.check.questions.length} questions)'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => QuizPage(
              StudyItem(
                id: 'journey.$_pid.$_stage',
                hlc: '',
                deleted: false,
                topicId: '',
                type: 'quiz',
                title: 'Quiz: ${widget.stage.title}',
                url: '',
                source: '',
                licence: '',
                minutes: 0,
                required: false,
                ord: 0,
                stoppedAt: '',
                takeaway: '',
                evidence: '',
                ref: '',
                content: jsonEncode({'questions': widget.check.questions}),
                retired: '',
              ),
              onFinish: (right) async {
                final score = right.where((r) => r).length;
                final pass = right.isNotEmpty && score * 100 >= right.length * 70;
                await ref.mutate(
                  (s) => s.book.setCheck(
                    _pid,
                    _stage,
                    day: pass ? ref.read(todayProvider) : '',
                    result: '$score of ${right.length} right',
                    now: _now(),
                  ),
                );
                return (score: score, max: right.length, cards: 0);
              },
            ),
          ),
        ),
      ),
    ),
  ];

  List<Widget> _interviewer(BuildContext context) => [
    if (widget.data.drills == 0 && widget.data.essentials.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('No interview drills yet. Make one question for each essential criterion to start.'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('journey-make-drills'),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Make the drills'),
                onPressed: () async {
                  final n = await ref.mutate(
                    (s) => s.book.addCriterionDrills(_pid, today: ref.read(todayProvider)),
                  );
                  if (context.mounted) notify(context, '$n ${n == 1 ? 'drill' : 'drills'} added.');
                },
              ),
            ),
          ],
        ),
      ),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const Key('journey-interviewer'),
          icon: const Icon(Icons.record_voice_over_outlined),
          label: const Text('Practise with the interviewer'),
          onPressed: () => openSpokenInterview(context, programId: _pid),
        ),
        if (widget.data.lastRound case final d?) Text('Last round ${niceDate(d)}'),
      ],
    ),
  ];

  List<Widget> _checklist() => [
    for (final item in widget.check.items)
      CheckboxListTile(
        key: Key('journey-tick-$item'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: widget.progress.ticked.contains(item),
        title: Text(item),
        onChanged: (on) => ref.mutate(
          (s) => s.book.setTicked(_pid, _stage, item, on ?? false, items: widget.check.items, now: _now()),
        ),
      ),
  ];

  List<Widget> _coverage(BuildContext context, TextTheme t) {
    final essentials = widget.data.essentials;
    final words = wordCount(_draft.text);
    return [
      if (essentials.isEmpty)
        const Text(
          'This job has no essential criteria in Vidya yet. Add them on the Readiness page, then paste your '
          'draft here.',
        ),
      TextField(
        key: const Key('journey-draft'),
        controller: _draft,
        minLines: 4,
        maxLines: 14,
        maxLength: maxDraft,
        decoration: const InputDecoration(labelText: 'Your draft', alignLabelWithHint: true),
        onChanged: (_) => setState(() {}),
      ),
      if (essentials.isNotEmpty && words > 0)
        Text(
          '$words words: about ${(words / essentials.length).round()} for each essential criterion.',
          style: t.bodySmall,
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          key: const Key('journey-check-draft'),
          onPressed: essentials.isEmpty
              ? null
              : () async {
                  final rows = await ref.mutate(
                    (s) => s.book.checkDraft(_pid, _stage, _draft.text, essentials, now: _now()),
                  );
                  if (mounted) setState(() => _rows = rows);
                },
          child: const Text('Check the criteria'),
        ),
      ),
      if (_rows case final rows?) ...[
        const SizedBox(height: 8),
        for (final r in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(switch (r.coverage) {
              Coverage.exact => Icons.check_circle_outline,
              Coverage.partly => Icons.error_outline,
              Coverage.missing => Icons.radio_button_unchecked,
            }),
            title: Text(r.criterion),
            subtitle: Text(
              [
                r.coverage.label,
                if (r.coverage != Coverage.exact && r.missingWords.isNotEmpty)
                  'missing: ${r.missingWords.join(', ')}',
              ].join(' · '),
            ),
          ),
        Text(
          'A word check only: it shows whether each criterion\'s words are in your draft, not whether your '
          'example is strong.',
          style: t.bodySmall,
        ),
      ],
    ];
  }
}

/// The program page's way into its journey.
class JourneyTile extends ConsumerWidget {
  const JourneyTile(this.programId, {super.key});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(journeyProvider(programId)).value;
    final v = d?.view;
    // Only programs for a job offer a journey: one with a role, or one already started.
    if (d == null || (v == null && d.program.role.isEmpty)) return const SizedBox.shrink();
    final stage = v?.journey.stage(v.current);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('journey-tile'),
        leading: const Icon(Icons.route_outlined),
        title: const Text('Job journey'),
        subtitle: Text(
          v == null
              ? 'Every stage of this job, from applying to your first months.'
              : 'Stage ${stage!.order + 1} of ${v.journey.stages.length}: ${stage.title}'
                    '${v.suggested != null ? ' · Udyoga suggests ${journeyStages[v.suggested]}' : ''}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openJourney(context, programId),
      ),
    );
  }
}
