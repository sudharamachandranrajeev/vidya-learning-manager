import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/study_items.dart';
import 'common.dart';
import 'zen.dart';

/// Everything one topic page shows, read in one go.
typedef TopicView = ({
  Topic topic,
  Course? course,
  List<StudyItem> items,

  /// All of the program's criteria; the topic links some by ref.
  List<Criterion> criteria,
  Note? note,
  double courseHours,
  String today,
});

final topicViewProvider = FutureProvider.family<TopicView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final today = ref.watch(todayProvider);
  final db = ref.watch(sessionProvider).db;
  final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(id) & t.deleted.not())).getSingleOrNull();
  if (topic == null) return null;
  final course = await (db.select(
    db.learnCourses,
  )..where((c) => c.id.equals(topic.courseId) & c.deleted.not())).getSingleOrNull();
  final items =
      await (db.select(db.learnItems)
            ..where((i) => i.topicId.equals(id) & i.deleted.not())
            ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
          .get();
  final pid = course?.programId;
  final criteria = pid == null
      ? <Criterion>[]
      : await (db.select(db.learnCriteria)
              ..where((c) => c.programId.equals(pid) & c.deleted.not())
              ..orderBy([(c) => OrderingTerm.asc(c.ord)]))
            .get();
  final noteId = topic.noteId.isNotEmpty ? topic.noteId : topicNoteId(id);
  final note = await (db.select(db.learnNotes)..where((n) => n.id.equals(noteId) & n.deleted.not())).getSingleOrNull();
  final sessions = await (db.select(
    db.learnSessions,
  )..where((s) => s.courseId.equals(topic.courseId) & s.deleted.not())).get();
  return (
    topic: topic,
    course: course,
    items: items,
    criteria: criteria,
    note: note,
    courseHours: sessions.fold(0, (a, s) => a + s.minutes) / 60,
    today: today,
  );
});

Future<void> openTopic(BuildContext context, String id) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopicPage(id)));

/// Ticks a topic off (or opens it again). Ticking before its required items
/// are done asks for a short note on why, kept with the topic.
Future<void> tickTopic(
  BuildContext context,
  WidgetRef ref,
  Topic t,
  Iterable<StudyItem> items,
  bool done, {
  required String today,
}) async {
  String? note;
  if (done && tickNeedsNote(items)) {
    final open = openRequired(items).length;
    final why = TextEditingController();
    final ok = await showFormDialog(
      context,
      title: 'Tick off anyway?',
      action: 'Tick off',
      fields: (_) => [
        Text(
          '$open required ${open == 1 ? 'item is' : 'items are'} not done yet. '
          'Say in a few words why this topic is done, for when you look back.',
        ),
        const SizedBox(height: 12),
        Field(why, 'Why it is done', autofocus: true, hint: 'I already do this at work'),
      ],
      onSave: () async => why.text.trim().isEmpty ? 'Write a short note first.' : null,
    );
    if (!ok) return;
    note = why.text.trim();
  }
  await ref.mutate((s) => s.book.setTopicDone(t, done, today: today, note: note));
}

