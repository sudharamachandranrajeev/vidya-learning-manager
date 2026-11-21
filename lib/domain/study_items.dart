/// Study items and topic status: what a topic page holds and how a topic
/// counts as earned. Plain rules over rows; nothing here writes.
library;

import 'dart:convert';

import '../db/database.dart';

/// Every item type, with its label. The keys are what plans and the
/// database use.
const itemTypes = {
  'course': 'Course',
  'video': 'Video',
  'article': 'Article',
  'book': 'Book',
  'practice task': 'Practice task',
  'quiz': 'Quiz',
  'interview drill': 'Interview drill',
  'note': 'Note',
};

/// Types listed under "Check yourself" rather than with the other items.
const checkTypes = {'quiz', 'interview drill'};

/// Types that have a place to stop and come back to.
const stoppableTypes = {'video', 'book'};

/// Types done with a one-line takeaway.
const takeawayTypes = {'article', 'book'};

/// The type key for what a plan or a person wrote ("Practice", "docs",
/// "drill"), or '' when it is not one Vidya knows.
String itemTypeOf(String raw) {
  final t = raw.trim().toLowerCase().replaceAll(RegExp(r'[_\-\s]+'), ' ');
  if (itemTypes.containsKey(t)) return t;
  return switch (t) {
    'task' || 'practice' || 'exercise' || 'project' => 'practice task',
    'drill' || 'interview' || 'interview question' => 'interview drill',
    'docs' || 'doc' || 'reading' || 'documentation' || 'link' || 'website' || 'page' => 'article',
    'chapter' || 'textbook' => 'book',
    'reflection' || 'text' => 'note',
    'mooc' || 'class' || 'module' => 'course',
    'youtube' || 'podcast' || 'lecture' => 'video',
    'test' || 'self test' => 'quiz',
    _ => '',
  };
}

/// The type a bare link most likely is: YouTube and Vimeo are videos, any
/// other web address an article.
String linkTypeOf(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.endsWith('youtube.com') || host == 'youtu.be' || host.endsWith('vimeo.com')) return 'video';
  return 'article';
}

/// The first web address in [text], or ''.
String firstUrl(String text) => RegExp(r'https?://[^\s<>"]+').firstMatch(text)?[0] ?? '';

/// A plan resource line ("Title — https://…", an address, or plain text)
/// as an item: a link becomes a video or article, plain text a note.
({String type, String title, String url}) resourceItem(String line) {
  final r = line.trim();
  final url = firstUrl(r);
  if (url.isEmpty) return (type: 'note', title: r, url: '');
  var title = r.replaceFirst(url, '').trim();
  title = title.replaceAll(RegExp(r'^[\s—–:\-|]+|[\s—–:\-|]+$'), '').trim();
  return (type: linkTypeOf(url), title: title.isEmpty ? url : title, url: url);
}

/// The stable id of a plan item without one of its own: its address when
/// it has one, else its type and title. Lower case, so case changes in the
/// plan do not make a twin.
String itemRef({required String type, required String title, String url = ''}) =>
    url.isNotEmpty ? 'url|${url.trim().toLowerCase()}' : '$type|${title.trim().toLowerCase()}';

/// A short hash, the same on every device, so a plan item or a split study
/// guide gets the same row id wherever it is made (and syncs as one row).
String stableHash(String s) {
  var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
  for (final c in utf8.encode(s)) {
    a = ((a ^ c) * 0x01000193) & 0xffffffff;
    b = ((b ^ c) * 0x0100019d) & 0xffffffff;
  }
  return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
}

/// The row id of the plan item [ref] in a topic.
String planItemId(String topicId, String ref) => '$topicId.i${stableHash(ref)}';

/// The row id of a topic's own note.
String topicNoteId(String topicId) => '$topicId.note';

/// The tag on topic notes made from a plan or study guide. They do not earn
/// experience until the learner writes in them (saving drops the tag).
const planNoteTag = 'from plan';

bool hasPlanNoteTag(Note n) => n.tags.split(',').any((t) => t.trim() == planNoteTag);

enum TopicStatus {
  notStarted('Not started'),
  studying('Studying'),
  review('Review'),
  done('Done');

  const TopicStatus(this.label);
  final String label;
}

/// Where a topic stands: done once ticked; else what the learner chose;
/// else studying once an item is done or the learner has written a note.
TopicStatus topicStatus(Topic t, Iterable<StudyItem> items, {bool wroteNote = false}) {
  if (t.done != null) return TopicStatus.done;
  if (t.status == 'review') return TopicStatus.review;
  if (t.status == 'studying') return TopicStatus.studying;
  if (wroteNote || items.any((i) => i.done != null)) return TopicStatus.studying;
  return TopicStatus.notStarted;
}

/// The required items still open.
List<StudyItem> openRequired(Iterable<StudyItem> items) => [
  for (final i in items)
    if (i.required && i.done == null) i,
];

/// Whether the topic is earned: it has required items and all are done.
/// (Version 2 adds a quiz score of at least 70%.)
bool topicEarned(Iterable<StudyItem> items) => items.any((i) => i.required) && openRequired(items).isEmpty;

/// Whether ticking the topic now asks for a short note: some required item
/// is still open.
bool tickNeedsNote(Iterable<StudyItem> items) => openRequired(items).isNotEmpty;

/// The topic's criteria refs.
List<String> criteriaRefs(Topic t) => [
  for (final c in t.criteria.split(','))
    if (c.trim().isNotEmpty) c.trim(),
];

/// An item's JSON extras (see `LearnItems.content`), empty when none.
Map<String, Object?> itemContent(StudyItem i) {
  if (i.content.isEmpty) return const {};
  try {
    final j = jsonDecode(i.content);
    return j is Map<String, Object?> ? j : const {};
  } on FormatException {
    return const {};
  }
}

/// How many questions a quiz item holds.
int quizLength(StudyItem i) => switch (itemContent(i)['questions']) {
  final List q => q.length,
  _ => 0,
};

/// One section of a course study guide (see `courseGuideMarkdown`): the
/// topic title from its `## n. Title (m min)` heading, the text under it,
/// and its trailing `- resource` lines.
typedef GuideSection = ({String title, String text, List<String> resources});

/// Splits a study guide into its topic sections.
List<GuideSection> guideSections(String markdown) {
  final heading = RegExp(r'^## \d+\.\s+(.+?)(?:\s+\(\d+(?:\.\d+)?\s*(?:min|h)\))?\s*$');
  final out = <GuideSection>[];
  String? title;
  var lines = <String>[];
  void flush() {
    final t = title;
    if (t == null) return;
    final text = lines.join('\n').trim();
    // The resources are the last block of "- " lines.
    final body = text.split('\n');
    var k = body.length;
    while (k > 0 && body[k - 1].startsWith('- ')) {
      k--;
    }
    final resources = k < body.length && (k == 0 || body[k - 1].trim().isEmpty)
        ? [for (final l in body.skip(k)) l.substring(2).trim()].where((r) => r.isNotEmpty).toList()
        : <String>[];
    out.add((title: t.trim(), text: text, resources: resources));
  }

  for (final line in markdown.split('\n')) {
    final m = heading.firstMatch(line);
    if (m != null) {
      flush();
      title = m[1];
      lines = [];
    } else if (line.startsWith('## ') || line.startsWith('# ')) {
      flush();
      title = null;
      lines = [];
    } else if (title != null) {
      lines.add(line);
    }
  }
  flush();
  return out;
}
