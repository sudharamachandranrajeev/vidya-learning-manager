/// The framework self-assessment page (assess plan A6) and its tile on the
/// program page. The rules live in domain/framework.dart.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/framework.dart';
import '../domain/interview.dart';
import 'charts.dart';
import 'topic_page.dart';
import 'zen.dart';

Future<void> openFramework(BuildContext context, String programId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => FrameworkPage(programId)));

/// The page's data: the view and the program's topics (for "Work on next").
typedef FrameworkPageData = ({FrameworkView view, List<Topic> topics});

final frameworkProvider = FutureProvider.family<FrameworkPageData?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final v = await book.frameworkView(id);
  if (v == null) return null;
  return (view: v, topics: (await book.programDrills(id)).topics);
});

/// The program's topics a standard names, by title or id, each once.
List<Topic> standardTopics(FrameworkStandard s, List<Topic> topics) {
  final out = <Topic>[];
  for (final name in s.topics) {
    final k = name.trim().toLowerCase();
    final t = topics.where((t) => t.title.toLowerCase() == k || t.id == name).firstOrNull;
    if (t != null && !out.contains(t)) out.add(t);
  }
  return out;
}

/// The program page's way into the framework; nothing when it has none.
class FrameworkTile extends ConsumerWidget {
  const FrameworkTile(this.programId, {super.key});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(frameworkProvider(programId)).value;
    if (d == null) return const SizedBox.shrink();
    final gaps = d.view.gaps.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('framework-tile'),
        leading: const Icon(Icons.assessment_outlined),
        title: Text(d.view.framework.name),
        subtitle: Text(gaps == 0 ? 'Self-assessment: no gaps' : 'Self-assessment: $gaps to work on next'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openFramework(context, programId),
      ),
    );
  }
}

