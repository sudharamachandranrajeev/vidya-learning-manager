/// The stage packs' tools on the Journey page (J8): email templates for
/// the contact, follow-up, after and offer stages; the offer checker; the
/// checks list with due dates; the joining kit (day-one list, who's who
/// and acronyms as flashcards, training); the first 90 days (30/60/90
/// plan, probation reviews, wins log, monthly check-in); and growing (PDR
/// prep, the next role's readiness). The rules live in
/// domain/stage_emails.dart, offer_checker.dart, stage_packs.dart and
/// stage_packs_book.dart.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart' hide Pace;
import '../domain/journey.dart';
import '../domain/journey_book.dart';
import '../domain/offer_checker.dart';
import '../domain/stage_emails.dart';
import '../domain/stage_packs.dart';
import '../domain/stage_packs_book.dart';
import 'common.dart';
import 'readiness_page.dart';
import 'zen.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

/// Whether Udyoga has sent a plan, so drafts can be handed to it.
final udyogaLinkedProvider = FutureProvider<bool>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.udyogaLinked();
});

/// The tool cards for [stage], titled; none for a stage without a pack.
List<(String, Widget)> stageTools(String programId, JourneyView view, JourneyStage stage) => [
  if (emailTemplatesFor(stage.id).isNotEmpty)
    (
      stage.id == 'contact' ? 'Contact templates' : 'Email templates',
      EmailTemplatesView(programId: programId, view: view, stage: stage.id),
    ),
  if (stage.id == 'offer') ('Offer checker', OfferCheckerView(programId: programId, view: view)),
  if (stage.id == 'checks') ('Your checks', ChecksView(programId: programId, view: view)),
  if (stage.id == 'joining') ('Joining kit', JoiningView(programId: programId, view: view)),
  if (stage.id == 'first-90-days')
    ('First 90 days and probation', NinetyDaysView(programId: programId, view: view)),
  if (stage.id == 'grow') ('Appraisal and the next role', GrowView(programId: programId, view: view)),
];

/// A line to learn or a heads-up: its source and the day it was checked,
/// or a "general advice" label. A line past its date says to check it.
class JourneyLineView extends StatelessWidget {
  const JourneyLineView(this.line, {super.key, required this.today});
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

Future<void> _copy(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) notify(context, '$what copied.', status: KitStatus.good);
}

// ---- email templates ----

class EmailTemplatesView extends ConsumerWidget {
  const EmailTemplatesView({super.key, required this.programId, required this.view, required this.stage});
  final String programId;
  final JourneyView view;
  final String stage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(todayProvider);
    final linked = ref.watch(udyogaLinkedProvider).value ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Short UK templates, filled in from this journey. Edit before you send: nothing is sent from Vidya.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('pack-fills'),
            icon: const Icon(Icons.badge_outlined),
            label: Text(view.fills.isEmpty ? 'Add your details' : 'Edit your details'),
            onPressed: () => _fillsDialog(context, ref),
          ),
        ),
        for (final t in emailTemplatesFor(stage))
          _TemplateTile(programId: programId, view: view, template: t, today: day, linked: linked),
      ],
    );
  }

  Future<void> _fillsDialog(BuildContext context, WidgetRef ref) async {
    final c = {for (final k in emailFills.keys) k: TextEditingController(text: view.fills[k])};
    await showFormDialog(
      context,
      title: 'Your details for the templates',
      fields: (_) => [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Kept in this journey only. Leave a field empty and the template shows [what goes there].',
          ),
        ),
        for (final e in emailFills.entries) Field(c[e.key]!, e.value),
      ],
      onSave: () async {
        await ref.mutate(
          (s) => s.book.setJourneyFills(programId, {
            for (final e in c.entries) e.key: e.value.text,
          }, now: _now()),
        );
        return null;
      },
    );
  }
}

class _TemplateTile extends ConsumerStatefulWidget {
  const _TemplateTile({
    required this.programId,
    required this.view,
    required this.template,
    required this.today,
    required this.linked,
  });
  final String programId;
  final JourneyView view;
  final EmailTemplate template;
  final String today;
  final bool linked;

  @override
  ConsumerState<_TemplateTile> createState() => _TemplateTileState();
}

