import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/capstone.dart' show capstoneType;
import '../domain/scenario.dart' show scenarioType;
import '../domain/interview.dart';
import '../domain/exam.dart';
import '../domain/next_up.dart';
import '../domain/quiz.dart';
import '../domain/resources.dart';
import '../domain/study_items.dart';
import 'capstone_page.dart';
import 'scenario_page.dart';
import 'charts.dart';
import 'common.dart';
import 'dialogs.dart';
import 'interview_pages.dart';
import 'quiz_page.dart';
import 'resource_search.dart';
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

  /// The last quiz score in percent, null when never taken.
  int? quizPercent,

  /// Minutes logged on this topic.
  int topicMinutes,

  /// Items a plan sent again without; kept, not counted.
  List<StudyItem> retired,

  /// Practice tasks already in the portfolio (by item id).
  Set<String> inPortfolio,

  /// Each interview drill's practice so far (by item id).
  Map<String, DrillEvidence> drills,

  /// The topic's exam attempts, oldest first (empty for a practice quiz).
  List<Assessment> exams,
});

final topicViewProvider = FutureProvider.family<TopicView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final today = ref.watch(todayProvider);
  final db = ref.watch(sessionProvider).db;
  final topic = await (db.select(
    db.learnTopics,
  )..where((t) => t.id.equals(id) & t.deleted.not())).getSingleOrNull();
  if (topic == null) return null;
  final course = await (db.select(
    db.learnCourses,
  )..where((c) => c.id.equals(topic.courseId) & c.deleted.not())).getSingleOrNull();
  final all =
      await (db.select(db.learnItems)
            ..where((i) => i.topicId.equals(id) & i.deleted.not())
            ..orderBy([(i) => OrderingTerm.asc(i.ord), (i) => OrderingTerm.asc(i.id)]))
          .get();
  final items = activeItems(all);
  final pid = course?.programId;
  final criteria = pid == null
      ? <Criterion>[]
      : await (db.select(db.learnCriteria)
              ..where((c) => c.programId.equals(pid) & c.deleted.not())
              ..orderBy([(c) => OrderingTerm.asc(c.ord)]))
            .get();
  final noteId = topic.noteId.isNotEmpty ? topic.noteId : topicNoteId(id);
  final note = await (db.select(
    db.learnNotes,
  )..where((n) => n.id.equals(noteId) & n.deleted.not())).getSingleOrNull();
  final sessions = await (db.select(
    db.learnSessions,
  )..where((s) => (s.courseId.equals(topic.courseId) | s.topicId.equals(id)) & s.deleted.not())).get();
  final tests = await (db.select(
    db.learnAssessments,
  )..where((a) => a.topicId.equals(id) & a.deleted.not())).get();
  final tasks = [
    for (final i in items)
      if (i.type == 'practice task') taskPortfolioId(i.id),
  ];
  final portfolio = tasks.isEmpty
      ? const <PortfolioItem>[]
      : await (db.select(db.learnPortfolio)..where((p) => p.id.isIn(tasks) & p.deleted.not())).get();
  final drills = await ref.watch(sessionProvider).book.drillEvidence([
    for (final i in items)
      if (i.type == 'interview drill') i.id,
  ]);
  return (
    topic: topic,
    course: course,
    items: items,
    criteria: criteria,
    note: note,
    courseHours: sessions.where((s) => s.courseId == topic.courseId).fold(0, (a, s) => a + s.minutes) / 60,
    today: today,
    quizPercent: lastQuizPercents(tests)[id],
    topicMinutes: minutesByTopic(sessions)[id] ?? 0,
    retired: [
      for (final i in all)
        if (i.retired.isNotEmpty) i,
    ],
    inPortfolio: {for (final p in portfolio) p.id.substring(0, p.id.length - '.portfolio'.length)},
    drills: drills,
    exams: examAttempts(tests, id),
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
  int? quizPercent,
}) async {
  String? note;
  if (done && tickNeedsNote(items, quizPercent: quizPercent)) {
    final open = openRequired(items).length;
    final quiz = quizPending(items, quizPercent);
    final why = TextEditingController();
    final ok = await showFormDialog(
      context,
      title: 'Tick off anyway?',
      action: 'Tick off',
      fields: (_) => [
        Text(
          [
            if (open > 0) '$open required ${open == 1 ? 'item is' : 'items are'} not done yet.',
            if (quiz) 'The quiz is not passed yet (${topicPassPercent(items)}% or more).',
            'Say in a few words why this topic is done, for when you look back.',
          ].join(' '),
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
              IconButton(
                tooltip: 'Log time on this topic',
                icon: const Icon(Icons.timer_outlined),
                onPressed: () => logSessionDialog(context, ref, courseId: t.courseId, topicId: t.id),
              ),
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Find free resources',
                              icon: const Icon(Icons.travel_explore),
                              onPressed: () => openResourceSearch(context, query: t.title, topicId: t.id),
                            ),
                            IconButton(
                              tooltip: 'Add item',
                              icon: const Icon(Icons.add),
                              onPressed: () => itemDialog(context, ref, t.id),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (study.isEmpty)
                              const Text('Add what you will watch, read or do for this topic.')
                            else
                              for (final (k, i) in study.indexed)
                                _ItemTile(
                                  i,
                                  today: v.today,
                                  first: k == 0,
                                  last: k == study.length - 1,
                                  inPortfolio: v.inPortfolio.contains(i.id),
                                ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                icon: const Icon(Icons.travel_explore),
                                label: const Text('Find free resources'),
                                onPressed: () => openResourceSearch(context, query: t.title, topicId: t.id),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _MyNotes(v),
                      _CheckYourself(
                        t.id,
                        checks,
                        v.criteria,
                        quizPercent: v.quizPercent,
                        evidence: v.drills,
                        programId: v.course?.programId,
                        exams: v.exams,
                        today: v.today,
                      ),
                      if (v.retired.isNotEmpty) _Retired(v.retired),
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
    final hasQuiz = topicQuiz(v.items) != null;
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
            if (v.topicMinutes > 0) Chip(label: Text('${minutesText(v.topicMinutes)} studied')),
            if (v.courseHours > 0)
              Chip(label: Text('${v.courseHours.toStringAsFixed(1)} h logged on the course')),
            Chip(
              label: Text(v.quizPercent == null ? 'Last quiz: not taken' : 'Last quiz: ${v.quizPercent}%'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (required > 0 || hasQuiz)
          Text(
            topicEarned(v.items, quizPercent: v.quizPercent)
                ? 'Required items done${hasQuiz ? ' and quiz passed' : ''}. This topic is earned.'
                : [
                    if (required > 0) '$requiredDone of $required required items done.',
                    if (hasQuiz)
                      quizPending(v.items, v.quizPercent)
                          ? 'Quiz: ${topicPassPercent(v.items)}% or more to earn it.'
                          : 'Quiz passed.',
                  ].join(' '),
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
                      onPressed: () => tickTopic(
                        context,
                        ref,
                        t,
                        v.items,
                        true,
                        today: v.today,
                        quizPercent: v.quizPercent,
                      ),
                    )
                  : OutlinedButton.icon(
                      icon: const Icon(Icons.undo),
                      label: Text('Done ${relativeDay(t.done!, v.today)}. Open again'),
                      onPressed: () => tickTopic(
                        context,
                        ref,
                        t,
                        v.items,
                        false,
                        today: v.today,
                        quizPercent: v.quizPercent,
                      ),
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
  const _ItemTile(
    this.i, {
    required this.today,
    required this.first,
    required this.last,
    this.inPortfolio = false,
  });
  final StudyItem i;
  final String today;
  final bool first, last;

  /// Whether this practice task is already a portfolio item.
  final bool inPortfolio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = i.type == 'practice task';
    final content = itemContent(i);
    final facts = [
      itemTypes[i.type] ?? i.type,
      if (i.minutes > 0) minutesText(i.minutes),
      if (i.required) 'required',
      if (accessTypes.contains(i.type) && itemAccess(content) != Access.unknown) itemAccess(content).label,
      if (i.source.isNotEmpty) i.source,
      if (i.licence.isNotEmpty) i.licence,
    ].join(' · ');
    final extra = [
      if (content['instructions'] case final String s when task && s.isNotEmpty) s,
      if (content['doneWhen'] case final String s when task && s.isNotEmpty) 'Done when: $s',
      if (i.done != null) 'Done ${relativeDay(i.done!, today)}',
      if (resumeText(i) case final r when r.isNotEmpty && i.done == null) r,
      if (i.takeaway.isNotEmpty)
        i.type == 'note' ? i.takeaway : (task ? 'Note: ${i.takeaway}' : 'Takeaway: ${i.takeaway}'),
      if (task && i.evidence.isNotEmpty) 'Evidence: ${i.evidence}',
    ];
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: i.done != null,
        onChanged: (v) => _setDone(context, ref, i, v ?? false, today),
      ),
      title: Text(
        i.title,
        style: i.done != null ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
      ),
      subtitle: Text([facts, ...extra].join('\n')),
      isThreeLine: extra.isNotEmpty,
      onTap: i.url.isNotEmpty
          ? () => openLink(context, i.url)
          : () => itemDialog(context, ref, i.topicId, item: i),
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
    if (!task || i.done == null) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 8),
            child: TextButton.icon(
              icon: Icon(inPortfolio ? Icons.check : Icons.work_outline),
              label: Text(inPortfolio ? 'In your portfolio' : 'Add to portfolio'),
              onPressed: inPortfolio
                  ? null
                  : () async {
                      await ref.mutate((s) => s.book.taskToPortfolio(i, today: today));
                      if (context.mounted) notify(context, 'Added to your portfolio.');
                    },
            ),
          ),
        ),
      ],
    );
  }
}

/// Marks an item done. An article or book asks for a one-line takeaway (it
/// can be left blank). A practice task needs its evidence link, or a short
/// note on what was done when there is nothing to link to.
Future<void> _setDone(BuildContext context, WidgetRef ref, StudyItem i, bool done, String today) async {
  if (!done || !(takeawayTypes.contains(i.type) || i.type == 'practice task')) {
    await ref.mutate((s) => s.book.setItemDone(i, done, today: today));
    return;
  }
  if (i.type == 'practice task') {
    final evidence = TextEditingController(text: i.evidence);
    final note = TextEditingController(text: i.takeaway);
    final doneWhen = itemContent(i)['doneWhen'];
    await showFormDialog(
      context,
      title: 'Done: ${i.title}',
      action: 'Done',
      fields: (_) => [
        if (doneWhen is String && doneWhen.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Done when: $doneWhen')),
        Field(evidence, 'Evidence link', autofocus: true, hint: 'Where the work is'),
        Field(note, 'Or a short note on what you did', lines: 2),
      ],
      onSave: () =>
          ref.mutate((s) => s.book.completeTask(i, evidence: evidence.text, note: note.text, today: today)),
    );
    return;
  }
  final c = TextEditingController(text: i.takeaway);
  await showFormDialog(
    context,
    title: 'Done: ${i.title}',
    action: 'Done',
    fields: (_) => [
      Field(c, 'One-line takeaway', autofocus: true, hint: 'What you will remember (optional)'),
    ],
    onSave: () async {
      await ref.mutate((s) => s.book.saveItem(i.copyWith(done: Value(today), takeaway: c.text.trim())));
      return null;
    },
  );
}

/// Item types that carry a free/paid badge the learner can correct.
const accessTypes = {'course', 'video', 'article', 'book'};

/// Adds an item to a topic, or edits [item]. The fields follow the type.
/// A pasted link can fill in the title (and the type, source and length)
/// from the page's own metadata; if that fails the learner types it.
Future<void> itemDialog(BuildContext context, WidgetRef ref, String topicId, {StudyItem? item}) async {
  final title = TextEditingController(text: item?.title ?? '');
  final url = TextEditingController(text: item?.url ?? '');
  final source = TextEditingController(text: item?.source ?? '');
  final minutes = TextEditingController(text: (item?.minutes ?? 0) > 0 ? '${item!.minutes}' : '');
  final stopped = TextEditingController(text: item?.stoppedAt ?? '');
  final takeaway = TextEditingController(text: item?.takeaway ?? '');
  final evidence = TextEditingController(text: item?.evidence ?? '');
  final content = item == null ? const <String, Object?>{} : itemContent(item);
  var type = item?.type ?? 'video';
  var required = item?.required ?? false;
  var access = itemAccess(content);
  var reading = false;
  String? linkNote;

  Future<void> readTitle(StateSetter setState) async {
    setState(() {
      reading = true;
      linkNote = null;
    });
    try {
      final info = await readLinkInfo(ref.read(httpClientProvider), url.text);
      title.text = info.title;
      if (source.text.trim().isEmpty) source.text = info.source;
      if (minutes.text.trim().isEmpty && info.minutes > 0) minutes.text = '${info.minutes}';
      if (item == null) type = info.type;
      if (access == Access.unknown) access = info.access;
      linkNote = 'Title read from the page. Check it, and the free or paid badge.';
    } on ResourceError catch (e) {
      linkNote = 'Could not read the title: ${e.message} Type it in.';
    } finally {
      // The dialog may have been closed while the page was being read.
      try {
        setState(() => reading = false);
      } on FlutterError {
        // Closed: nothing to show.
      }
    }
  }

  await showFormDialog(
    context,
    title: item == null ? 'Add item' : 'Edit item',
    fields: (setState) => [
      Choice(
        label: 'Type',
        value: type,
        options: addableItemTypes,
        onChanged: (v) => setState(() => type = v),
      ),
      if (type != 'note')
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Link',
              hintText: 'Paste any link: https://…',
              helperText: linkNote,
              helperMaxLines: 3,
              suffixIcon: reading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Read the title from the link',
                      icon: const Icon(Icons.title),
                      onPressed: () {
                        if (url.text.trim().isEmpty) return;
                        readTitle(setState);
                      },
                    ),
            ),
          ),
        ),
      Field(title, 'Title', autofocus: item == null),
      if (type != 'note') Field(source, 'Source', hint: 'Site, channel or publisher'),
      Field(minutes, 'Minutes', number: true),
      if (accessTypes.contains(type))
        Choice<Access>(
          label: 'Free or paid',
          value: access,
          options: {for (final a in Access.values) a: a.label},
          onChanged: (v) => setState(() => access = v),
        ),
      if (stoppableTypes.contains(type))
        Field(stopped, 'Stopped at', hint: type == 'video' ? '12:30' : 'page 84'),
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
      final extras = accessTypes.contains(type) ? withAccess(content, access) : (item?.content ?? '');
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
            content: extras,
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
              content: extras,
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

  Future<void> _editNote(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => _TopicNoteEditor(v.topic, v.course?.title ?? '', v.note?.body ?? '')),
  );
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

