import 'dart:convert';
import 'dart:math';

import 'package:brahma_core/brahma_core.dart';

import 'cloze.dart';
import 'journey.dart';
import 'study_items.dart';

/// A whole study plan in one file: a program, its roadmap of courses with
/// topics, the skills it builds, flashcards and notes. Learners get one by
/// pasting [curriculumPrompt] into any AI chat and pasting the reply back, by
/// letting Vidya ask a connected AI, or by opening a saved `.json` file. Nothing here touches the database; see
/// `LearningBook.importCurriculum`.

class PlanTopic {
  const PlanTopic(
    this.title, {
    this.minutes = 30,
    this.details = '',
    this.resources = const [],
    this.items = const [],
    this.criteria = const [],
  });
  final String title;
  final int minutes;
  final String details;
  final List<String> resources;

  /// The topic's study items (format 2): its `items`, then one quiz item
  /// holding its `quiz` questions, then one item per `drills` entry.
  final List<PlanItem> items;

  /// Ids of the plan's [CurriculumPlan.criteria] this topic works towards.
  final List<String> criteria;
}

/// One study item in a plan (see study_items.dart for the types). [ref] is
/// its stable id: the plan's own `id`, or one made from its link or title.
class PlanItem {
  const PlanItem({
    required this.type,
    required this.title,
    required this.ref,
    this.url = '',
    this.source = '',
    this.licence = '',
    this.minutes = 0,
    this.required = false,
    this.content = '',
  });
  final String type, title, ref, url, source, licence, content;
  final int minutes;
  final bool required;
}

/// What the goal (a job, usually) asks for. [id] is what topics list.
typedef PlanCriterion = ({String id, String text, bool essential, String kind, String source, bool? shown});

class PlanCourse {
  const PlanCourse(
    this.title, {
    this.kind = 'course',
    this.hours = 0,
    this.provider = '',
    this.url = '',
    this.startWeek,
    this.dueWeek,
    this.summary = '',
    this.topics = const [],
  });
  final String title, kind, provider, url, summary;
  final int hours;

  /// Weeks from the day of import; [dueWeek] sets the course's due date.
  final int? startWeek, dueWeek;
  final List<PlanTopic> topics;

  /// Whether the course carries more than its topic titles, worth a note.
  bool get hasGuide =>
      summary.isNotEmpty || topics.any((t) => t.details.isNotEmpty || t.resources.isNotEmpty);
}

typedef PlanSkill = ({String name, String category, int target});

/// [id] is the sender's stable id for the card, '' when it has none: a
/// card with one is updated in place when the plan comes again.
typedef PlanCard = ({String id, String deck, String course, String front, String back});
typedef PlanNote = ({String title, String body, String tags});

class CurriculumPlan {
  const CurriculumPlan({
    required this.title,
    this.goal = '',
    this.targetDate,
    this.part = '',
    this.courses = const [],
    this.skills = const [],
    this.cards = const [],
    this.notes = const [],
    this.role = '',
    this.criteria = const [],
    this.journey,
  });
  final String title, goal, part;

  /// The job journey (format 3), null when the plan has none.
  final Journey? journey;

  /// The job role the plan is for (from Udyoga), '' otherwise.
  final String role;
  final List<PlanCriterion> criteria;

  /// yyyy-MM-dd, or null.
  final String? targetDate;
  final List<PlanCourse> courses;
  final List<PlanSkill> skills;
  final List<PlanCard> cards;
  final List<PlanNote> notes;

  int get topicCount => courses.fold(0, (a, c) => a + c.topics.length);
  int get itemCount => courses.fold(0, (a, c) => c.topics.fold(a, (b, t) => b + t.items.length));
}

const curriculumFormat = 'vidya-curriculum';

// Limits keep a runaway or hostile file from flooding the database.
const _maxCourses = 100, _maxTopics = 300, _maxCards = 5000, _maxNotes = 300, _maxSkills = 200;
const _maxTitle = 200, _maxText = 4000, _maxBody = 40000;
const _maxItems = 50, _maxQuiz = 20, _maxDrills = 30, _maxCriteria = 200, _maxAllItems = 5000;

/// The newest plan format this Vidya reads. Format 1 plans (no items,
/// quiz, drills or criteria) and format 2 plans (no journey) still import.
/// A `journey` is read whatever the version says: Udyoga adds it to the
/// plans it sends as version 1, which older Vidyas import without it.
const curriculumVersion = 3;

