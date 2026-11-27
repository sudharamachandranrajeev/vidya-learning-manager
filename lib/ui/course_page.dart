import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/book.dart';
import '../domain/exam.dart';
import '../domain/quiz.dart';
import '../domain/stats.dart';
import '../domain/study_items.dart' show topicQuiz;
import 'capstone_page.dart';
import 'scenario_page.dart';
import 'charts.dart';
import 'common.dart';
import 'dialogs.dart';
import 'focus_page.dart';
import 'next_up_card.dart';
import 'resource_search.dart';
import 'topic_page.dart';
import 'zen.dart';

class CoursePage extends ConsumerWidget {
  const CoursePage(this.id, {super.key});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(statsProvider),
      builder: (s) {
        final c = s.courses.where((x) => x.id == id).firstOrNull;
        if (c == null) return const Scaffold(body: Center(child: Text('This course was deleted.')));
        final t = Theme.of(context).textTheme;
        final topics = s.topicsOf(id);
        final tests = s.assessments.where((a) => a.courseId == id).toList()
          ..sort((a, b) => b.day.compareTo(a.day));
        final spent = s.hoursOn(id);
        final items = ref.watch(itemsProvider).value ?? const [];
        final quiz = lastQuizPercents(s.assessments);
        return Scaffold(
          appBar: AppBar(
            title: CourseTitleHero(
              id,
              child: Text(c.title, style: Theme.of(context).appBarTheme.titleTextStyle),
            ),
            actions: [
              IconButton(
                tooltip: 'Find free resources for this course',
                icon: const Icon(Icons.travel_explore),
                onPressed: () => openResourceSearch(context, query: c.title, topics: topics),
              ),
              IconButton(
                tooltip: 'Focus on this course',
                icon: const Icon(Icons.self_improvement),
                onPressed: () => openFocus(context, courseId: id),
              ),
              if (c.url.isNotEmpty)
                IconButton(
                  tooltip: 'Open link',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => openLink(context, c.url),
                ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      await editCourseDialog(context, ref, c);
                    case 'delete':
                      if (!await askSure(context, 'Delete course?', 'Its topics are deleted too.') ||
                          !context.mounted) {
                        return;
                      }
                      await ref.mutate((x) => x.book.removeCourse(id));
                      if (context.mounted) Navigator.pop(context);
                    default:
                      await ref.mutate((x) => x.book.setCourseStatus(c, v, today: s.today));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  for (final (k, l) in [
                    ('planned', 'Mark planned'),
                    ('doing', 'Mark in progress'),
                    ('done', 'Mark complete'),
                    ('dropped', 'Drop'),
                  ])
                    if (c.status != k) PopupMenuItem(value: k, child: Text(l)),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => logSessionDialog(context, ref, courseId: id),
            icon: const Icon(Icons.timer_outlined),
            label: const Text('Log time'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Chip(label: Text(courseKinds[c.kind] ?? c.kind)),
                          Chip(
                            label: Text(switch (c.status) {
                              'done' => 'Complete',
                              'doing' => 'In progress',
                              'dropped' => 'Dropped',
                              _ => 'Planned',
                            }),
                          ),
                          if (c.provider.isNotEmpty) Chip(label: Text(c.provider)),
                          if (c.due != null) Chip(label: Text('Due ${niceDate(c.due!)}')),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Meter(
                        'Progress',
                        s.courseProgress(c),
                        trailing:
                            '${spent.toStringAsFixed(1)} h studied${c.hours > 0 ? ' of ~${c.hours} h' : ''}',
                      ),
                      const SizedBox(height: 12),
                      NextUpCard(courseId: id),
                      SectionCard(
                        title: 'Topics',
                        trailing: IconButton(
                          tooltip: 'Add topic',
                          icon: const Icon(Icons.add),
                          onPressed: () => addTopicDialog(context, ref, id),
                        ),
                        child: topics.isEmpty
                            ? const Text('Break the course into topics to track it.')
                            : Column(
                                children: [
                                  for (final tp in topics)
                                    Dismissible(
                                      key: ValueKey(tp.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 16),
                                        child: const Icon(Icons.delete_outline),
                                      ),
                                      confirmDismiss: (_) => askSure(context, 'Delete topic?', tp.title),
                                      onDismissed: (_) => ref.mutate((x) => x.book.removeTopic(tp.id)),
                                      child: _TopicTile(
                                        tp,
                                        [
                                          for (final i in items)
                                            if (i.topicId == tp.id) i,
                                        ],
                                        today: s.today,
                                        quizPercent: quiz[tp.id],
                                        exams: examAttempts(s.assessments, tp.id),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      if ([
                            for (final i in items)
                              if (i.type == 'capstone' && topics.any((tp) => tp.id == i.topicId)) i,
                          ]
                          case final caps when caps.isNotEmpty)
                        SectionCard(
                          title: caps.length == 1 ? 'Capstone' : 'Capstones',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final c in caps) CapstoneCard(c.id, key: Key('course-capstone-${c.id}')),
                            ],
                          ),
                        ),
                      if ([
                            for (final i in items)
                              if (i.type == 'scenario' &&
                                  i.retired.isEmpty &&
                                  topics.any((tp) => tp.id == i.topicId))
                                i,
                          ]
                          case final tests when tests.isNotEmpty)
                        SectionCard(
                          title: tests.length == 1 ? 'Stress test' : 'Stress tests',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final (k, c) in tests.indexed) ...[
                                if (k > 0) const SizedBox(height: 12),
                                ScenarioCard(c.id, key: Key('course-scenario-${c.id}')),
                              ],
                            ],
                          ),
                        ),
                      SectionCard(
                        title: 'Tests',
                        trailing: IconButton(
                          tooltip: 'Record a test',
                          icon: const Icon(Icons.add),
                          onPressed: () => addAssessmentDialog(context, ref, courseId: id),
                        ),
                        child: tests.isEmpty
                            ? const Text('No tests recorded.')
                            : Column(
                                children: [
                                  if (tests.length > 1)
                                    Sparkline([for (final a in tests.reversed) Stats.percentOf(a)]),
                                  for (final a in tests)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(a.title),
                                      subtitle: Text(niceDate(a.day)),
                                      trailing: Text(
                                        '${Stats.percentOf(a).round()}%',
                                        style: t.titleMedium?.merge(tabular),
                                      ),
                                      onLongPress: () async {
                                        if (await askSure(context, 'Delete test?', a.title) &&
                                            context.mounted) {
                                          await ref.mutate((x) => x.book.remove(x.db.learnAssessments, a.id));
                                        }
                                      },
                                    ),
                                ],
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

/// A topic on the course page: the box ticks it off, a tap opens its page.
class _TopicTile extends ConsumerWidget {
  const _TopicTile(this.tp, this.items, {required this.today, this.quizPercent, this.exams = const []});
  final Topic tp;
  final List<StudyItem> items;
  final String today;
  final int? quizPercent;

  /// The topic's exam attempts, oldest first.
  final List<Assessment> exams;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = items.where((i) => i.done != null).length;
    final quiz = topicQuiz(items);
    final exam = quiz == null ? null : examRules(quiz);
    final nextExam = exam == null ? null : examNextDay(exams, exam);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: tp.done != null,
        onChanged: (v) =>
            tickTopic(context, ref, tp, items, v ?? false, today: today, quizPercent: quizPercent),
      ),
      title: Text(
        tp.title,
        style: tp.done != null ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
      ),
      subtitle: Text(
        [
          tp.done != null ? 'Done ${relativeDay(tp.done!, today)}' : minutesText(tp.minutes),
          if (items.isNotEmpty) '$done of ${items.length} items',
          if (quizPercent != null) '${exam != null ? 'exam' : 'quiz'} $quizPercent%',
          if (exam != null && quizPercent == null) 'exam not taken',
          if (examLocked(nextExam, today)) 'next exam ${niceDate(nextExam!)}',
        ].join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openTopic(context, tp.id),
    );
  }
}
