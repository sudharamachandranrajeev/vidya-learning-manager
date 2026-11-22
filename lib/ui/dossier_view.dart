/// The job dossier on the Journey page's Research stage (journey plan J5):
/// fact cards grouped by kind, each with its status (verified, checked by
/// you, inference), its supporting sentence, its source and the source's
/// date, and a flag when its source cycle says it may be out of date.
/// Sources come from pasting (board papers, staff survey, reviews read by
/// the learner), the advert Udyoga sent, and the official readers. The
/// "why here" points and questions to ask are built only from checked
/// cards, each linking the card it rests on. The rules live in
/// domain/dossier.dart, dossier_book.dart and dossier_readers.dart.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' as ie;

import '../app/providers.dart';
import '../app/research_providers.dart';
import '../db/database.dart';
import '../domain/answer_checker.dart';
import '../domain/dossier.dart';
import '../domain/dossier_book.dart';
import '../domain/dossier_readers.dart';
import '../domain/journey.dart';
import '../domain/spoken_interview.dart' show interviewAiUsable;
import 'common.dart';
import 'zen.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

String _day(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;

/// The dossier for [programId]'s journey [journey].
class DossierSection extends ConsumerWidget {
  const DossierSection({super.key, required this.programId, required this.journey});
  final String programId;
  final Journey journey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final day = ref.watch(todayProvider);
    return AsyncView(
      ref.watch(dossierProvider(programId)),
      builder: (d) {
        final cards = d.cards;
        final facts = [for (final c in cards) _facts(c)];
        final why = whyHerePoints(facts, today: day);
        final ask = questionsToAsk(facts, today: day);
        final criteria = ref.watch(programCriteriaProvider(programId)).value ?? const <Criterion>[];
        final likely = likelyQuestions(criteria, cards, today: day);
        final orgNote = ie.organisationTierNote(evidenceCards(cards, today: day));
        final count = {for (final s in factStatuses.keys) s: cards.where((c) => c.status == s).length};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Facts about the employer, each with the sentence that supports it. "Verified" means Vidya found '
              'that sentence, word for word, in a source you gave it. "Inference" means nobody has checked it.',
            ),
            const SizedBox(height: 8),
            if (cards.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in count.entries)
                    if (e.value > 0)
                      StatusPill('${e.value} ${factStatuses[e.key]!.toLowerCase()}', status: _tone(e.key)),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('dossier-paste'),
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste a source'),
                  onPressed: () => pasteSourceDialog(context, ref, programId, employer: journey.employer),
                ),
                if (journey.advertText.trim().isNotEmpty && !d.sources.any((s) => s.kind == 'advert'))
                  OutlinedButton.icon(
                    key: const Key('dossier-advert'),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Use the advert from Udyoga'),
                    onPressed: () async {
                      final id = await ref.mutate(
                        (s) => s.book.addAdvertSource(programId, journey, now: _now()),
                      );
                      if (id != null && context.mounted) await openSource(context, id);
                    },
                  ),
                OutlinedButton.icon(
                  key: const Key('dossier-ods'),
                  icon: const Icon(Icons.local_hospital_outlined),
                  label: const Text('NHS ODS'),
                  onPressed: () => odsDialog(context, ref, programId, employer: journey.employer),
                ),
                OutlinedButton.icon(
                  key: const Key('dossier-cqc'),
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('CQC'),
                  onPressed: () => cqcDialog(context, ref, programId, d.sources, employer: journey.employer),
                ),
                OutlinedButton.icon(
                  key: const Key('dossier-companies-house'),
                  icon: const Icon(Icons.business_outlined),
                  label: const Text('Companies House'),
                  onPressed: () => companiesHouseDialog(context, ref, programId, employer: journey.employer),
                ),
                OutlinedButton.icon(
                  key: const Key('dossier-ask'),
                  icon: const Icon(Icons.search),
                  label: const Text('Ask the dossier'),
                  onPressed: () => askDossierDialog(context, ref, programId, d, journey: journey),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('3 reasons for choosing this employer', style: t.titleSmall),
            _Artefacts(why, cards: cards, keyPrefix: 'why', empty: 'Add verified facts to build these.'),
            const SizedBox(height: 8),
            Text('3 questions to ask the panel', style: t.titleSmall),
            _Artefacts(ask, cards: cards, keyPrefix: 'ask', empty: 'Add verified facts to build these.'),
            const Text(
              'Built only from verified facts and facts you checked: never from an inference.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text('Likely interview questions', style: t.titleSmall),
            const Text(
              'Ranked by evidence: what the person specification assesses at interview, then the employer\'s '
              'values and plans from your checked facts, then questions candidates reported (anecdotal), then '
              'common ones. Each says why it is here.',
              style: TextStyle(fontSize: 12),
            ),
            if (likely.isEmpty) const Text('Add the job\'s criteria to see likely questions.'),
            for (final (i, q) in likely.indexed)
              ListTile(
                key: Key('likely-$i'),
                contentPadding: EdgeInsets.zero,
                leading: Text('${i + 1}.'),
                title: Text(q.question),
                subtitle: Text('${q.tier.label}. ${q.why}'),
                trailing: q.cardId.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Show the fact it rests on',
                        icon: const Icon(Icons.link),
                        onPressed: () {
                          final c = cards.where((c) => c.id == q.cardId).firstOrNull;
                          if (c != null) showCardDialog(context, c);
                        },
                      ),
              ),
            if (orgNote != null)
              Text(orgNote, key: const Key('likely-org-note'), style: const TextStyle(fontSize: 12)),
            for (final kind in factKinds.keys)
              if (cards.where((c) => c.kind == kind).toList() case final group when group.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(factKinds[kind]!, style: t.titleSmall),
                for (final c in group) FactTile(c, sources: d.sources),
              ],
            if (d.sources.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Your sources', style: t.titleSmall),
              for (final s in d.sources)
                ListTile(
                  key: Key('source-${s.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.article_outlined),
                  title: Text(s.title.isNotEmpty ? s.title : sourceKinds[s.kind] ?? s.kind),
                  subtitle: Text(
                    [
                      sourceKinds[s.kind] ?? s.kind,
                      if (s.sourceDate.isNotEmpty) 'dated ${niceDate(s.sourceDate)}',
                      'read ${niceDate(_day(s.fetchedAt))}',
                    ].join(' · '),
                  ),
                  onTap: () => openSource(context, s.id),
                ),
            ],
            const SizedBox(height: 12),
            Text('Read these yourself', style: t.titleSmall),
            for (final l in linkOnlySources(journey.employer))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.label),
                subtitle: Text(l.note),
                trailing: IconButton(
                  tooltip: 'Open ${l.label}',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => openLink(context, l.url),
                ),
              ),
          ],
        );
      },
    );
  }
}