const _kinds = {'course', 'book', 'certification', 'degree', 'project', 'practice'};

/// Reads one reply, or several parts of a long plan pasted one after
/// another. Each part is a whole plan for some of the courses.
List<CurriculumPlan> parseCurriculumParts(String text) {
  final objects = _jsonObjects(text);
  if (objects.length < 2) return [parseCurriculum(text)];
  return [for (final o in objects) parseCurriculum(o)];
}

/// The `{…}` blocks at the top level of [t], skipping braces inside strings.
List<String> _jsonObjects(String t) {
  final out = <String>[];
  var depth = 0, start = 0, inString = false, escaped = false;
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      // Quotes in the prose around the JSON are not strings.
      inString = depth > 0;
    } else if (c == '{') {
      if (depth++ == 0) start = i;
    } else if (c == '}' && depth > 0 && --depth == 0) {
      out.add(t.substring(start, i + 1));
    }
  }
  return out;
}

/// Parts named "k of N" that are not among [plans], for a warning.
List<int> missingParts(List<CurriculumPlan> plans) {
  final have = <int>{};
  var total = 0;
  for (final p in plans) {
    final m = RegExp(r'^(\d+)\s*of\s*(\d+)$').firstMatch(p.part.trim());
    if (m == null) continue;
    have.add(int.parse(m[1]!));
    total = max(total, min(int.parse(m[2]!), 50));
  }
  return [
    for (var k = 1; k <= total; k++)
      if (!have.contains(k)) k,
  ];
}