class TopicPage extends ConsumerWidget {
  const TopicPage(this.id, {super.key});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(topicViewProvider(id)),
      builder: (v) {
        if (v == null) return const Scaffold(body: Center(child: Text('This topic was deleted.')));
        final t = v.topic;
        final status = topicStatus(t, v.items, wroteNote: v.note != null && !hasPlanNoteTag(v.note!));
        final study = [
          for (final i in v.items)
            if (!checkTypes.contains(i.type)) i,
        ];
        final checks = [
          for (final i in v.items)
            if (checkTypes.contains(i.type)) i,
        ];
        final refs = criteriaRefs(t).toSet();
        final linked = [
          for (final c in v.criteria)
            if (refs.contains(c.ref)) c,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(t.title),
            actions: [
              PopupMenuButton<String>(
                onSelected: (k) async {
                  if (k == 'delete') {
                    if (!await askSure(
                          context,
                          'Delete topic?',
                          'Its study items are deleted too. Its note stays in Notes.',
                        ) ||
                        !context.mounted) {
                      return;
                    }
                    await ref.mutate((s) => s.book.removeTopic(t.id));
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete topic'))],
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
                      _Header(v, status),
                      const SizedBox(height: 12),
                      _WhyItMatters(linked),
                      SectionCard(
                        title: 'Items',
                        trailing: IconButton(
                          tooltip: 'Add item',
                          icon: const Icon(Icons.add),
                          onPressed: () => itemDialog(context, ref, t.id),
                        ),
                        child: study.isEmpty
                            ? const Text('Add what you will watch, read or do for this topic.')
                            : Column(
                                children: [
                                  for (final (k, i) in study.indexed)
                                    _ItemTile(i, today: v.today, first: k == 0, last: k == study.length - 1),
                                ],
                              ),
                      ),
                      _MyNotes(v),
                      _CheckYourself(checks, v.criteria),
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

class _Header extends ConsumerWidget {
  const _Header(this.v, this.status);
  final TopicView v;
  final TopicStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = v.topic;
    final required = v.items.where((i) => i.required).length;
    final requiredDone = required - openRequired(v.items).length;
    final doneMinutes = v.items.where((i) => i.done != null).fold(0, (a, i) => a + i.minutes);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (v.course != null) Text(v.course!.title, style: text.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (t.done != null)
              Chip(avatar: const Icon(Icons.check, size: 18), label: Text(status.label))
            else
              PopupMenuButton<String>(
                tooltip: 'Change status',
                onSelected: (s) => ref.mutate((x) => x.book.setTopicStatus(t, s)),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: '', child: Text('Work it out from my items')),
                  PopupMenuItem(value: 'studying', child: Text('Studying')),
                  PopupMenuItem(value: 'review', child: Text('Review')),
                ],
                child: Chip(avatar: const Icon(Icons.flag_outlined, size: 18), label: Text(status.label)),
              ),
            Chip(label: Text('${minutesText(t.minutes)} planned')),
            if (doneMinutes > 0) Chip(label: Text('${minutesText(doneMinutes)} of items done')),
            if (v.courseHours > 0) Chip(label: Text('${v.courseHours.toStringAsFixed(1)} h logged on the course')),
            const Chip(label: Text('Last quiz: not taken')),
          ],
        ),
        const SizedBox(height: 8),
        if (required > 0)
          Text(
            topicEarned(v.items)
                ? 'All $required required items done. This topic is earned.'
                : '$requiredDone of $required required items done.',
            style: text.bodyMedium,
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: t.done == null
                  ? FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Tick off topic'),
                      onPressed: () => tickTopic(context, ref, t, v.items, true, today: v.today),
                    )
                  : OutlinedButton.icon(
                      icon: const Icon(Icons.undo),
                      label: Text('Done ${relativeDay(t.done!, v.today)}. Open again'),
                      onPressed: () => tickTopic(context, ref, t, v.items, false, today: v.today),
                    ),
            ),
          ],
        ),
        if (t.done != null && t.tickNote.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Ticked off because: ${t.tickNote}')),
      ],
    );
  }
}

class _WhyItMatters extends StatelessWidget {
  const _WhyItMatters(this.criteria);
  final List<Criterion> criteria;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Why it matters',
    child: criteria.isEmpty
        ? const Text('No job criteria are linked to this topic.')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in criteria)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '• ${c.body} (${[c.essential ? 'essential' : 'desirable', if (c.source.isNotEmpty) 'from ${c.source}', if (c.shown == true) 'already on your CV'].join(', ')})',
                  ),
                ),
            ],
          ),
  );
}