/// Each standard at the target stage with its descriptor, latest rating,
/// trend, history and the stories that evidence it; gaps first as "Work on
/// next". Self-rating only: no 360, nothing shared.
class FrameworkPage extends ConsumerWidget {
  const FrameworkPage(this.programId, {super.key});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(frameworkProvider(programId)),
      builder: (d) {
        if (d == null) return const Scaffold(body: Center(child: Text('This program has no framework.')));
        final v = d.view;
        final f = v.framework;
        final text = Theme.of(context).textTheme;
        final scheme = Theme.of(context).colorScheme;
        final areas = <String, List<StandardView>>{};
        for (final s in v.standards) {
          (areas[s.standard.area] ??= []).add(s);
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Framework')),
          body: ListView(
            key: const Key('framework-list'),
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(f.name, style: text.titleLarge),
                      if (f.isDraft)
                        Card(
                          key: const Key('framework-draft'),
                          color: scheme.tertiaryContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.info_outline, color: scheme.onTertiaryContainer),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Draft structure — check final wording.',
                                    style: text.bodyMedium?.copyWith(color: scheme.onTertiaryContainer),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      InputDecorator(
                        decoration: const InputDecoration(labelText: 'Target stage'),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            key: const Key('framework-stage'),
                            isExpanded: true,
                            isDense: true,
                            value: v.stage,
                            items: [
                              for (final s in f.stages)
                                DropdownMenuItem(
                                  value: s.id,
                                  child: Text(s.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                ),
                            ],
                            onChanged: (s) {
                              if (s != null) ref.mutate((x) => x.book.setFrameworkStage(programId, s));
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Rate yourself 0–4: ${[for (final (i, l) in ratingLabels.indexed) '$i $l'].join(' · ')}. '
                        'Your ratings stay yours: nothing is shared, and a rating alone never marks a '
                        'criterion covered.',
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      SectionCard(
                        key: const Key('framework-gaps'),
                        title: 'Work on next',
                        child: v.gaps.isEmpty
                            ? const Text('No gaps: every standard is rated 2 or more and has a story.')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [for (final s in v.gaps) _Gap(s, d.topics)],
                              ),
                      ),
                      for (final MapEntry(key: area, value: list) in areas.entries)
                        SectionCard(
                          title: area.isEmpty ? 'Standards' : f.areaTitle(area),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [for (final s in list) _Standard(programId, v, s)],
                          ),
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

class _Gap extends StatelessWidget {
  const _Gap(this.s, this.topics);
  final StandardView s;
  final List<Topic> topics;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final linked = standardTopics(s.standard, topics);
    return Padding(
      key: Key('framework-gap-${s.standard.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.standard.title, style: text.titleSmall),
          Text(s.gapReasons.map((r) => r.label).join(' · '), style: text.bodySmall),
          if (linked.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final t in linked)
                  ActionChip(
                    avatar: const Icon(Icons.menu_book_outlined, size: 18),
                    label: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onPressed: () => openTopic(context, t.id),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Standard extends ConsumerWidget {
  const _Standard(this.programId, this.v, this.s);
  final String programId;
  final FrameworkView v;
  final StandardView s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final descriptor = s.standard.descriptors[v.stage] ?? '';
    final l = s.latest;
    final trend = trendText(s.history);
    return Padding(
      key: Key('framework-standard-${s.standard.id}'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.standard.title, style: text.titleSmall),
          if (descriptor.isNotEmpty) Text(descriptor, style: text.bodyMedium),
          const SizedBox(height: 4),
          Text(
            l == null
                ? 'Not rated yet'
                : '${l.rating.label} (${l.rating.rating}/$ratingMax) on ${niceDate(l.day)}'
                      '${trend.isEmpty ? '' : ' · $trend'}',
            style: text.bodyMedium,
          ),
          if (l != null && l.rating.note.isNotEmpty) Text(l.rating.note, style: text.bodySmall),
          if (s.history.length > 1) ...[
            const SizedBox(height: 4),
            // The trend of the last ratings (0–4), oldest first; a screen
            // reader hears the same history as words.
            Semantics(
              key: Key('framework-trend-${s.standard.id}'),
              label:
                  'Ratings over time, oldest first: '
                  '${[for (final h in trendWindow(s.history)) '${niceDate(h.day)} ${h.rating.rating} of $ratingMax'].join(', ')}',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Sparkline(
                  [for (final h in trendWindow(s.history)) h.rating.rating.toDouble()],
                  max: ratingMax.toDouble(),
                  height: 48,
                ),
              ),
            ),
            Text(
              'History: ${[for (final h in s.history) '${niceDate(h.day)} ${h.rating.rating}'].join(', ')}',
              style: text.bodySmall,
            ),
          ],
          Text(
            s.evidence.isEmpty
                ? 'No story tagged with this yet. Tag one in Udyoga\'s story bank.'
                : 'Evidence: ${[for (final e in s.evidence) e.happened.isEmpty ? e.title : '${e.title} (${niceDate(e.happened)})'].join('; ')}',
            style: text.bodySmall,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('framework-rate-${s.standard.id}'),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l == null ? 'Rate' : 'Rate again'),
              onPressed: () => rateDialog(context, ref, programId, v, s),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a rating 0–4 and an optional note, then saves it dated today.
Future<void> rateDialog(
  BuildContext context,
  WidgetRef ref,
  String programId,
  FrameworkView v,
  StandardView s,
) async {
  var rating = s.latest?.rating.rating;
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(s.standard.title),
        scrollable: true,
        content: RadioGroup<int>(
          groupValue: rating,
          onChanged: (r) => set(() => rating = r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, l) in ratingLabels.indexed)
                RadioListTile<int>(
                  key: Key('framework-rating-$i'),
                  value: i,
                  contentPadding: EdgeInsets.zero,
                  title: Text('$i $l'),
                  subtitle: Text(ratingMeanings[i]),
                ),
              TextField(
                controller: note,
                maxLength: 1000,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: rating == null ? null : () => Navigator.pop(c, true),
            child: const Text('Save rating'),
          ),
        ],
      ),
    ),
  );
  final r = rating;
  if (ok != true || r == null) return;
  await ref.mutate(
    (x) => x.book.rateStandard(
      programId,
      v.framework,
      s.standard,
      stage: v.stage,
      rating: r,
      note: note.text,
      today: today(),
    ),
  );
}