CardFacts _facts(FactCard c) => (
  id: c.id,
  claim: c.claim,
  kind: c.kind,
  status: c.status,
  sourceTitle: c.sourceTitle,
  sourceDate: c.sourceDate,
  staleAfter: c.staleAfter,
);

KitStatus _tone(String status) => switch (status) {
  'verified' => KitStatus.good,
  'user-confirmed' => KitStatus.info,
  _ => KitStatus.warning,
};

/// What a card's status pill says.
String statusLabel(String status) => switch (status) {
  'verified' => 'Verified',
  'user-confirmed' => 'You checked it',
  _ => 'Inference: not checked',
};

class _Artefacts extends StatelessWidget {
  const _Artefacts(this.items, {required this.cards, required this.keyPrefix, required this.empty});
  final List<Artefact> items;
  final List<FactCard> cards;
  final String keyPrefix, empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(empty));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, a) in items.indexed)
          ListTile(
            key: Key('$keyPrefix-$i'),
            contentPadding: EdgeInsets.zero,
            leading: Text('${i + 1}.'),
            title: Text(a.text),
            trailing: IconButton(
              key: Key('$keyPrefix-$i-card'),
              tooltip: 'Show the fact it rests on',
              icon: const Icon(Icons.link),
              onPressed: () {
                final c = cards.where((c) => c.id == a.cardId).firstOrNull;
                if (c != null) showCardDialog(context, c);
              },
            ),
          ),
      ],
    );
  }
}

/// A card's claim, sentence, source and status, in a dialog.
Future<void> showCardDialog(BuildContext context, FactCard c) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('The fact it rests on'),
    scrollable: true,
    content: SizedBox(width: 480, child: _CardBody(c, today: today())),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
  ),
);