class _ItemTile extends ConsumerWidget {
  const _ItemTile(this.i, {required this.today, required this.first, required this.last});
  final StudyItem i;
  final String today;
  final bool first, last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = [
      itemTypes[i.type] ?? i.type,
      if (i.minutes > 0) minutesText(i.minutes),
      if (i.required) 'required',
      if (i.source.isNotEmpty) i.source,
      if (i.licence.isNotEmpty) i.licence,
    ].join(' · ');
    final extra = [
      if (i.done != null) 'Done ${relativeDay(i.done!, today)}',
      if (stoppableTypes.contains(i.type) && i.stoppedAt.isNotEmpty) 'Stopped at ${i.stoppedAt}',
      if (i.takeaway.isNotEmpty) i.type == 'note' ? i.takeaway : 'Takeaway: ${i.takeaway}',
      if (i.type == 'practice task' && i.evidence.isNotEmpty) 'Evidence: ${i.evidence}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(value: i.done != null, onChanged: (v) => _setDone(context, ref, i, v ?? false, today)),
      title: Text(i.title, style: i.done != null ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
      subtitle: Text([facts, ...extra].join('\n')),
      isThreeLine: extra.isNotEmpty,
      onTap: i.url.isNotEmpty ? () => openLink(context, i.url) : () => itemDialog(context, ref, i.topicId, item: i),
      trailing: PopupMenuButton<String>(
        tooltip: 'Item actions',
        onSelected: (k) async {
          switch (k) {
            case 'open':
              await openLink(context, i.url);
            case 'edit':
              await itemDialog(context, ref, i.topicId, item: i);
            case 'up':
              await ref.mutate((s) => s.book.moveItem(i, -1));
            case 'down':
              await ref.mutate((s) => s.book.moveItem(i, 1));
            case 'delete':
              if (await askSure(context, 'Delete item?', i.title) && context.mounted) {
                await ref.mutate((s) => s.book.remove(s.db.learnItems, i.id));
              }
          }
        },
        itemBuilder: (_) => [
          if (i.url.isNotEmpty) const PopupMenuItem(value: 'open', child: Text('Open link')),
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          if (!first) const PopupMenuItem(value: 'up', child: Text('Move up')),
          if (!last) const PopupMenuItem(value: 'down', child: Text('Move down')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Marks an item done. An article or book asks for a one-line takeaway
/// and a practice task for an evidence link; both can be left blank.
Future<void> _setDone(BuildContext context, WidgetRef ref, StudyItem i, bool done, String today) async {
  if (!done || !(takeawayTypes.contains(i.type) || i.type == 'practice task')) {
    await ref.mutate((s) => s.book.setItemDone(i, done, today: today));
    return;
  }
  final task = i.type == 'practice task';
  final c = TextEditingController(text: task ? i.evidence : i.takeaway);
  await showFormDialog(
    context,
    title: 'Done: ${i.title}',
    action: 'Done',
    fields: (_) => [
      task
          ? Field(c, 'Evidence link', autofocus: true, hint: 'Where the work is (optional)')
          : Field(c, 'One-line takeaway', autofocus: true, hint: 'What you will remember (optional)'),
    ],
    onSave: () async {
      final v = c.text.trim();
      await ref.mutate(
        (s) => s.book.saveItem(
          i.copyWith(done: Value(today), evidence: task ? v : i.evidence, takeaway: task ? i.takeaway : v),
        ),
      );
      return null;
    },
  );
}

/// Adds an item to a topic, or edits [item]. The fields follow the type.
Future<void> itemDialog(BuildContext context, WidgetRef ref, String topicId, {StudyItem? item}) async {
  final title = TextEditingController(text: item?.title ?? '');
  final url = TextEditingController(text: item?.url ?? '');
  final source = TextEditingController(text: item?.source ?? '');
  final minutes = TextEditingController(text: (item?.minutes ?? 0) > 0 ? '${item!.minutes}' : '');
  final stopped = TextEditingController(text: item?.stoppedAt ?? '');
  final takeaway = TextEditingController(text: item?.takeaway ?? '');
  final evidence = TextEditingController(text: item?.evidence ?? '');
  var type = item?.type ?? 'video';
  var required = item?.required ?? false;
  await showFormDialog(
    context,
    title: item == null ? 'Add item' : 'Edit item',
    fields: (setState) => [
      Choice(label: 'Type', value: type, options: itemTypes, onChanged: (v) => setState(() => type = v)),
      Field(title, 'Title', autofocus: item == null),
      if (type != 'note') Field(url, 'Link', hint: 'https://…'),
      if (type != 'note') Field(source, 'Source', hint: 'Site, channel or publisher'),
      Field(minutes, 'Minutes', number: true),
      if (stoppableTypes.contains(type)) Field(stopped, 'Stopped at', hint: type == 'video' ? '12:30' : 'page 84'),
      if (takeawayTypes.contains(type)) Field(takeaway, 'One-line takeaway'),
      if (type == 'note') Field(takeaway, 'Text', lines: 4),
      if (type == 'practice task') Field(evidence, 'Evidence link'),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: required,
        title: const Text('Required to earn the topic'),
        onChanged: (v) => setState(() => required = v ?? false),
      ),
    ],
    onSave: () async {
      final name = title.text.trim().isNotEmpty ? title.text.trim() : url.text.trim();
      if (name.isEmpty) return 'Give the item a title or a link.';
      final link = type == 'note' ? '' : url.text.trim();
      final m = (numberIn(minutes)?.round() ?? 0).clamp(0, 6000);
      final keepsTakeaway = type == 'note' || takeawayTypes.contains(type);
      await ref.mutate((s) async {
        if (item == null) {
          await s.book.addItem(
            topicId,
            type,
            name,
            url: link,
            source: type == 'note' ? '' : source.text.trim(),
            minutes: m,
            required: required,
            stoppedAt: stoppableTypes.contains(type) ? stopped.text.trim() : '',
            takeaway: keepsTakeaway ? takeaway.text.trim() : '',
            evidence: type == 'practice task' ? evidence.text.trim() : '',
          );
        } else {
          await s.book.saveItem(
            item.copyWith(
              type: type,
              title: name,
              url: link,
              source: type == 'note' ? '' : source.text.trim(),
              minutes: m,
              required: required,
              stoppedAt: stoppableTypes.contains(type) ? stopped.text.trim() : item.stoppedAt,
              takeaway: keepsTakeaway ? takeaway.text.trim() : item.takeaway,
              evidence: type == 'practice task' ? evidence.text.trim() : item.evidence,
            ),
          );
        }
      });
      return null;
    },
  );
}

class _MyNotes extends ConsumerWidget {
  const _MyNotes(this.v);
  final TopicView v;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = v.note;
    return SectionCard(
      title: 'My notes',
      trailing: IconButton(
        tooltip: n == null ? 'Start notes' : 'Edit notes',
        icon: Icon(n == null ? Icons.note_add_outlined : Icons.edit_outlined),
        onPressed: () => _editNote(context),
      ),
      child: n == null
          ? Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('Start notes in your own words'),
                onPressed: () => _editNote(context),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasPlanNoteTag(n))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'From the plan. Edit it to make it yours.',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                SelectableText(n.body.isEmpty ? 'Empty note.' : n.body),
              ],
            ),
    );
  }

  Future<void> _editNote(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => _TopicNoteEditor(v.topic, v.course?.title ?? '', v.note?.body ?? '')));
}

