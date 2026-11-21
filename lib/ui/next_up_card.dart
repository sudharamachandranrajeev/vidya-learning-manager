import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/next_up.dart';
import '../domain/study_items.dart';
import 'common.dart';
import 'quiz_page.dart';
import 'topic_page.dart';
import 'zen.dart';

/// "Next up": the one thing to study next, with one tap to start it. On
/// Home it looks across every program; on a course page ([courseId]) only
/// at that course. Says so calmly when nothing is waiting.
class NextUpCard extends ConsumerWidget {
  const NextUpCard({super.key, this.courseId});
  final String? courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(nextUpProvider(courseId));
    if (!async.hasValue) return const SizedBox.shrink();
    final n = async.value;
    final t = Theme.of(context).textTheme;
    if (n == null) {
      return SectionCard(
        title: 'Next up',
        child: Text(
          courseId == null
              ? 'Nothing is waiting. Start a course on Learn whenever you like.'
              : 'Nothing left to study here.',
          style: t.bodyMedium?.copyWith(color: muted(context)),
        ),
      );
    }
    final i = n.item;
    final where = [if (courseId == null) n.course.title, if (i != null) n.topic.title].join(' · ');
    final facts = [
      if (i != null) itemTypes[i.type] ?? i.type,
      if (i != null && i.minutes > 0) minutesText(i.minutes),
      if (i == null) minutesText(n.topic.minutes),
      if (i != null && resumeText(i).isNotEmpty) resumeText(i),
      switch (n.reason) {
        NextReason.required => 'required',
        NextReason.quiz => 'check what stuck',
        NextReason.optional => 'optional',
        NextReason.topic => 'open the topic',
      },
    ].join(' · ');
    final (label, icon, VoidCallback go) = switch (i) {
      null => ('Open topic', Icons.menu_book_outlined, () => openTopic(context, n.topic.id)),
      final q when q.type == 'quiz' => ('Take the quiz', Icons.quiz_outlined, () => openQuiz(context, q)),
      final x when x.url.isNotEmpty => (
        resumeText(x).isNotEmpty ? 'Resume' : 'Open',
        Icons.open_in_new,
        () => openLink(context, x.url),
      ),
      _ => ('Open', Icons.menu_book_outlined, () => openTopic(context, n.topic.id)),
    };
    final opensTopic = i == null || (i.type != 'quiz' && i.url.isEmpty);
    return SectionCard(
      title: 'Next up',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(i?.title ?? n.topic.title, style: t.titleMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (where.isNotEmpty)
            Text(where, style: t.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(facts, style: t.bodySmall?.copyWith(color: muted(context))),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(icon: Icon(icon), label: Text(label), onPressed: go),
              if (!opensTopic)
                TextButton(onPressed: () => openTopic(context, n.topic.id), child: const Text('Topic')),
            ],
          ),
        ],
      ),
    );
  }
}
