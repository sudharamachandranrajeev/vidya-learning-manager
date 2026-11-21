import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';

import '../db/database.dart';
import 'book.dart';
import 'next_up.dart';
import 'quiz.dart';
import 'stats.dart';
import 'study_items.dart';

/// The portfolio as Markdown, to paste into a CV, a profile or a README:
/// skills by category, the work that shows them, and what was completed.
String portfolioMarkdown(Stats s) {
  final out = StringBuffer('# Portfolio\n');

  final rated = s.skills.where((k) => k.level > 0).toList()
    ..sort((a, b) => b.level != a.level ? b.level.compareTo(a.level) : a.name.compareTo(b.name));
  if (rated.isNotEmpty) {
    out.write('\n## Skills\n\n');
    final byCategory = <String, List<String>>{};
    for (final k in rated) {
      (byCategory[k.category] ??= []).add('${k.name} (${skillLevels[k.level.clamp(0, 5)]})');
    }
    for (final e in byCategory.entries) {
      out.write('- **${e.key}:** ${e.value.join(', ')}\n');
    }
  }

  if (s.portfolio.isNotEmpty) {
    out.write('\n## Work\n');
    for (final p in s.portfolio) {
      final title = p.url.isEmpty ? p.title : '[${p.title}](${p.url})';
      out.write('\n### $title\n\n');
      out.write('${portfolioKinds[p.kind] ?? p.kind} · ${niceDate(p.day)}\n');
      if (p.summary.isNotEmpty) out.write('\n${p.summary}\n');
      if (p.skills.isNotEmpty) out.write('\nSkills: ${p.skills}\n');
    }
  }

  final done = s.courses.where((c) => c.status == 'done').toList()
    ..sort((a, b) => (b.finished ?? '').compareTo(a.finished ?? ''));
  if (done.isNotEmpty) {
    out.write('\n## Learning completed\n\n');
    for (final c in done) {
      final parts = [
        courseKinds[c.kind] ?? c.kind,
        if (c.provider.isNotEmpty) c.provider,
        if (c.finished != null) niceDate(c.finished!),
      ];
      out.write('- ${c.title} (${parts.join(', ')})\n');
    }
  }

  out.write(
    '\n---\n\n${s.hours.round()} hours of study · ${s.topicsDone} topics · '
    '${s.coursesDone} courses completed\n',
  );
  return out.toString();
}

/// The flashcards as a plain, versioned JSON share file: text, deck and media
/// references only. Schedules and review history stay on this device, so the
/// receiver starts every card fresh. Local media paths do not travel; web
/// addresses do.
String decksJson(List<Flashcard> cards) => const JsonEncoder.withIndent('  ').convert({
  'format': 'vidya-decks',
  'version': 1,
  'cards': [
    for (final c in [
      ...cards,
    ]..sort((a, b) => a.deck != b.deck ? a.deck.compareTo(b.deck) : a.front.compareTo(b.front)))
      {
        'deck': c.deck,
        'front': c.front,
        'back': c.back,
        if (c.image.isNotEmpty) 'image': c.image,
        if (c.audio.isNotEmpty) 'audio': c.audio,
      },
  ],
});

/// Everything the learner's own history export holds (see [historyMarkdown]
/// and [historyJson]): rows that are not deleted.
typedef History = ({
  String today,
  List<Program> programs,
  List<Course> courses,
  List<Topic> topics,
  List<StudyItem> items,
  List<Assessment> tests,
  List<StudySession> sessions,
  List<Note> notes,
});

/// The learner's notes for the export: their own words only. Study guides
/// and topic notes made from a plan and never edited are the plan's text,
/// so they stay out.
List<Note> _ownNotes(History h) => [
  for (final n in h.notes)
    if (!isPlanNote(n)) n,
]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

/// The courses of [programId] (null: those with no program) in the order
/// they were added.
List<Course> _coursesOf(History h, String? programId) {
  final ids = {for (final p in h.programs) p.id};
  return [
    for (final c in h.courses)
      if (programId == null ? (c.programId == null || !ids.contains(c.programId)) : c.programId == programId)
        c,
  ];
}

List<Topic> _topicsOf(History h, String courseId) =>
    h.topics.where((t) => t.courseId == courseId).toList()..sort((a, b) => a.ord.compareTo(b.ord));

List<StudyItem> _itemsOf(History h, String topicId) =>
    h.items.where((i) => i.topicId == topicId).toList()..sort((a, b) => a.ord.compareTo(b.ord));