/// Reads a plan from a file or a pasted AI reply. Tolerates what chat apps
/// add around the JSON (prose, ``` fences) and trailing commas. Throws a
/// [FormatException] with a message fit for the learner.
CurriculumPlan parseCurriculum(String text) {
  final t = text.replaceFirst('﻿', '');
  final start = t.indexOf('{'), end = t.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw const FormatException('No plan found. Paste the whole reply, starting with { and ending with }.');
  }
  final body = t.substring(start, end + 1);
  Object? j;
  try {
    j = jsonDecode(body);
  } on FormatException {
    try {
      j = jsonDecode(body.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!));
    } on FormatException {
      throw const FormatException(
        'The plan is cut off or not valid JSON. If the reply was long, ask the AI to send it in parts.',
      );
    }
  }
  if (j is! Map) throw const FormatException('This is not a Vidya plan.');
  final format = j['format'];
  if (format != null && format != curriculumFormat) {
    throw FormatException(
      format == 'vidya-decks' ? 'This is a card file: import it on Review.' : 'This is not a Vidya plan.',
    );
  }
  final version = j['version'];
  if (version is num && version > curriculumVersion) {
    throw const FormatException('This plan was made for a newer Vidya. Update Vidya and try again.');
  }

  final program = j['program'] is Map ? j['program'] as Map : j;
  final title = _str(program['title'], _maxTitle);
  if (title.isEmpty) throw const FormatException('The plan needs a program title.');
  final target = _str(program['targetDate'], 10);

  final criteria = <PlanCriterion>[];
  final criteriaSeen = <String>{};
  for (final c in _list(j['criteria'], _maxCriteria, 'criteria')) {
    final m = c is Map ? c : {'text': c};
    final text = _str(m['text'], _maxText);
    if (text.isEmpty) continue;
    final id = _ref(m['id']);
    if (!criteriaSeen.add(id.isNotEmpty ? id : text.toLowerCase())) continue;
    criteria.add((
      id: id,
      text: text,
      essential: m['essential'] == true,
      kind: _str(m['kind'], 40),
      source: _str(m['source'], 60),
      shown: m['shown'] is bool ? m['shown'] as bool : null,
    ));
  }

  var allItems = 0;
  final courses = <PlanCourse>[];
  final seen = <String>{};
  for (final c in _list(j['courses'], _maxCourses, 'courses')) {
    if (c is! Map) continue;
    final name = _str(c['title'], _maxTitle);
    if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
    final topics = <PlanTopic>[];
    for (final tp in _list(c['topics'], _maxTopics, 'topics in “$name”')) {
      final topic = tp is Map ? tp : {'title': tp};
      final tt = _str(topic['title'], _maxTitle);
      if (tt.isEmpty) continue;
      final items = _items(topic, tt);
      allItems += items.length;
      if (allItems > _maxAllItems) {
        throw const FormatException('Too many study items; the most is $_maxAllItems in one plan.');
      }
      topics.add(
        PlanTopic(
          tt,
          minutes: _int(topic['minutes'], 30, 5, 600),
          details: _str(topic['details'], _maxText),
          resources: [
            for (final r in topic['resources'] is List ? topic['resources'] as List : const [])
              if (_resource(r) case final s when s.isNotEmpty) s,
          ],
          items: items,
          criteria: [
            for (final c in _list(topic['criteria'], _maxCriteria, 'criteria in “$tt”'))
              if (_ref(c) case final id when id.isNotEmpty) id,
          ],
        ),
      );
    }
    final kind = _str(c['kind'], 20).toLowerCase();
    final start = c['startWeek'] is num ? _int(c['startWeek'], 0, 0, 520) : null;
    final due = c['dueWeek'] is num ? _int(c['dueWeek'], 0, 0, 520) : null;
    final minutes = topics.fold(0, (a, t) => a + t.minutes);
    courses.add(
      PlanCourse(
        name,
        kind: _kinds.contains(kind) ? kind : 'course',
        hours: _int(c['hours'], (minutes / 60).round(), 0, 5000),
        provider: _str(c['provider'], _maxTitle),
        url: _str(c['url'], 500),
        startWeek: start,
        dueWeek: due == null || start == null || due >= start ? due : start,
        summary: _str(c['summary'], _maxText),
        topics: topics,
      ),
    );
  }

  final skills = <PlanSkill>[
    for (final s in _list(j['skills'], _maxSkills, 'skills'))
      if ((s is Map ? _str(s['name'], _maxTitle) : _str(s, _maxTitle)) case final name when name.isNotEmpty)
        (
          name: name,
          category: s is Map && _str(s['category'], 60).isNotEmpty ? _str(s['category'], 60) : 'General',
          target: s is Map ? _int(s['target'], 3, 1, 5) : 3,
        ),
  ];

  final cards = <PlanCard>[];
  for (final c in _list(j['cards'], _maxCards, 'cards')) {
    if (c is! Map) continue;
    final front = _str(c['front'], _maxText), back = _str(c['back'], _maxText);
    if (front.isEmpty || (back.isEmpty && !isCloze(front))) continue;
    final course = _str(c['course'], _maxTitle);
    final deck = _str(c['deck'], _maxTitle);
    cards.add((
      id: _str(c['id'], 200),
      deck: deck.isNotEmpty ? deck : (course.isNotEmpty ? course : title),
      course: course,
      front: front,
      back: back,
    ));
  }

  final notes = <PlanNote>[
    for (final n in _list(j['notes'], _maxNotes, 'notes'))
      if (n is Map && _str(n['title'], _maxTitle).isNotEmpty)
        (
          title: _str(n['title'], _maxTitle),
          body: _str(n['body'], _maxBody),
          tags: n['tags'] is List
              ? [for (final x in n['tags'] as List) _str(x, 40).replaceAll(',', ' ')]
                    .where((x) => x.isNotEmpty)
                    .join(', ')
              : _str(n['tags'], 200),
        ),
  ];

  final journey = j['journey'] == null ? null : parseJourney(j['journey']);

  if (courses.isEmpty && cards.isEmpty && notes.isEmpty && journey == null) {
    throw const FormatException('The plan has no courses, cards or notes.');
  }
  return CurriculumPlan(
    title: title,
    goal: _str(program['goal'], _maxText),
    targetDate: isValidIsoDate(target) ? target : null,
    part: _str(j['part'], 40),
    courses: courses,
    skills: skills,
    cards: cards,
    notes: notes,
    role: _str(j['role'] ?? program['role'], _maxTitle),
    criteria: criteria,
    journey: journey,
  );
}

/// An id from a plan, safe to keep in a comma-separated list.
String _ref(Object? v) => _str(v, 60).replaceAll(',', ' ');

