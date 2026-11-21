/// "Next up": the one thing to study next, so the learner opens Vidya and
/// starts instead of planning. Plain rules over rows; nothing here writes.
library;

import '../db/database.dart';
import 'study_items.dart';

/// Why [NextUp.item] (or the topic) was picked.
enum NextReason {
  /// The topic's next required item still open.
  required,

  /// Required items are done; the topic's quiz is not yet passed.
  quiz,

  /// Nothing required is open; the topic's next optional item.
  optional,

  /// The topic has nothing open (or no items at all): open it, study, tick.
  topic,
}

typedef NextUp = ({Program? program, Course course, Topic topic, StudyItem? item, NextReason reason});

/// The next thing to study. Programs that are paused or done, and courses
/// that are dropped or done, are skipped. Programs go oldest first, then
/// courses with no program; inside a program, courses go by due date (a
/// plan's week order) and then the order they were added; topics and items
/// by their list order. In the first open topic, the next open required
/// item comes first, then an unpassed quiz, then any other open item
/// (interview drills aside). [quizPercents] holds each topic's last quiz
/// score. With [courseId], only that course. Null when nothing is waiting.
NextUp? nextUp({
  required List<Program> programs,
  required List<Course> courses,
  required List<Topic> topics,
  required List<StudyItem> items,
  Map<String, int> quizPercents = const {},
  String? courseId,
}) {
  final live = {
    for (final p in programs)
      if (!p.deleted) p.id: p,
  };
  final order =
      [
        for (final (k, p) in programs.indexed)
          if (!p.deleted && p.status == 'active') (k, p),
      ]..sort(
        (a, b) => a.$2.started != b.$2.started ? a.$2.started.compareTo(b.$2.started) : a.$1.compareTo(b.$1),
      );
  final rank = {for (final (k, (_, p)) in order.indexed) p.id: k};

  int groupOf(Course c) {
    final pid = c.programId;
    if (pid == null || !live.containsKey(pid)) return order.length; // no program: after the programs
    return rank[pid] ?? -1; // -1: paused or done program
  }

  final open =
      [
        for (final (k, c) in courses.indexed)
          if (!c.deleted &&
              c.status != 'done' &&
              c.status != 'dropped' &&
              (courseId == null || c.id == courseId) &&
              groupOf(c) >= 0)
            (k, c),
      ]..sort((a, b) {
        final g = groupOf(a.$2).compareTo(groupOf(b.$2));
        if (g != 0) return g;
        final d = (a.$2.due ?? '9999-12-31').compareTo(b.$2.due ?? '9999-12-31');
        if (d != 0) return d;
        final add = a.$2.added.compareTo(b.$2.added);
        return add != 0 ? add : a.$1.compareTo(b.$1);
      });

  final byTopic = <String, List<StudyItem>>{};
  for (final i in items) {
    if (!i.deleted && i.retired.isEmpty) (byTopic[i.topicId] ??= []).add(i);
  }
  int byOrd(({int ord, String id}) a, ({int ord, String id}) b) =>
      a.ord != b.ord ? a.ord.compareTo(b.ord) : a.id.compareTo(b.id);

  for (final (_, c) in open) {
    final list = [
      for (final t in topics)
        if (t.courseId == c.id && !t.deleted && t.done == null) t,
    ]..sort((a, b) => byOrd((ord: a.ord, id: a.id), (ord: b.ord, id: b.id)));
    for (final t in list) {
      final its = [...?byTopic[t.id]]..sort((a, b) => byOrd((ord: a.ord, id: a.id), (ord: b.ord, id: b.id)));
      final program = live[c.programId];
      NextUp pick(StudyItem? i, NextReason r) => (program: program, course: c, topic: t, item: i, reason: r);
      final req = openRequired(its).firstOrNull;
      if (req != null) return pick(req, NextReason.required);
      if (quizPending(its, quizPercents[t.id])) return pick(topicQuiz(its), NextReason.quiz);
      final other = its
          .where((i) => i.done == null && i.type != 'interview drill' && i.type != 'quiz')
          .firstOrNull;
      if (other != null) return pick(other, NextReason.optional);
      return pick(null, NextReason.topic);
    }
  }
  return null;
}

/// Where to pick a video or book up again ("Resume at 12:30"), or ''.
String resumeText(StudyItem i) =>
    stoppableTypes.contains(i.type) && i.stoppedAt.trim().isNotEmpty ? 'Resume at ${i.stoppedAt.trim()}' : '';

/// The Monday of [day]'s week (weeks run Monday to Sunday).
String weekStart(String day) {
  final d = DateTime.parse('${day}T00:00:00Z');
  return d.subtract(Duration(days: d.weekday - 1)).toIso8601String().substring(0, 10);
}

/// Minutes studied from this week's Monday up to and including [today].
int minutesThisWeek(Iterable<StudySession> sessions, String today) {
  final from = weekStart(today);
  return sessions
      .where((s) => !s.deleted && s.day.compareTo(from) >= 0 && s.day.compareTo(today) <= 0)
      .fold(0, (a, s) => a + s.minutes);
}

/// Minutes logged on each topic.
Map<String, int> minutesByTopic(Iterable<StudySession> sessions) {
  final out = <String, int>{};
  for (final s in sessions) {
    final t = s.topicId;
    if (t != null && !s.deleted) out[t] = (out[t] ?? 0) + s.minutes;
  }
  return out;
}

/// The weekly time target line on Home: progress only, never a penalty or
/// a nudge about missed days. [target] 0 means no target.
String weekTargetText(int done, int target) {
  if (target <= 0) return '';
  if (done >= target) return 'Target reached this week. Anything more is a bonus.';
  return '$done of $target min this week.';
}