class _CardBody extends StatelessWidget {
  const _CardBody(this.c, {required this.today});
  final FactCard c;
  final String today;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(c.claim),
        if (c.quote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('“${c.quote}”', style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusPill(statusLabel(c.status), status: _tone(c.status)),
            if (c.kind == 'reviews-anecdotal') const StatusPill('Anecdotal', quiet: true, dot: false),
            if (isStale(c.staleAfter, today)) StatusPill(staleNote(c.kind), status: KitStatus.warning),
            if (c.sourceUrl.isNotEmpty || c.sourceTitle.isNotEmpty)
              InkWell(
                onTap: c.sourceUrl.isEmpty ? null : () => openLink(context, c.sourceUrl),
                child: Text(
                  [
                    'Source: ${c.sourceTitle.isNotEmpty ? c.sourceTitle : Uri.tryParse(c.sourceUrl)?.host ?? c.sourceUrl}',
                    if (c.sourceDate.isNotEmpty) 'dated ${niceDate(c.sourceDate)}',
                    if (c.fetchedAt.isNotEmpty) 'read ${niceDate(_day(c.fetchedAt))}',
                    if (c.origin == 'udyoga') 'proposed by Udyoga',
                    if (c.origin == 'ai') 'found by AI, sentence checked',
                  ].join(' · '),
                  style: t.bodySmall?.copyWith(
                    decoration: c.sourceUrl.isEmpty ? null : TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One fact card with its actions.
class FactTile extends ConsumerWidget {
  const FactTile(this.c, {super.key, required this.sources});
  final FactCard c;
  final List<FactSource> sources;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    key: Key('fact-${c.id}'),
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _CardBody(c, today: ref.watch(todayProvider))),
        PopupMenuButton<String>(
          key: Key('fact-${c.id}-menu'),
          tooltip: 'Fact actions',
          onSelected: (v) => _act(context, ref, v),
          itemBuilder: (_) => [
            if (c.status == 'inference' && sources.isNotEmpty)
              const PopupMenuItem(value: 'pick', child: Text('Pick the supporting sentence')),
            if (c.status == 'inference')
              const PopupMenuItem(value: 'confirm', child: Text('I checked this myself')),
            const PopupMenuItem(value: 'kind', child: Text('Change the kind')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    ),
  );

  Future<void> _act(BuildContext context, WidgetRef ref, String v) async {
    switch (v) {
      case 'confirm':
        final ok = await askSure(
          context,
          'You checked it yourself?',
          'Only say so if you read this in a source you trust. It will be labelled "You checked it".',
          action: 'I checked it',
        );
        if (ok) await ref.mutate((s) => s.book.confirmFact(c.id, now: _now()));
      case 'pick':
        await pickSentenceDialog(context, ref, c, sources);
      case 'kind':
        var kind = c.kind;
        await showFormDialog(
          context,
          title: 'Kind of fact',
          fields: (setState) => [
            Choice<String>(
              label: 'Kind',
              value: kind,
              options: factKinds,
              onChanged: (k) => setState(() => kind = k),
            ),
          ],
          onSave: () async {
            await ref.mutate((s) => s.book.setFactKind(c.id, kind, now: _now()));
            return null;
          },
        );
      case 'delete':
        if (await askSure(context, 'Delete this fact?', c.claim)) {
          await ref.mutate((s) => s.book.removeFact(c.id));
        }
    }
  }
}

/// Picks a supporting sentence for an inference card from the sources'
/// sentences that share its words. It becomes verified only if the quote
/// check passes.
Future<void> pickSentenceDialog(
  BuildContext context,
  WidgetRef ref,
  FactCard c,
  List<FactSource> sources,
) async {
  final same = [
    for (final s in sources)
      if (c.sourceUrl.isNotEmpty && sameUrl(s.url) == sameUrl(c.sourceUrl)) s,
  ];
  final pool = same.isNotEmpty ? same : sources;
  final choices = [
    for (final s in pool)
      for (final line in candidateSentences(c.claim, s.body)) (source: s, sentence: line),
  ];
  ({FactSource source, String sentence})? picked;
  await showFormDialog(
    context,
    title: 'Pick the supporting sentence',
    action: 'Check and save',
    fields: (setState) => [
      Text(c.claim),
      const SizedBox(height: 8),
      if (choices.isEmpty)
        const Text(
          'Not found in your sources: no sentence shares its words. Paste the page it comes from first.',
        )
      else
        RadioGroup<int>(
          groupValue: picked == null ? null : choices.indexOf(picked!),
          onChanged: (i) => setState(() => picked = i == null ? null : choices[i]),
          child: Column(
            children: [
              for (final (i, ch) in choices.indexed)
                RadioListTile<int>(
                  key: Key('pick-$i'),
                  value: i,
                  contentPadding: EdgeInsets.zero,
                  title: Text(ch.sentence),
                  subtitle: Text(
                    ch.source.title.isNotEmpty ? ch.source.title : sourceKinds[ch.source.kind] ?? '',
                  ),
                ),
            ],
          ),
        ),
    ],
    onSave: () async {
      final p = picked;
      if (p == null) return choices.isEmpty ? null : 'Pick a sentence, or cancel.';
      return ref.mutate((s) => s.book.attachQuote(c.id, p.source.id, p.sentence, now: _now()));
    },
  );
}

// ---- sources ----

Future<void> openSource(BuildContext context, String id) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SourcePage(id)));

/// The paste flow: the learner pastes what they read with its address and
/// date. Review sites and LinkedIn are never read by Vidya: their text
/// comes only this way.
Future<void> pasteSourceDialog(
  BuildContext context,
  WidgetRef ref,
  String programId, {
  String employer = '',
}) async {
  var kind = 'board';
  String? date;
  final title = TextEditingController(), url = TextEditingController(), body = TextEditingController();
  String? id;
  await showFormDialog(
    context,
    title: 'Paste a source',
    fields: (setState) => [
      Choice<String>(
        label: 'What it is',
        value: kind,
        options: {for (final k in pasteKinds) k: sourceKinds[k]!},
        onChanged: (k) => setState(() => kind = k),
      ),
      if (kind == 'reviews')
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Anecdotal: every fact from reviews is labelled so. Glassdoor and Indeed do not allow programs to read '
            'them, so Vidya never does: paste what you read.',
          ),
        ),
      if (kind == 'linkedin')
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Read it yourself and paste only what matters. Vidya never opens or reads LinkedIn for you.',
          ),
        ),
      Field(title, 'Title', hint: 'Board papers, September 2026'),
      Field(url, 'Web address', hint: 'https://…'),
      DatePick(
        label: 'The source\'s own date (meeting, survey year, report)',
        value: date,
        onChanged: (d) => setState(() => date = d),
      ),
      Field(body, 'The text', lines: 8, hint: 'Paste the parts you read'),
    ],
    onSave: () async {
      if (body.text.trim().isEmpty) return 'Paste the text first.';
      final u = url.text.trim();
      if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://')) {
        return 'The web address should start with https://';
      }
      id = await ref.mutate(
        (s) => s.book.addFactSource(
          programId,
          employer: employer,
          kind: kind,
          url: u,
          title: title.text,
          sourceDate: date ?? '',
          body: body.text,
          now: _now(),
        ),
      );
      return null;
    },
  );
  if (id != null && context.mounted) await openSource(context, id!);
}