/// A topic's `items`, `quiz` and `drills` as items, in that order, each
/// once by its stable ref.
List<PlanItem> _items(Map topic, String topicTitle) {
  final out = <PlanItem>[];
  final refs = <String>{};
  void add(PlanItem i) {
    if (refs.add(i.ref)) out.add(i);
  }

  for (final x in _list(topic['items'], _maxItems, 'items in “$topicTitle”')) {
    if (x is! Map) continue;
    final url = _str(x['url'], 500);
    final title = _str(x['title'], _maxTitle).isNotEmpty ? _str(x['title'], _maxTitle) : url;
    if (title.isEmpty) continue;
    var type = itemTypeOf(_str(x['type'], 40));
    if (type.isEmpty) type = url.isEmpty ? 'note' : linkTypeOf(url);
    final extra = {
      for (final k in ['instructions', 'doneWhen'])
        if (_str(x[k], _maxText) case final v when v.isNotEmpty) k: v,
    };
    final id = _str(x['id'], 200);
    add(
      PlanItem(
        type: type,
        title: title,
        ref: id.isNotEmpty ? id : itemRef(type: type, title: title, url: url),
        url: url,
        source: _str(x['source'], 100),
        licence: _str(x['licence'] ?? x['license'], 100),
        minutes: _int(x['minutes'], 0, 0, 6000),
        required: x['required'] == true,
        content: extra.isEmpty ? '' : jsonEncode(extra),
      ),
    );
  }

  final questions = parseQuizQuestions(topic['quiz'], 'quiz questions in “$topicTitle”');
  if (questions.isNotEmpty) {
    add(
      PlanItem(
        type: 'quiz',
        title: 'Quiz: $topicTitle',
        ref: 'quiz',
        minutes: (questions.length * 1.5).ceil(),
        content: jsonEncode({'questions': questions}),
      ),
    );
  }

  for (final d in _list(topic['drills'], _maxDrills, 'drills in “$topicTitle”')) {
    final m = d is Map ? d : {'question': d};
    final question = _str(m['question'] ?? m['title'], _maxText);
    if (question.isEmpty) continue;
    final extra = {
      'question': question,
      for (final k in ['criterion', 'rubric', 'story'])
        if (_str(m[k], _maxText) case final v when v.isNotEmpty) k: v,
    };
    final id = _str(m['id'], 200);
    add(
      PlanItem(
        type: 'interview drill',
        title: question.length > _maxTitle ? '${question.substring(0, _maxTitle - 1)}…' : question,
        ref: id.isNotEmpty ? id : itemRef(type: 'interview drill', title: question),
        source: _str(m['source'], 100),
        content: jsonEncode(extra),
      ),
    );
  }
  return out;
}

/// Quiz questions from a plan, checked as a topic's quiz is: a question
/// and an answer each, a choice with two or more options (an index answer
/// becomes the option), at most [_maxQuiz]. Also used by journey checks.
List<Map<String, Object>> parseQuizQuestions(Object? list, String what) {
  final questions = <Map<String, Object>>[];
  for (final q in _list(list, _maxQuiz, what)) {
    if (q is! Map) continue;
    final question = _str(q['question'] ?? q['q'] ?? q['front'], _maxText);
    final options = [
      for (final o
          in q['options'] is List
              ? q['options'] as List
              : (q['choices'] is List ? q['choices'] as List : const []))
        if (_str(o, _maxTitle) case final s when s.isNotEmpty) s,
    ].take(8).toList();
    final rawAnswer = q['answer'] ?? q['a'] ?? q['back'];
    // A choice answer may be the option's index.
    final answer = rawAnswer is int && rawAnswer >= 0 && rawAnswer < options.length
        ? options[rawAnswer]
        : _str(rawAnswer, _maxText);
    if (question.isEmpty || answer.isEmpty) continue;
    var kind = _str(q['kind'] ?? q['type'], 20).toLowerCase();
    if (!{'choice', 'short', 'card'}.contains(kind)) kind = options.length > 1 ? 'choice' : 'short';
    if (kind == 'choice' && options.length < 2) kind = 'short';
    questions.add({
      'question': question,
      'kind': kind,
      if (kind == 'choice') 'options': options,
      'answer': answer,
      if (_str(q['explain'], _maxText) case final e when e.isNotEmpty) 'explain': e,
    });
  }
  return questions;
}

/// A plan topic's details and resources as the Markdown of its own note,
/// the same text the course's study guide holds under its heading.
String topicGuideMarkdown(PlanTopic t) {
  final parts = [
    if (t.details.isNotEmpty) t.details,
    if (t.resources.isNotEmpty) [for (final r in t.resources) '- $r'].join('\n'),
  ];
  return parts.join('\n\n');
}