/// The learner's own history as Markdown: each program, its courses and
/// topics with their status, the items done (with takeaways and evidence),
/// quiz and test scores, time studied, and the learner's notes.
String historyMarkdown(History h) {
  final quiz = lastQuizPercents(h.tests);
  final perTopic = minutesByTopic(h.sessions);
  final total = h.sessions.fold(0, (a, s) => a + s.minutes);
  final out = StringBuffer('# My learning history\n\nExported ${niceDate(h.today)}. ');
  out.write('${(total / 60).toStringAsFixed(1)} hours of study logged.\n');

  void course(Course c) {
    final facts = [
      courseKinds[c.kind] ?? c.kind,
      c.status,
      if (c.provider.isNotEmpty) c.provider,
      if (c.finished != null) 'finished ${niceDate(c.finished!)}',
    ];
    out.write('\n### ${c.title}\n\n${facts.join(' · ')}\n');
    final topics = _topicsOf(h, c.id);
    if (topics.isNotEmpty) out.write('\n');
    for (final t in topics) {
      final items = _itemsOf(h, t.id);
      final bits = [
        topicStatus(t, items).label,
        if (t.done != null) niceDate(t.done!),
        if (quiz[t.id] case final p?) 'last quiz $p%',
        if (perTopic[t.id] case final m? when m > 0) '$m min studied',
      ];
      out.write('- [${t.done != null ? 'x' : ' '}] ${t.title} (${bits.join(', ')})\n');
      if (t.tickNote.isNotEmpty) out.write('  - Ticked off because: ${t.tickNote}\n');
      for (final i in items.where((i) => i.done != null)) {
        final title = i.url.isEmpty ? i.title : '[${i.title}](${i.url})';
        final more = [
          if (i.takeaway.isNotEmpty) i.type == 'note' ? i.takeaway : 'Takeaway: ${i.takeaway}',
          if (i.evidence.isNotEmpty) 'Evidence: ${i.evidence}',
        ];
        out.write(
          '  - $title (${itemTypes[i.type] ?? i.type}, done ${niceDate(i.done!)})'
          '${more.isEmpty ? '' : '. ${more.join('. ')}'}\n',
        );
      }
    }
  }

  for (final p in h.programs) {
    out.write('\n## ${p.title}\n\n${p.status} · started ${niceDate(p.started)}');
    if (p.role.isNotEmpty) out.write(' · for the role ${p.role}');
    out.write('\n');
    if (p.goal.isNotEmpty) out.write('\n${p.goal}\n');
    _coursesOf(h, p.id).forEach(course);
  }
  final loose = _coursesOf(h, null);
  if (loose.isNotEmpty) {
    out.write('\n## Courses without a program\n');
    loose.forEach(course);
  }

  final tests = h.tests.toList()..sort((a, b) => a.day.compareTo(b.day));
  if (tests.isNotEmpty) {
    out.write('\n## Quizzes and tests\n\n');
    for (final a in tests) {
      out.write(
        '- ${niceDate(a.day)}: ${a.title}, ${_num(a.score)} of ${_num(a.max)} (${percentOf(a.score, a.max)}%)\n',
      );
    }
  }

  final notes = _ownNotes(h);
  if (notes.isNotEmpty) {
    out.write('\n## Notes\n');
    for (final n in notes) {
      out.write('\n### ${n.title}\n\n');
      out.write('Updated ${niceDate(n.updated)}${n.tags.isEmpty ? '' : ' · tags: ${n.tags}'}\n');
      if (n.body.trim().isNotEmpty) out.write('\n${n.body.trim()}\n');
    }
  }
  return out.toString();
}

String _num(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// The same history as a versioned JSON file (`vidya-history`, version 1),
/// for keeping or for another tool to read.
String historyJson(History h) {
  final quiz = lastQuizPercents(h.tests);
  final perTopic = minutesByTopic(h.sessions);
  final courseTitle = {for (final c in h.courses) c.id: c.title};
  final topicTitle = {for (final t in h.topics) t.id: t.title};
  Map<String, Object?> course(Course c) => {
    'title': c.title,
    'kind': c.kind,
    'status': c.status,
    if (c.provider.isNotEmpty) 'provider': c.provider,
    if (c.url.isNotEmpty) 'url': c.url,
    'added': c.added,
    if (c.finished != null) 'finished': c.finished,
    'topics': [
      for (final t in _topicsOf(h, c.id))
        {
          'title': t.title,
          'status': topicStatus(t, _itemsOf(h, t.id)).name,
          if (t.done != null) 'done': t.done,
          if (t.tickNote.isNotEmpty) 'tickNote': t.tickNote,
          'lastQuizPercent': ?quiz[t.id],
          if (perTopic[t.id] case final m? when m > 0) 'minutesStudied': m,
          'itemsDone': [
            for (final i in _itemsOf(h, t.id).where((i) => i.done != null))
              {
                'type': i.type,
                'title': i.title,
                if (i.url.isNotEmpty) 'url': i.url,
                'done': i.done,
                if (i.takeaway.isNotEmpty) 'takeaway': i.takeaway,
                if (i.evidence.isNotEmpty) 'evidence': i.evidence,
              },
          ],
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert({
    'format': 'vidya-history',
    'version': 1,
    'exported': h.today,
    'programs': [
      for (final p in h.programs)
        {
          'title': p.title,
          if (p.goal.isNotEmpty) 'goal': p.goal,
          if (p.role.isNotEmpty) 'role': p.role,
          'status': p.status,
          'started': p.started,
          if (p.target != null) 'target': p.target,
          'courses': [for (final c in _coursesOf(h, p.id)) course(c)],
        },
    ],
    'courses': [for (final c in _coursesOf(h, null)) course(c)],
    'tests': [
      for (final a in h.tests.toList()..sort((a, b) => a.day.compareTo(b.day)))
        {
          'day': a.day,
          'title': a.title,
          'score': a.score,
          'max': a.max,
          'percent': percentOf(a.score, a.max),
          'course': ?courseTitle[a.courseId],
          'topic': ?topicTitle[a.topicId],
        },
    ],
    'sessions': [
      for (final s in h.sessions.toList()..sort((a, b) => a.day.compareTo(b.day)))
        {
          'day': s.day,
          'minutes': s.minutes,
          'course': ?courseTitle[s.courseId],
          'topic': ?topicTitle[s.topicId],
          if (s.note.isNotEmpty) 'note': s.note,
        },
    ],
    'notes': [
      for (final n in _ownNotes(h))
        {'title': n.title, 'tags': n.tags, 'created': n.created, 'updated': n.updated, 'body': n.body},
    ],
  });
}