class _TemplateTileState extends ConsumerState<_TemplateTile> {
  late FilledEmail _filled = _fill();
  late final _body = TextEditingController(text: _filled.body);

  FilledEmail _fill() => fillEmail(widget.template, widget.view.journey, widget.view.fills, date: niceDate);

  @override
  void didUpdateWidget(covariant _TemplateTile old) {
    super.didUpdateWidget(old);
    final next = _fill();
    // New details refill the text unless the learner has edited it.
    if (next.body != _filled.body && _body.text == _filled.body) _body.text = next.body;
    _filled = next;
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    final text = t.kind == 'email' && _filled.subject.isNotEmpty
        ? 'Subject: ${_filled.subject}\n\n${_body.text}'
        : _body.text;
    return ExpansionTile(
      key: Key('pack-template-${t.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Text(t.title),
      subtitle: t.optional ? const Text('Optional') : null,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in t.headsUp) JourneyLineView(l, today: widget.today),
        if (_filled.subject.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText('Subject: ${_filled.subject}'),
          ),
        TextField(
          key: Key('pack-template-body-${t.id}'),
          controller: _body,
          minLines: 4,
          maxLines: 16,
          decoration: const InputDecoration(labelText: 'Text (edit freely)', alignLabelWithHint: true),
          onChanged: (_) => setState(() {}),
        ),
        if (_filled.missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Still to fill: ${_filled.missing.map((k) => emailFills[k] ?? k).join(', ')}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: Key('pack-copy-${t.id}'),
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () => _copy(context, text, t.kind == 'email' ? 'Email' : 'Plan'),
            ),
            if (t.kind == 'email' && widget.linked)
              OutlinedButton.icon(
                key: Key('pack-udyoga-${t.id}'),
                icon: const Icon(Icons.forum_outlined),
                label: const Text('Open in Udyoga Conversations'),
                onPressed: () async {
                  await ref.mutate(
                    (s) => s.book.sendDraftToUdyoga(
                      template: t.id,
                      title: t.title,
                      subject: _filled.subject,
                      body: _body.text,
                      employer: widget.view.journey.employer,
                      role: widget.view.journey.role,
                      now: _now(),
                    ),
                  );
                  if (context.mounted) {
                    notify(
                      context,
                      'Sent to Udyoga as a draft. In Udyoga, open the conversation and press "From Vidya". '
                      'Nothing is sent until you send it.',
                      status: KitStatus.good,
                    );
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

// ---- offer checker ----

class OfferCheckerView extends ConsumerStatefulWidget {
  const OfferCheckerView({super.key, required this.programId, required this.view});
  final String programId;
  final JourneyView view;

  @override
  ConsumerState<OfferCheckerView> createState() => _OfferCheckerViewState();
}

class _OfferCheckerViewState extends ConsumerState<OfferCheckerView> {
  late final OfferFacts _saved = OfferFacts.fromJson(_map(widget.view.of('offer').pack['facts']));
  late final _c = {
    'band': TextEditingController(text: _saved.band),
    'point': TextEditingController(text: _saved.point?.toString() ?? ''),
    'salary': TextEditingController(text: _saved.salary?.toString() ?? ''),
    'hours': TextEditingController(text: _saved.hours?.toString() ?? ''),
    'probationMonths': TextEditingController(text: _saved.probationMonths?.toString() ?? ''),
    'startDate': TextEditingController(text: _saved.startDate),
    'noticeWeeks': TextEditingController(text: _saved.noticeWeeks?.toString() ?? ''),
    'relevantYears': TextEditingController(text: _saved.relevantYears?.toString() ?? ''),
    'fixedTermEnd': TextEditingController(text: _saved.fixedTermEnd),
    'rangeMin': TextEditingController(text: _saved.rangeMin?.toString() ?? ''),
    'rangeMax': TextEditingController(text: _saved.rangeMax?.toString() ?? ''),
  };
  late bool _promotion = _saved.promotion, _fixedTerm = _saved.fixedTerm;
  late List<OfferFinding>? _found = _saved.isEmpty ? null : _check(_saved);

  Journey get _j => widget.view.journey;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  OfferFacts get _facts => OfferFacts.fromJson({
    for (final e in _c.entries)
      if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
    'promotion': _promotion,
    'fixedTerm': _fixedTerm,
  });

  List<OfferFinding> _check(OfferFacts f) =>
      checkOffer(f, sector: _j.sector, employer: _j.employer, today: ref.read(todayProvider));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final uni = _j.sector == 'university';
    final table = uni ? gradeTableFor(_j.employer) : null;
    final cards = switch (_j.sector) {
      'nhs' => afcRuleCards,
      'university' => [?table?.card],
      _ => const <RuleCard>[],
    };
    final evidence = [
      for (final r in _rowsOf(widget.view.of('offer').pack['evidence']))
        {for (final e in r.entries) e.key: '${e.value}'},
    ];
    Widget field(String key, String label, {bool number = false, String? hint}) =>
        Field(_c[key]!, label, number: number, hint: hint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(notLegalAdvice, style: t.bodySmall),
        const SizedBox(height: 12),
        field('band', uni ? 'Grade' : 'Band or grade', hint: uni ? 'Grade 6' : 'Band 5'),
        field('point', 'Pay point or step offered (1 is the bottom)', number: true),
        field('salary', 'Full-time salary (£ a year)', number: true),
        if (uni && table == null) ...[
          field('rangeMin', 'Grade\'s lowest salary, from the university\'s pay page', number: true),
          field('rangeMax', 'Grade\'s highest salary', number: true),
        ],
        field('hours', 'Hours a week', number: true),
        field('probationMonths', 'Probation (months)', number: true),
        field('startDate', 'Start date', hint: 'yyyy-mm-dd'),
        field('noticeWeeks', 'Notice owed at your current job (weeks)', number: true),
        field('relevantYears', 'Completed years of relevant experience', number: true),
        SwitchListTile(
          key: const Key('offer-promotion'),
          contentPadding: EdgeInsets.zero,
          title: const Text('A move up a band or grade with the same kind of employer'),
          value: _promotion,
          onChanged: (v) => setState(() => _promotion = v),
        ),
        SwitchListTile(
          key: const Key('offer-fixed-term'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Fixed term'),
          value: _fixedTerm,
          onChanged: (v) => setState(() => _fixedTerm = v),
        ),
        if (_fixedTerm) field('fixedTermEnd', 'Fixed term ends', hint: 'yyyy-mm-dd'),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('offer-check'),
            onPressed: () async {
              final f = _facts;
              await ref.mutate((s) => s.book.setOfferFacts(widget.programId, f, now: _now()));
              if (mounted) setState(() => _found = _check(f));
            },
            child: const Text('Check the offer'),
          ),
        ),
        if (_found case final found?) ...[
          const SizedBox(height: 12),
          for (final f in found)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusPill(
                    f.kind.label,
                    status: switch (f.kind) {
                      FindingKind.normal => KitStatus.good,
                      FindingKind.ask => KitStatus.info,
                      FindingKind.watch => KitStatus.serious,
                      FindingKind.stale => KitStatus.warning,
                    },
                  ),
                  const SizedBox(height: 4),
                  JourneyLineView(f.line, today: day),
                ],
              ),
            ),
        ],
        if (cards.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Rule cards (${cards.length})'),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final c in cards) JourneyLineView(c.line, today: day)],
          ),
        ExpansionTile(
          key: const Key('offer-evidence'),
          tilePadding: EdgeInsets.zero,
          title: const Text('Evidence table for a higher starting point'),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'One row for each earlier role: dates, completed years and how it matches the new post. Paste it into '
              'the "starting pay point" email, before you accept.',
            ),
            const SizedBox(height: 8),
            SelectableText(evidenceTable(evidence), style: t.bodySmall?.copyWith(fontFamily: 'monospace')),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('offer-evidence-add'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a role'),
                  onPressed: () => _addRole(context, evidence),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy the table'),
                  onPressed: () => _copy(context, evidenceTable(evidence), 'Table'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _addRole(BuildContext context, List<Map<String, String>> rows) async {
    const labels = {
      'role': 'Role',
      'employer': 'Employer',
      'from': 'From (month and year)',
      'to': 'To',
      'years': 'Completed years',
      'match': 'How it matches the new post',
      'evidence': 'Evidence (contract, payslip, reference)',
    };
    final c = {for (final k in evidenceColumns) k: TextEditingController()};
    await showFormDialog(
      context,
      title: 'Add a role',
      fields: (_) => [for (final k in evidenceColumns) Field(c[k]!, labels[k]!)],
      onSave: () async {
        if (c['role']!.text.trim().isEmpty) return 'Give the role a title.';
        await ref.mutate(
          (s) => s.book.setEvidenceRows(widget.programId, [
            ...rows,
            {for (final e in c.entries) e.key: e.value.text},
          ], now: _now()),
        );
        return null;
      },
    );
  }
}

Map<String, Object?> _map(Object? v) =>
    v is Map ? {for (final e in v.entries) '${e.key}': e.value} : const {};

List<Map<String, Object?>> _rowsOf(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map) _map(r),
];

// ---- checks ----

class ChecksView extends ConsumerWidget {
  const ChecksView({super.key, required this.programId, required this.view});
  final String programId;
  final JourneyView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final j = view.journey;
    final checks = packChecks(j, view.of('checks').pack);
    final overdue = overdueChecks(checks, day);
    final fromUdyoga = checks.any((c) => c.fromUdyoga);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          fromUdyoga
              ? 'From your application in Udyoga. Change a check there; it updates here.'
              : 'Vidya\'s own list. If Udyoga tracks this application, its checklist shows here instead.',
          style: t.bodySmall,
        ),
        if (overdue.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: StatusPill(
              '${overdue.length} overdue: ${overdue.map((c) => c.title.split(':').first).join(', ')}',
              status: KitStatus.serious,
            ),
          ),
        const SizedBox(height: 8),
        for (final c in checks)
          ExpansionTile(
            key: Key('pack-check-${c.kind}'),
            tilePadding: EdgeInsets.zero,
            leading: Icon(switch (c.status) {
              'done' => Icons.check_circle,
              'not_needed' => Icons.remove_circle_outline,
              'sent' => Icons.outbox_outlined,
              _ => Icons.radio_button_unchecked,
            }),
            title: Text(c.title),
            subtitle: Text(
              [
                checkStatuses[c.status] ?? c.status,
                if (c.done != null) 'done ${niceDate(c.done!)}',
                if (c.due != null && c.open) 'due ${niceDate(c.due!)} (${relativeDay(c.due!, day)})',
                if (c.overdueOn(day)) 'OVERDUE',
              ].join(' · '),
            ),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final l in checkNotes(c.kind, j.sector)) JourneyLineView(l, today: day),
              if (!c.fromUdyoga) ...[
                Choice<String>(
                  label: 'Status',
                  value: c.status,
                  options: checkStatuses,
                  onChanged: (v) =>
                      ref.mutate((s) => s.book.setOwnCheck(programId, c.kind, status: v, now: _now())),
                ),
                DatePick(
                  label: 'Due',
                  value: c.due,
                  onChanged: (d) =>
                      ref.mutate((s) => s.book.setOwnCheck(programId, c.kind, due: d ?? '', now: _now())),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

// ---- joining ----

class JoiningView extends ConsumerWidget {
  const JoiningView({super.key, required this.programId, required this.view});
  final String programId;
  final JourneyView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final p = view.of('joining').pack;
    final j = view.journey;
    final dayOne = [
      for (final i in (p['dayOne'] is List ? p['dayOne'] as List : dayOneStarter))
        if (i is String) i,
    ];
    final ticked = {
      for (final i in (p['dayOneTicked'] is List ? p['dayOneTicked'] as List : const []))
        if (i is String) i,
    };
    final training = trainingRows(p['training']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Day one', style: t.titleMedium),
        const StatusPill('General advice: a starter list to make your own', quiet: true, dot: false),
        for (final i in dayOne)
          CheckboxListTile(
            key: Key('pack-day-one-$i'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: ticked.contains(i),
            title: Text(i),
            onChanged: (on) => ref.mutate((s) => s.book.setDayOne(programId, i, on ?? false, now: _now())),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add an item'),
            onPressed: () async {
              final v = await _ask(context, 'Add to the day-one list', 'Item');
              if (v == null) return;
              await ref.mutate((s) => s.book.setDayOne(programId, v, false, add: true, now: _now()));
            },
          ),
        ),
        const Divider(height: 24),
        _cardList(
          context,
          ref,
          list: 'people',
          title: 'Who\'s who',
          help: 'Names and roles you add become flashcards in "${peopleDeck(j)}", reviewed with the rest.',
          frontLabel: 'Name',
          backLabel: 'Role, and how you work with them',
          today: day,
        ),
        const Divider(height: 24),
        _cardList(
          context,
          ref,
          list: 'acronyms',
          title: 'Acronyms and systems',
          help: 'Each becomes a flashcard in "${acronymDeck(j)}".',
          frontLabel: 'Acronym or system',
          backLabel: 'What it means or does',
          today: day,
        ),
        const Divider(height: 24),
        Text('Mandatory training', style: t.titleMedium),
        for (final l in trainingNotes(j.sector)) JourneyLineView(l, today: day),
        if (training.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('pack-training-start'),
              icon: const Icon(Icons.playlist_add),
              label: const Text('Start from a common list'),
              onPressed: () => ref.mutate(
                (s) => s.book.setTraining(programId, [
                  for (final n in trainingStarter(j.sector)) (name: n, due: '', done: ''),
                ], now: _now()),
              ),
            ),
          ),
        for (final (k, r) in training.indexed)
          CheckboxListTile(
            key: Key('pack-training-${r.name}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: r.done.isNotEmpty,
            title: Text(r.name),
            subtitle: Text(
              r.done.isNotEmpty
                  ? 'Done ${niceDate(r.done)}'
                  : r.due.isEmpty
                  ? 'No due date'
                  : 'Due ${niceDate(r.due)} (${relativeDay(r.due, day)})',
              style: r.done.isEmpty && r.due.isNotEmpty && r.due.compareTo(day) < 0
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
            secondary: IconButton(
              tooltip: 'Set the due date',
              icon: const Icon(Icons.event),
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: DateTime.parse('${r.due.isEmpty ? day : r.due}T00:00:00'),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2040),
                );
                if (d == null) return;
                await ref.mutate(
                  (s) => s.book.setTraining(programId, [
                    for (final (i, x) in training.indexed)
                      i == k ? (name: x.name, due: isoDate(d), done: x.done) : x,
                  ], now: _now()),
                );
              },
            ),
            onChanged: (on) => ref.mutate(
              (s) => s.book.setTraining(programId, [
                for (final (i, x) in training.indexed)
                  i == k ? (name: x.name, due: x.due, done: (on ?? false) ? day : '') : x,
              ], now: _now()),
            ),
          ),
      ],
    );
  }

  Widget _cardList(
    BuildContext context,
    WidgetRef ref, {
    required String list,
    required String title,
    required String help,
    required String frontLabel,
    required String backLabel,
    required String today,
  }) {
    final rows = packCards(view.of('joining').pack[list]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Text(help, style: Theme.of(context).textTheme.bodySmall),
        for (final r in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(r.front),
            subtitle: Text(r.back),
            trailing: IconButton(
              tooltip: 'Remove from the list',
              icon: const Icon(Icons.close),
              onPressed: () =>
                  ref.mutate((s) => s.book.removePackCard(programId, list, r.front, now: _now())),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: Key('pack-add-$list'),
            icon: const Icon(Icons.add),
            label: Text('Add to $title'.replaceAll('Add to Who\'s who', 'Add a person')),
            onPressed: () async {
              final f = TextEditingController(), b = TextEditingController();
              await showFormDialog(
                context,
                title: title,
                fields: (_) => [Field(f, frontLabel, autofocus: true), Field(b, backLabel)],
                onSave: () async {
                  if (f.text.trim().isEmpty || b.text.trim().isEmpty) return 'Fill in both.';
                  await ref.mutate(
                    (s) => s.book.addPackCard(
                      programId,
                      list,
                      front: f.text,
                      back: b.text,
                      today: today,
                      now: _now(),
                    ),
                  );
                  return null;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<String?> _ask(BuildContext context, String title, String label) async {
  final c = TextEditingController();
  String? out;
  await showFormDialog(
    context,
    title: title,
    fields: (_) => [Field(c, label, autofocus: true)],
    onSave: () async {
      if (c.text.trim().isEmpty) return 'Type something first.';
      out = c.text.trim();
      return null;
    },
  );
  return out;
}

// ---- first 90 days ----

class NinetyDaysView extends ConsumerStatefulWidget {
  const NinetyDaysView({super.key, required this.programId, required this.view});
  final String programId;
  final JourneyView view;

  @override
  ConsumerState<NinetyDaysView> createState() => _NinetyDaysViewState();
}

class _NinetyDaysViewState extends ConsumerState<NinetyDaysView> {
  Map<String, Object?> get _p => widget.view.of('first-90-days').pack;
  late final _plan = {
    for (final k in plan90Parts.keys) k: TextEditingController(text: _p[k] is String ? _p[k] as String : ''),
  };
  final _win = TextEditingController();

  @override
  void dispose() {
    for (final c in _plan.values) {
      c.dispose();
    }
    _win.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final j = widget.view.journey;
    final offer = OfferFacts.fromJson(_map(widget.view.of('offer').pack['facts']));
    final months = offer.probationMonths ?? usualProbationMonths;
    final reviews = probationReviews(offer.startDate, months);
    final last = _p['lastCheckIn'] is String ? _p['lastCheckIn'] as String : '';
    final next = nextCheckIn(last: last, start: offer.startDate);
    final log = wins(_p['wins']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('30/60/90-day plan', style: t.titleMedium),
        const StatusPill('General advice: a template to make your own', quiet: true, dot: false),
        const SizedBox(height: 8),
        for (final e in plan90Parts.entries) Field(_plan[e.key]!, e.value, lines: 3),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            key: const Key('pack-plan90-save'),
            onPressed: () async {
              await ref.mutate(
                (s) => s.book.setPlan90(widget.programId, {
                  for (final e in _plan.entries) e.key: e.value.text,
                }, now: _now()),
              );
              if (context.mounted) notify(context, 'Plan saved.', status: KitStatus.good);
            },
            child: const Text('Save the plan'),
          ),
        ),
        const Divider(height: 24),
        Text('Probation', style: t.titleMedium),
        for (final l in probationNotes(j.sector)) JourneyLineView(l, today: day),
        if (reviews.isEmpty)
          const Text('Add your start date in the offer checker to see review dates.')
        else ...[
          Text('A $months-month probation from ${niceDate(offer.startDate)}:', style: t.bodySmall),
          for (final r in reviews)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.event_note_outlined),
              title: Text(r.label),
              subtitle: Text('${niceDate(r.day)} (${relativeDay(r.day, day)})'),
            ),
          const StatusPill(
            'General advice: your employer\'s policy sets the real dates',
            quiet: true,
            dot: false,
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Prepare for a probation review'),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final q in probationPrompts)
              ListTile(dense: true, leading: const Icon(Icons.arrow_right), title: Text(q)),
          ],
        ),
        const Divider(height: 24),
        Text('Weekly wins and evidence', style: t.titleMedium),
        Text(
          'Each win can go to your story bank, ready for your review and your next interview.',
          style: t.bodySmall,
        ),
        TextField(
          key: const Key('pack-win'),
          controller: _win,
          decoration: const InputDecoration(labelText: 'This week\'s win: what you did and what changed'),
          minLines: 1,
          maxLines: 4,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('pack-win-add'),
            icon: const Icon(Icons.add),
            label: const Text('Log it'),
            onPressed: () async {
              final text = _win.text;
              if (text.trim().isEmpty) return;
              await ref.mutate((s) => s.book.addWin(widget.programId, text, now: _now()));
              _win.clear();
            },
          ),
        ),
        for (final w in log.reversed)
          ListTile(
            key: Key('pack-win-${w.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(w.text),
            subtitle: Text(w.day.isEmpty ? '' : niceDate(w.day)),
            trailing: w.story.isNotEmpty
                ? const StatusPill('In the story bank', status: KitStatus.good)
                : TextButton(
                    key: Key('pack-win-story-${w.id}'),
                    onPressed: () async {
                      await ref.mutate(
                        (s) => s.book.winToStory(
                          widget.programId,
                          w.id,
                          today: ref.read(todayProvider),
                          now: _now(),
                        ),
                      );
                      if (!context.mounted) return;
                      notify(context, 'Added to your story bank.', status: KitStatus.good);
                    },
                    child: const Text('To story bank'),
                  ),
          ),
        const Divider(height: 24),
        Text('Monthly check-in', style: t.titleMedium),
        Text(
          next == null
              ? 'Add your start date in the offer checker; the first check-in falls a month later.'
              : 'Next check-in ${niceDate(next)} (${relativeDay(next, day)}). Review reminders, when on, include it.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('pack-check-in'),
            icon: const Icon(Icons.event_available_outlined),
            label: const Text('Do the check-in'),
            onPressed: () => _checkIn(context),
          ),
        ),
      ],
    );
  }

  Future<void> _checkIn(BuildContext context) async {
    final c = {for (final q in checkInPrompts) q: TextEditingController()};
    await showFormDialog(
      context,
      title: 'Monthly check-in',
      fields: (_) => [for (final q in checkInPrompts) Field(c[q]!, q, lines: 2)],
      onSave: () async {
        await ref.mutate(
          (s) => s.book.doCheckIn(
            widget.programId,
            {for (final e in c.entries) e.key: e.value.text},
            day: ref.read(todayProvider),
            now: _now(),
          ),
        );
        return null;
      },
    );
  }
}

// ---- grow ----

class GrowView extends ConsumerStatefulWidget {
  const GrowView({super.key, required this.programId, required this.view});
  final String programId;
  final JourneyView view;

  @override
  ConsumerState<GrowView> createState() => _GrowViewState();
}

class _GrowViewState extends ConsumerState<GrowView> {
  Map<String, Object?> get _p => widget.view.of('grow').pack;
  late final _pdr = {
    for (final k in pdrPrompts.keys) k: TextEditingController(text: '${_map(_p['pdr'])[k] ?? ''}'),
  };
  final _title = TextEditingController(), _criteria = TextEditingController();

  @override
  void dispose() {
    for (final c in [..._pdr.values, _title, _criteria]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    final next = _p['nextProgram'] is String ? _p['nextProgram'] as String : '';
    final winCount = wins(widget.view.of('first-90-days').pack['wins']).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in growNotes) JourneyLineView(l, today: day),
        Text('Appraisal (PDR) preparation', style: t.titleMedium),
        if (winCount > 0)
          Text('Your wins log has $winCount ${winCount == 1 ? 'entry' : 'entries'} to draw on.'),
        const SizedBox(height: 8),
        for (final e in pdrPrompts.entries) Field(_pdr[e.key]!, e.value, lines: 3),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonal(
              key: const Key('pack-pdr-save'),
              onPressed: () async {
                await ref.mutate(
                  (s) => s.book.setPdr(widget.programId, {
                    for (final e in _pdr.entries) e.key: e.value.text,
                  }, now: _now()),
                );
                if (context.mounted) notify(context, 'Saved.', status: KitStatus.good);
              },
              child: const Text('Save'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () => _copy(
                context,
                [for (final e in pdrPrompts.entries) '${e.value}\n${_pdr[e.key]!.text.trim()}'].join('\n\n'),
                'Preparation',
              ),
            ),
          ],
        ),
        const Divider(height: 24),
        Text('Ready for the next role?', style: t.titleMedium),
        if (next.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('pack-next-readiness'),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text('Readiness for ${_p['nextTitle'] ?? 'the next role'}'),
              onPressed: () => openReadiness(context, next),
            ),
          )
        else ...[
          const Text(
            'Paste the next band\'s or grade\'s person specification, one criterion a line. Vidya measures you '
            'against it with the same evidence: stories, drills and portfolio.',
          ),
          const SizedBox(height: 8),
          Field(_title, 'Next role\'s title'),
          Field(_criteria, 'Its criteria, one a line ("Desirable:" or "(D)" for desirable ones)', lines: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('pack-next-start'),
              onPressed: () async {
                final id = await ref.mutate(
                  (s) => s.book.startNextRole(
                    widget.programId,
                    title: _title.text,
                    criteria: _criteria.text,
                    today: ref.read(todayProvider),
                    now: _now(),
                  ),
                );
                if (!context.mounted) return;
                if (id == null) return notify(context, 'Add a title and at least one criterion.');
                await openReadiness(context, id);
              },
              child: const Text('Check my readiness'),
            ),
          ),
        ],
      ],
    );
  }
}