String _str(Object? v, int max) {
  if (v is! String && v is! num) return '';
  final s = '$v'.trim();
  return s.length > max ? s.substring(0, max) : s;
}

int _int(Object? v, int fallback, int min, int max) =>
    (v is num ? v.round() : int.tryParse('${v ?? ''}') ?? fallback).clamp(min, max);

List<Object?> _list(Object? v, int max, String what) {
  if (v is! List) return const [];
  if (v.length > max) throw FormatException('Too many $what (${v.length}); the most is $max.');
  return v;
}

/// "Title — https://…", a title or an address on its own.
String _resource(Object? r) {
  if (r is Map) {
    final t = _str(r['title'], _maxTitle), u = _str(r['url'], 500);
    return [t, u].where((x) => x.isNotEmpty).join(' — ');
  }
  return _str(r, 600);
}

/// A course's topic details and resources as a Markdown note, so nothing
/// the plan carries is lost (topics themselves hold only a title and time).
String courseGuideMarkdown(PlanCourse c, {String? due}) {
  final out = StringBuffer('# ${c.title}\n');
  final facts = [
    if (c.startWeek != null && c.dueWeek != null) 'Weeks ${c.startWeek}–${c.dueWeek}',
    if (due != null) 'due ${niceDate(due)}',
    if (c.hours > 0) 'about ${c.hours} h',
  ];
  if (facts.isNotEmpty) out.write('\n${facts.join(' · ')}\n');
  if (c.summary.isNotEmpty) out.write('\n${c.summary}\n');
  for (final (i, t) in c.topics.indexed) {
    out.write('\n## ${i + 1}. ${t.title} (${t.minutes} min)\n');
    if (t.details.isNotEmpty) out.write('\n${t.details}\n');
    if (t.resources.isNotEmpty) {
      out.write('\n');
      for (final r in t.resources) {
        out.write('- $r\n');
      }
    }
  }
  return out.toString();
}