/// The topic's quiz (take it, or add and edit its questions) and its
/// interview drills.
class _CheckYourself extends ConsumerWidget {
  const _CheckYourself(
    this.topicId,
    this.items,
    this.criteria, {
    this.quizPercent,
    this.evidence = const {},
    this.programId,
    this.exams = const [],
    this.today = '',
  });
  final String topicId;
  final List<StudyItem> items;
  final List<Criterion> criteria;
  final int? quizPercent;

  /// The exam attempts so far, oldest first, and today, for the lock.
  final List<Assessment> exams;
  final String today;

  /// Each drill's practice so far.
  final Map<String, DrillEvidence> evidence;

  /// The topic's program, null for a course outside one.
  final String? programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = topicQuiz(items);
    final exam = quiz == null ? null : examRules(quiz);
    final drills = [
      for (final i in items)
        if (i.type == 'interview drill') i,
    ];
    return SectionCard(
      title: 'Check yourself',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (quiz == null) ...[
            const Text('No quiz yet. Three to ten questions of your own help it stick.'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add questions'),
                onPressed: () => openQuizEditor(context, topicId),
              ),
            ),
          ] else if (exam != null)
            _ExamCard(quiz, exam, exams, today: today, quizPercent: quizPercent)
          else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.quiz_outlined),
              title: Text(quiz.title),
              subtitle: Text(
                [
                  '${quizLength(quiz)} questions',
                  quizPercent == null ? 'not taken yet' : 'last score $quizPercent%',
                ].join(' · '),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(quizPercent == null ? 'Take the quiz' : 'Take it again'),
                  onPressed: () => openQuiz(context, quiz),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit questions'),
                  onPressed: () => openQuizEditor(context, topicId),
                ),
              ],
            ),
          ],
          for (final c in items.where((i) => i.type == capstoneType)) ...[
            const SizedBox(height: 12),
            CapstoneCard(c.id, key: Key('capstone-${c.id}')),
          ],
          for (final c in items.where((i) => i.type == scenarioType)) ...[
            const SizedBox(height: 12),
            ScenarioCard(c.id, key: Key('scenario-${c.id}')),
          ],
          const SizedBox(height: 12),
          Text(
            drills.isEmpty
                ? 'No interview drills yet. Add a question a panel might ask about this topic.'
                : 'Interview drills: tap one to practise it out loud against a timer and rate yourself.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          for (final i in drills)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                evidence[i.id]?.weak ?? false ? Icons.flag : Icons.record_voice_over_outlined,
                color: evidence[i.id]?.weak ?? false ? Theme.of(context).colorScheme.error : null,
              ),
              title: Text(i.title),
              subtitle: Text(
                [
                  'Interview drill',
                  if (drillCriterionText(i, criteria) case final c when c.isNotEmpty) 'tests $c',
                  if (isScenarioDrill(i)) 'scenario',
                  drillEvidenceText(evidence[i.id] ?? const DrillEvidence()),
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openDrill(context, i.id),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add drill'),
                onPressed: () => addDrillDialog(context, ref, topicId, criteria),
              ),
              TextButton.icon(
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('Story bank'),
                onPressed: () => openStoryBank(context, programId: programId),
              ),
              if (programId != null)
                TextButton.icon(
                  icon: const Icon(Icons.event_available_outlined),
                  label: const Text('Before the interview'),
                  onPressed: () => openBeforeInterview(context, programId!),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A quiz the plan made a timed exam: its rules, the retake lock, the
/// attempts so far as a chart, and buttons to start it or practise it
/// (practice is never counted as an attempt).
class _ExamCard extends StatelessWidget {
  const _ExamCard(this.quiz, this.rules, this.attempts, {required this.today, this.quizPercent});
  final StudyItem quiz;
  final ExamRules rules;
  final List<Assessment> attempts;
  final String today;
  final int? quizPercent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final next = examNextDay(attempts, rules);
    final locked = examLocked(next, today);
    final results = [for (final a in attempts) ?ExamResult.of(a)];
    final last = results.lastOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined),
          title: Text(examTitle(quiz)),
          subtitle: Text(
            [
              '${quizLength(quiz)} questions in ${minutesText(rules.minutes)}',
              'pass mark ${rules.passPercent}%',
              if (last == null)
                'not taken yet'
              else
                'last attempt ${last.percent}% (${last.passed ? 'passed' : 'not passed'})',
            ].join(' · '),
          ),
        ),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Next exam attempt from ${niceDate(next!)}.', style: t.bodyMedium),
          ),
        if (results.isNotEmpty) ...[
          Text('Exam history', style: t.labelLarge),
          const SizedBox(height: 4),
          Semantics(
            label: 'Exam scores, oldest first: ${[for (final r in results) '${r.percent}%'].join(', ')}',
            excludeSemantics: true,
            child: BarChart(
              values: [for (final r in results) r.percent],
              labels: [for (final a in attempts.where((a) => ExamResult.of(a) != null)) _shortDay(a.day)],
              unit: '%',
              height: 80,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!locked)
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: Text(last == null ? 'Start the exam' : 'Take the exam again'),
                onPressed: () => openQuiz(context, quiz),
              ),
            OutlinedButton(
              onPressed: () => openQuiz(context, quiz, practice: true),
              child: Text(locked ? 'Practise anyway (not counted)' : 'Practise (not counted)'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit questions'),
              onPressed: () => openQuizEditor(context, quiz.topicId),
            ),
          ],
        ),
      ],
    );
  }
}

/// Items a plan sent again without: kept with what the learner did on them,
/// not counted. Each can be put back in use.
class _Retired extends ConsumerWidget {
  const _Retired(this.items);
  final List<StudyItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'No longer in the plan',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('The plan stopped sending these. They are kept, but no longer count for the topic.'),
        for (final i in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i.title),
            subtitle: Text('${itemTypes[i.type] ?? i.type} · set aside ${niceDate(i.retired)}'),
            trailing: TextButton(
              onPressed: () => ref.mutate((s) => s.book.unretireItem(i)),
              child: const Text('Use again'),
            ),
          ),
      ],
    ),
  );
}

/// "27/11" for 2026-11-27: short enough for a chart label.
String _shortDay(String day) => day.length >= 10
    ? '${int.tryParse(day.substring(8, 10)) ?? 0}/${int.tryParse(day.substring(5, 7)) ?? 0}'
    : day;
