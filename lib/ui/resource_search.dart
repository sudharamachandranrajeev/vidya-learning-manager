import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/resources.dart';
import 'common.dart';

/// Opens the free resource search with [query] filled in. With [topicId]
/// a tap on Add puts the result in that topic; otherwise the learner picks
/// one of [topics] (a course's or a program's).
Future<void> openResourceSearch(
  BuildContext context, {
  required String query,
  String? topicId,
  List<Topic> topics = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => ResourceSearchSheet(query: query, topicId: topicId, topics: topics),
);

/// One search across every catalogue at once: a progress line per
/// catalogue (a failing one never blocks the rest), free results first,
/// badges for how free each is and its licence, and Add on each.
class ResourceSearchSheet extends ConsumerStatefulWidget {
  const ResourceSearchSheet({super.key, required this.query, this.topicId, this.topics = const []});
  final String query;
  final String? topicId;
  final List<Topic> topics;

  @override
  ConsumerState<ResourceSearchSheet> createState() => _ResourceSearchSheetState();
}

class _ResourceSearchSheetState extends ConsumerState<ResourceSearchSheet> {
  late final _query = TextEditingController(text: widget.query);
  List<SourceStatus> _statuses = const [];
  List<Resource> _results = const [];
  final _added = <String>{};
  var _searched = '';
  var _run = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final run = ++_run;
    final catalogues = await ref.read(resourceCataloguesProvider.future);
    if (!mounted || run != _run) return;
    setState(() {
      _searched = q;
      _results = const [];
    });
    await searchAll(
      catalogues,
      q,
      onChange: (s) {
        if (!mounted || run != _run) return;
        setState(() {
          _statuses = List.of(s);
          _results = rankResources(q, s);
        });
      },
    );
  }

  /// The topic a result goes to: the sheet's own, the only one there is,
  /// or the one the learner picks.
  Future<Topic?> _target() async {
    if (widget.topicId != null) return null;
    final topics = widget.topics;
    if (topics.isEmpty) {
      showMessage(context, 'Add a topic first, then add resources to it.');
      return null;
    }
    if (topics.length == 1) return topics.single;
    return showDialog<Topic>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to which topic?'),
        children: [
          for (final t in topics)
            SimpleDialogOption(onPressed: () => Navigator.pop(context, t), child: Text(t.title)),
        ],
      ),
    );
  }

  Future<void> _add(Resource r) async {
    final topic = await _target();
    final topicId = widget.topicId ?? topic?.id;
    if (topicId == null || !mounted) return;
    final f = resourceItemFields(r);
    await ref.mutate(
      (s) => s.book.addItem(
        topicId,
        f.type,
        f.title,
        url: f.url,
        source: f.source,
        licence: f.licence,
        minutes: f.minutes,
        content: f.content,
      ),
    );
    if (!mounted) return;
    setState(() => _added.add(r.url));
    showMessage(context, topic == null ? 'Added to this topic.' : 'Added to ${topic.title}.');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final youtube = (ref.watch(youtubeKeyProvider).value ?? '').isNotEmpty;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.9,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Find free resources', style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Searches Microsoft Learn, MIT Learn and Open Library${youtube ? ', and YouTube with your key' : ''} '
              'at once. Vidya keeps the link and its facts, never the lesson text.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(labelText: 'Topic or role'),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: _search),
              ],
            ),
            const SizedBox(height: 8),
            for (final s in _statuses) _StatusLine(s),
            if (_searched.isNotEmpty) _OpenLearnRow(_searched),
            const SizedBox(height: 4),
            Expanded(
              child: _searched.isEmpty
                  ? Text(
                      'Type a topic or a role, then search. Vidya goes online only when you do.',
                      style: text.bodyMedium,
                    )
                  : _results.isEmpty && _statuses.every((s) => s.state != SourceState.searching)
                  ? Text(
                      'Nothing found for "$_searched". Try fewer or broader words.',
                      style: text.bodyMedium,
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: 16 + MediaQuery.paddingOf(context).bottom),
                      itemCount: _results.length,
                      itemBuilder: (_, i) => _ResultTile(
                        _results[i],
                        added: _added.contains(_results[i].url),
                        onAdd: () => _add(_results[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.s);
  final SourceStatus s;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: switch (s.state) {
              SourceState.searching => const CircularProgressIndicator(strokeWidth: 2),
              SourceState.done => Icon(Icons.check, size: 16, color: scheme.primary),
              SourceState.failed => Icon(Icons.error_outline, size: 16, color: scheme.error),
            },
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(s.line, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// OpenLearn is link only (its feeds block apps): this row opens
/// OpenLearn's own search for the query in the browser. Nothing is fetched
/// from OpenLearn by Vidya.
class _OpenLearnRow extends StatelessWidget {
  const _OpenLearnRow(this.query);
  final String query;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        const Icon(Icons.open_in_new, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'OpenLearn: link only, opens in your browser',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () => openLink(context, openLearnSearchUrl(query).toString()),
          child: const Text('Search OpenLearn'),
        ),
      ],
    ),
  );
}

/// A small label: how free a result is, or its licence.
class ResourceBadge extends StatelessWidget {
  const ResourceBadge(this.label, {super.key, this.strong = false});
  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: strong ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: strong ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile(this.r, {required this.added, required this.onAdd});
  final Resource r;
  final bool added;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final facts = [
      r.source,
      if (r.kind.isNotEmpty) r.kind,
      if (r.author.isNotEmpty) r.author,
      if (r.minutes > 0) minutesText(r.minutes) else if (r.length.isNotEmpty) r.length,
      if (r.level.isNotEmpty) r.level,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(r.title, style: text.titleSmall),
          const SizedBox(height: 2),
          Text(facts, style: text.bodySmall),
          if (r.summary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(r.summary, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ResourceBadge(r.access.label, strong: r.access.rank <= 1),
              if (r.licence.isNotEmpty) ResourceBadge(r.licence),
            ],
          ),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open'),
                onPressed: () => openLink(context, r.url),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                icon: Icon(added ? Icons.check : Icons.add, size: 18),
                label: Text(added ? 'Added' : 'Add'),
                onPressed: added ? null : onAdd,
              ),
            ],
          ),
          const Divider(height: 8),
        ],
      ),
    );
  }
}