/// What the learner copies into an AI chat. The reply is a plan Vidya can
/// import. Brackets are for the learner to fill in.
const curriculumPrompt = '''
You are an expert teacher and exam coach. Build me a complete study plan that I will import into Vidya, a learning app. Reply with ONE JSON object only — no other text before or after it.

ABOUT ME (I have filled these in):
- Goal, exam or qualification: [for example: Pass NYC Transit exam 7612, Car Inspector]
- Official syllabus, exam notice, book contents or other source material: [paste it here, or write "use what you know"]
- Where I am now: [beginner / some experience / experienced, and in what]
- Time I can study each week: [hours]
- Deadline or exam date: [yyyy-mm-dd, or "none"]
- Anything else: [preferred resources, weak areas, language]

WHAT TO MAKE:
1. A roadmap. Split the goal into courses (modules) in the order I should study them. Give each a startWeek and dueWeek, counted in whole weeks from today (week 0), so the whole plan fits my weekly hours before the deadline and leaves the last weeks for revision and practice tests.
2. Topics. For every course, list the topics to cover in order. Each topic has minutes of study, details (the key facts, formulas, procedures and common mistakes, 2–6 sentences), and items: what to study or do, in order. Items are real, well-known resources (preferably free; if you are not sure of a web address, leave out the url — never invent links) and at least one practice task. Mark "required": true on the items that must be done before the topic counts as learned. Give 3–10 quiz questions per topic, and interview drills where the goal is a job.
3. Skills the plan builds, each with a category and a target level from 1 (aware) to 5 (expert).
4. Flashcards: 10–30 per course, testing the facts and principles in its topics. Write them in your own words; never copy questions from copyrighted books or past papers. Cloze cards are allowed: put {{c1::hidden words}} in the front and leave back empty.
5. Notes: one titled "Roadmap" with a week-by-week plan in Markdown; for an exam, one titled "Exam day" (format, timing, pass mark, what to bring, rules); add any others that help.

FORMAT (follow it exactly; leave out any optional field you have nothing for):
{
  "format": "vidya-curriculum",
  "version": 3,
  "part": "1 of 1",
  "program": {
    "title": "Short name of the goal",
    "goal": "One or two sentences: what I will be able to do",
    "targetDate": "yyyy-mm-dd"
  },
  "criteria": [{ "id": "c1", "text": "Something the goal or job asks for", "essential": true }],
  "journey": {
    "role": "Job title (only when the goal is one job)",
    "employer": "Employer's name",
    "sector": "nhs",
    "advertUrl": "https://…",
    "closes": "yyyy-mm-dd",
    "stages": [
      {
        "id": "research",
        "teach": [{ "text": "A fact about this job or employer", "source": { "url": "https://…", "title": "Where it is from", "date": "yyyy-mm-dd" } }],
        "produce": [{ "title": "Three reasons for choosing this employer", "kind": "list" }]
      }
    ]
  },
  "courses": [
    {
      "title": "Unique course title",
      "kind": "course",
      "hours": 12,
      "provider": "Optional: book, publisher or website",
      "url": "Optional: https://…",
      "startWeek": 0,
      "dueWeek": 2,
      "summary": "Why this course matters and what it covers",
      "topics": [
        {
          "title": "Topic title",
          "minutes": 45,
          "details": "Key points to learn",
          "criteria": ["c1"],
          "items": [
            { "type": "video", "title": "Resource name", "url": "https://…", "source": "Site, channel or publisher", "licence": "Optional, e.g. CC BY", "minutes": 20, "required": true },
            { "type": "practice task", "title": "What to do", "instructions": "How to do it", "doneWhen": "What finished looks like", "minutes": 30, "required": true }
          ],
          "quiz": [
            { "question": "A question", "kind": "choice", "options": ["One", "Two", "Three"], "answer": "Two" },
            { "question": "A question", "kind": "short", "answer": "The answer" }
          ],
          "drills": [{ "question": "An interview question on this topic", "criterion": "c1" }]
        }
      ]
    }
  ],
  "skills": [{ "name": "Skill", "category": "Area", "target": 4 }],
  "cards": [{ "course": "Unique course title", "front": "Question", "back": "Answer" }],
  "notes": [{ "title": "Roadmap", "body": "Markdown text", "tags": ["plan"] }]
}

RULES:
- "kind" is one of: course, book, certification, degree, project, practice.
- An item's "type" is one of: course, video, article, book, practice task, quiz, interview drill, note. Give links and titles only; never copy a course's text.
- A quiz question's "kind" is choice (with "options", and "answer" equal to one of them), short or card. Add a one-sentence "explain" where it helps.
- "criteria" lists what the goal asks for (for a job: the essential and desirable criteria); each topic's "criteria" names the ids it works towards. Leave both out if there are none.
- "journey" is only for a goal that is one job; leave it out otherwise. "sector" is one of: nhs, university, private, civil-service, other. A stage "id" is one of: decide, research, contact, apply, follow-up, prepare, interview-day, after, offer, checks, joining, first-90-days, grow. Vidya fills in every stage you leave out from its own dated guides, so add only what is special to this job. A line with no "source" is shown as general advice; never invent a source or a date.
- Plain JSON: double quotes, no comments, no trailing commas, \\n for line breaks inside text.
- Every card's "course" must match a course title exactly.
- Be accurate. Leave out anything you are not sure of rather than guess.
- If everything will not fit in one reply, split it into parts. Set "part" to "1 of N", "2 of N" and so on. Every part repeats the same "program" block; part 1 also carries the skills and notes; each part holds whole courses with their own cards. I will say "next part" to get the next one.
''';

/// What the learner tells the AI about themselves, in the order of the
/// prompt's ABOUT ME lines.
typedef PlanRequest = ({
  String goal,
  String source,
  String level,
  String hours,
  String deadline,
  String other,
});

/// [curriculumPrompt] with the learner's answers in place of the brackets.
/// Blank answers become "not given" (the deadline: "none").
String filledCurriculumPrompt(PlanRequest r) {
  final answers = [r.goal, r.source, r.level, r.hours, r.deadline, r.other];
  var i = 0;
  return curriculumPrompt.replaceAllMapped(RegExp(r'^(- [^:\n]+: )\[[^\]\n]*\]$', multiLine: true), (m) {
    final k = i++;
    final a = k < answers.length ? answers[k].trim() : '';
    return '${m[1]}${a.isNotEmpty ? a : (k == 4 ? 'none' : 'not given')}';
  });
}