final _sourceProvider = FutureProvider.family<(FactSource?, List<FactCard>), String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final s = await book.factSource(id);
  if (s == null) return (null, const <FactCard>[]);
  return (
    s,
    [
      for (final c in await book.factCards(s.programId))
        if (c.sourceId == id) c,
    ],
  );
});

/// One source: its text, the facts from it, and ways to add more (an AI
/// proposes, or the learner writes one); every fact faces the quote check.
class SourcePage extends ConsumerStatefulWidget {
  const SourcePage(this.id, {super.key});
  final String id;

  @override
  ConsumerState<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends ConsumerState<SourcePage> {
  var _busy = false, _all = false;

  @override
  Widget build(BuildContext context) => AsyncView(
    ref.watch(_sourceProvider(widget.id)),
    builder: (d) {
      final (s, cards) = d;
      if (s == null) return const Scaffold(body: Center(child: Text('This source was deleted.')));
      final t = Theme.of(context).textTheme;
      final setup = ref.watch(helpAiProvider).value ?? const HelpAiSetup();
      final ai = interviewAiUsable(setup, offline: false);
      final text = !_all && s.body.length > 3000 ? '${s.body.substring(0, 3000)}…' : s.body;
      return Scaffold(
        appBar: AppBar(
          title: Text(s.title.isNotEmpty ? s.title : sourceKinds[s.kind] ?? 'Source'),
          actions: [
            IconButton(
              tooltip: 'Delete this source',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final sure = await askSure(
                  context,
                  'Delete this source?',
                  'Facts from it stay, with their status.',
                );
                if (!sure) return;
                await ref.mutate((x) => x.book.removeFactSource(s.id));
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            Text(
              [
                sourceKinds[s.kind] ?? s.kind,
                if (s.sourceDate.isNotEmpty) 'dated ${niceDate(s.sourceDate)}',
                'read ${niceDate(_day(s.fetchedAt))}',
              ].join(' · '),
              style: t.bodySmall,
            ),
            if (s.url.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(Uri.tryParse(s.url)?.host ?? s.url),
                  onPressed: () => openLink(context, s.url),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('source-ai'),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('Ask AI for facts'),
                  onPressed: _busy || !ai ? null : () => _askAi(s),
                ),
                OutlinedButton.icon(
                  key: const Key('source-add-fact'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a fact'),
                  onPressed: () => addFactDialog(context, ref, s),
                ),
              ],
            ),
            if (!ai)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Asking an AI needs one connected in Ask AI. You can add facts yourself.'),
              ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            const SizedBox(height: 12),
            Text('Facts from this source (${cards.length})', style: t.titleSmall),
            for (final c in cards) FactTile(c, sources: [s]),
            const SizedBox(height: 12),
            Text('The text', style: t.titleSmall),
            const SizedBox(height: 4),
            SelectableText(text),
            if (s.body.length > 3000)
              TextButton(
                onPressed: () => setState(() => _all = !_all),
                child: Text(_all ? 'Show less' : 'Show all'),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _askAi(FactSource s) async {
    setState(() => _busy = true);
    try {
      final setup = await ref.read(helpAiProvider.future);
      final asker = await ref.read(helpAskerProvider)(setup);
      final proposals = await aiFactProposals(
        (system, text) => asker.ask(system, [(user: true, text: text)]),
        s,
      );
      final r = await ref.mutate((x) => x.book.addProposals(s.id, proposals, origin: 'ai', now: _now()));
      if (!mounted) return;
      final dropped = r.unmatched.length;
      notify(
        context,
        [
          r.added == 0
              ? 'No new verified facts.'
              : 'Added ${r.added} verified ${r.added == 1 ? 'fact' : 'facts'}.',
          if (dropped > 0) '$dropped dropped: their sentence is not in the text word for word.',
        ].join(' '),
        status: r.added > 0 ? KitStatus.good : KitStatus.info,
      );
    } catch (e) {
      if (mounted) {
        notify(context, e is FormatException ? e.message : describeError(e), status: KitStatus.warning);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The learner writes a fact from [s]: a claim and the sentence that
/// supports it. Verified if the sentence is in the text; otherwise kept
/// as inference, or as "you checked it" if they say so.
Future<void> addFactDialog(BuildContext context, WidgetRef ref, FactSource s) async {
  final claim = TextEditingController(), quote = TextEditingController();
  var kind = defaultFactKind(s.kind);
  var mine = false;
  String? result;
  await showFormDialog(
    context,
    title: 'Add a fact',
    fields: (setState) => [
      Field(claim, 'The fact, in your words', lines: 2, autofocus: true),
      Field(quote, 'The sentence that supports it', lines: 3, hint: 'Copy it whole from the text'),
      if (s.kind != 'reviews')
        Choice<String>(
          label: 'Kind',
          value: kind,
          options: factKinds,
          onChanged: (k) => setState(() => kind = k),
        ),
      CheckboxListTile(
        key: const Key('fact-mine'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: mine,
        title: const Text('I checked this myself'),
        subtitle: const Text('Used only if the sentence is not found in the text.'),
        onChanged: (v) => setState(() => mine = v ?? false),
      ),
    ],
    onSave: () async {
      if (claim.text.trim().isEmpty) return 'Write the fact first.';
      final r = await ref.mutate(
        (x) => x.book.addOwnFact(
          s.programId,
          employer: s.employer,
          claim: claim.text,
          quote: quote.text,
          kind: kind,
          sourceId: s.id,
          checkedMyself: mine,
          now: _now(),
        ),
      );
      result = switch (r.status) {
        'verified' => 'Verified: the sentence is in the text.',
        'user-confirmed' => 'Saved as checked by you. ${quoteProblem(quote.text, s.body) ?? ''}',
        _ => 'Saved as inference. ${quoteProblem(quote.text, s.body) ?? ''}',
      };
      return null;
    },
  );
  if (result != null && context.mounted) {
    notify(
      context,
      result!.trim(),
      status: result!.startsWith('Verified') ? KitStatus.good : KitStatus.warning,
    );
  }
}

// ---- readers ----

Future<void> _runReader(
  BuildContext context,
  WidgetRef ref,
  String programId,
  Future<ReaderRecord> Function() read, {
  String employer = '',
}) async {
  final r = await read();
  final id = await ref.mutate((s) => s.book.saveReaderRecord(programId, r, employer: employer, now: _now()));
  if (context.mounted) {
    notify(context, 'Kept: ${r.title}, with ${r.facts.length} verified facts.', status: KitStatus.good);
    await openSource(context, id);
  }
}

/// NHS ODS: search by name, pick the organisation, keep its record.
Future<void> odsDialog(BuildContext context, WidgetRef ref, String programId, {String employer = ''}) async {
  final name = TextEditingController(text: employer);
  final ods = OdsReader(ref.read(researchGateProvider));
  List<OdsOrg>? hits;
  String? picked, error;
  var busy = false;
  await showFormDialog(
    context,
    title: 'NHS ODS',
    action: 'Keep this record',
    fields: (setState) => [
      const Text(
        'The NHS Organisation Data Service: official names, sites and successors. No key; Vidya asks only when you '
        'search and keeps answers for a week.',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: Field(name, 'Organisation name')),
          IconButton(
            key: const Key('ods-search'),
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      hits = await ods.search(name.text);
                    } on ResearchException catch (e) {
                      error = e.message;
                    }
                    setState(() => busy = false);
                  },
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null) Text(error!),
      if (hits case final h? when h.isEmpty) const Text('Not found in the register. Try fewer words.'),
      if (hits != null)
        RadioGroup<String>(
          groupValue: picked,
          onChanged: (v) => setState(() => picked = v),
          child: Column(
            children: [
              for (final o in hits!)
                RadioListTile<String>(
                  key: Key('ods-${o.code}'),
                  value: o.code,
                  contentPadding: EdgeInsets.zero,
                  title: Text(o.name),
                  subtitle: Text(
                    [o.code, o.status, o.postcode, o.role].where((x) => x.isNotEmpty).join(' · '),
                  ),
                ),
            ],
          ),
        ),
    ],
    onSave: () async {
      if (picked == null) return 'Search, then pick the organisation.';
      try {
        await _runReader(context, ref, programId, () => ods.record(picked!), employer: employer);
      } on ResearchException catch (e) {
        return e.message;
      }
      return null;
    },
  );
}

/// CQC with the learner's own key; without one, a link to CQC's site.
Future<void> cqcDialog(
  BuildContext context,
  WidgetRef ref,
  String programId,
  List<FactSource> sources, {
  String employer = '',
}) async {
  final reader = (await ref.read(keyedReadersProvider.future)).cqc;
  final odsCode = [
    for (final s in sources)
      if (s.kind == 'ods') Uri.tryParse(s.url)?.pathSegments.lastOrNull ?? '',
  ].where((c) => c.isNotEmpty).firstOrNull;
  if (!context.mounted) return;
  final id = TextEditingController(text: odsCode ?? '');
  await showFormDialog(
    context,
    title: 'CQC',
    action: reader == null ? 'Open CQC' : 'Keep this record',
    fields: (_) => [
      if (reader == null)
        const Text(
          'Off. CQC\'s ratings can be read with your own CQC API key (Settings, Job research keys). Until then, open '
          'CQC\'s site, and paste what you read.',
        )
      else ...[
        const Text('Reads the provider\'s ratings and report dates with your own key.'),
        const SizedBox(height: 8),
      ],
      Field(id, 'CQC provider ID', hint: 'For an NHS trust, usually its ODS code'),
    ],
    onSave: () async {
      if (reader == null) {
        await openLink(
          context,
          id.text.trim().isEmpty ? 'https://www.cqc.org.uk/' : CqcReader.pageUrl(id.text),
        );
        return null;
      }
      try {
        await _runReader(context, ref, programId, () => reader.record(id.text), employer: employer);
      } on ResearchException catch (e) {
        return e.message;
      }
      return null;
    },
  );
}

/// Companies House with the learner's own key; without one, a link to
/// its search page.
Future<void> companiesHouseDialog(
  BuildContext context,
  WidgetRef ref,
  String programId, {
  String employer = '',
}) async {
  final reader = (await ref.read(keyedReadersProvider.future)).companiesHouse;
  if (!context.mounted) return;
  final name = TextEditingController(text: employer);
  List<CompanyHit>? hits;
  String? picked, error;
  var busy = false;
  await showFormDialog(
    context,
    title: 'Companies House',
    action: reader == null ? 'Open Companies House' : 'Keep this record',
    fields: (setState) => [
      if (reader == null)
        const Text(
          'Off. A private employer\'s officers and filings can be read with your own free Companies House key '
          '(Settings, Job research keys). Until then, open its search page.',
        ),
      Row(
        children: [
          Expanded(child: Field(name, 'Company name')),
          if (reader != null)
            IconButton(
              key: const Key('ch-search'),
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: busy
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        hits = await reader.search(name.text);
                      } on ResearchException catch (e) {
                        error = e.message;
                      }
                      setState(() => busy = false);
                    },
            ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null) Text(error!),
      if (hits case final h? when h.isEmpty) const Text('Not found in the register.'),
      if (hits != null)
        RadioGroup<String>(
          groupValue: picked,
          onChanged: (v) => setState(() => picked = v),
          child: Column(
            children: [
              for (final c in hits!)
                RadioListTile<String>(
                  key: Key('ch-${c.number}'),
                  value: c.number,
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name),
                  subtitle: Text([c.number, c.status, c.address].where((x) => x.isNotEmpty).join(' · ')),
                ),
            ],
          ),
        ),
    ],
    onSave: () async {
      if (reader == null) {
        await openLink(context, CompaniesHouseReader.searchUrl(name.text));
        return null;
      }
      if (picked == null) return 'Search, then pick the company.';
      try {
        await _runReader(
          context,
          ref,
          programId,
          () => reader.record(picked!, today: today()),
          employer: employer,
        );
      } on ResearchException catch (e) {
        return e.message;
      }
      return null;
    },
  );
}

// ---- asking ----

/// Looks for a question's words in the cards and sources. Says "not found
/// in your sources" rather than guess, with where to look.
Future<void> askDossierDialog(
  BuildContext context,
  WidgetRef ref,
  String programId,
  DossierData d, {
  required Journey journey,
}) async {
  final q = TextEditingController();
  DossierAnswer? answer;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final a = answer;
        final odsCode = [
          for (final s in d.sources)
            if (s.kind == 'ods') Uri.tryParse(s.url)?.pathSegments.lastOrNull ?? '',
        ].firstOrNull;
        return AlertDialog(
          title: const Text('Ask the dossier'),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Looks only in your facts and sources: it never guesses.'),
                TextField(
                  key: const Key('dossier-question'),
                  controller: q,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'What do you want to know?'),
                  onSubmitted: (_) => setState(
                    () => answer = askDossier(
                      q.text,
                      cards: [for (final c in d.cards) (id: c.id, claim: c.claim, quote: c.quote)],
                      sources: [for (final s in d.sources) (id: s.id, body: s.body)],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (a != null && a.cardIds.isEmpty && a.sentences.isEmpty) ...[
                  Text(
                    'Not found in your sources.',
                    key: const Key('dossier-not-found'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Text('Where to look:'),
                  for (final w in whereToLook(q.text, employer: journey.employer, odsCode: odsCode ?? ''))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(w.label),
                      trailing: w.url.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => openLink(context, w.url),
                            ),
                    ),
                ],
                if (a != null)
                  for (final id in a.cardIds)
                    if (d.cards.where((c) => c.id == id).firstOrNull case final c?)
                      _CardBody(c, today: today()),
                if (a != null && a.sentences.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('In your sources, not yet a fact:'),
                  for (final s in a.sentences)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.sentence),
                      trailing: TextButton(
                        child: const Text('Make it a fact'),
                        onPressed: () async {
                          final src = d.sources.firstWhere((x) => x.id == s.sourceId);
                          await ref.mutate(
                            (x) => x.book.addOwnFact(
                              programId,
                              employer: journey.employer,
                              claim: s.sentence,
                              quote: s.sentence,
                              kind: defaultFactKind(src.kind),
                              sourceId: src.id,
                              now: _now(),
                            ),
                          );
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            FilledButton(
              key: const Key('dossier-ask-go'),
              onPressed: () => setState(
                () => answer = askDossier(
                  q.text,
                  cards: [for (final c in d.cards) (id: c.id, claim: c.claim, quote: c.quote)],
                  sources: [for (final s in d.sources) (id: s.id, body: s.body)],
                ),
              ),
              child: const Text('Ask'),
            ),
          ],
        );
      },
    ),
  );
}