/// A topic's note: the body only; the title is the topic's.
class _TopicNoteEditor extends ConsumerStatefulWidget {
  const _TopicNoteEditor(this.topic, this.courseTitle, this.body);
  final Topic topic;
  final String courseTitle, body;

  @override
  ConsumerState<_TopicNoteEditor> createState() => _TopicNoteEditorState();
}

class _TopicNoteEditorState extends ConsumerState<_TopicNoteEditor> {
  late final _body = TextEditingController(text: widget.body);

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: Scaffold(
      appBar: AppBar(
        title: Text('Notes: ${widget.topic.title}'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.mutate(
                (s) => s.book.saveTopicNote(widget.topic, widget.courseTitle, _body.text, today: today()),
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Field(_body, 'Note (Markdown)', lines: 12, autofocus: true),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CheckYourself extends StatelessWidget {
  const _CheckYourself(this.items, this.criteria);
  final List<StudyItem> items;
  final List<Criterion> criteria;

  /// A drill's criterion: the program criterion with that ref, or the text.
  String _criterion(String c) => criteria.where((x) => x.ref == c).firstOrNull?.body ?? c;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Check yourself',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          items.isEmpty
              ? 'No quiz or interview drills for this topic yet.'
              : 'Taking quizzes and practising drills here comes in the next update. '
                    'For now they are listed so you know what to check.',
        ),
        for (final i in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(i.type == 'quiz' ? Icons.quiz_outlined : Icons.record_voice_over_outlined),
            title: Text(i.title),
            subtitle: Text(switch (i.type) {
              'quiz' => '${quizLength(i)} questions',
              _ => [
                'Interview drill',
                if (itemContent(i)['criterion'] case final String c when c.isNotEmpty) 'tests ${_criterion(c)}',
              ].join(' · '),
            }),
          ),
      ],
    ),
  );
}
