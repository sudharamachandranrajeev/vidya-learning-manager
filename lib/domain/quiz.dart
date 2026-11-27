/// Topic quizzes: the questions a quiz item holds, how an answer is marked,
/// how a plan's questions and the learner's own live together, and the
/// questions an AI writes. Plain rules; nothing here writes.
library;

import 'dart:convert';

import '../db/database.dart';
import 'answer.dart';
import 'study_items.dart';

/// The question kinds: pick one option, type a short answer, or recall it
/// in your head and mark yourself (card).
const questionKinds = {'choice': 'Pick one', 'short': 'Short answer', 'card': 'Card (mark yourself)'};

/// One quiz question, as kept in a quiz item's `content.questions`.
class QuizQuestion {
  const QuizQuestion({
    required this.question,
    required this.answer,
    this.kind = 'short',
    this.options = const [],
    this.explain = '',
    this.own = false,
    this.ai = false,
    this.replaces = '',
    this.topic = '',
  });

  final String question, kind, answer, explain;

  /// The topic this question tests, for an exam's per-topic breakdown: a
  /// topic title in the same course, or '' for the quiz's own topic.
  final String topic;
  final List<String> options;

  /// Written or changed by the learner. Own questions stay when the plan
  /// comes again; the plan's own questions are replaced by the new ones.
  final bool own;

  /// Written by an AI. Shown with an "AI" label, and editable like any.
  final bool ai;

  /// The plan question this one is the learner's edit of, so the plan's
  /// version does not come back beside it.
  final String replaces;

  /// The question text in a form that ignores case and spacing.
  String get key => normalKey(question);

  static String normalKey(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  factory QuizQuestion.fromJson(Map j) {
    String s(String k) => j[k] is String ? (j[k] as String).trim() : '';
    final options = [
      for (final o in j['options'] is List ? j['options'] as List : const [])
        if (o is String && o.trim().isNotEmpty) o.trim(),
    ];
    var kind = s('kind');
    if (!questionKinds.containsKey(kind)) kind = options.length > 1 ? 'choice' : 'short';
    if (kind == 'choice' && options.length < 2) kind = 'short';
    return QuizQuestion(
      question: s('question'),
      answer: s('answer'),
      kind: kind,
      options: kind == 'choice' ? options : const [],
      explain: s('explain'),
      own: j['own'] == true,
      ai: j['ai'] == true,
      replaces: s('replaces'),
      topic: s('topic'),
    );
  }

  Map<String, Object> toJson() => {
    'question': question,
    'kind': kind,
    if (kind == 'choice') 'options': options,
    'answer': answer,
    if (explain.isNotEmpty) 'explain': explain,
    if (own) 'own': true,
    if (ai) 'ai': true,
    if (replaces.isNotEmpty) 'replaces': replaces,
    if (topic.isNotEmpty) 'topic': topic,
  };

  QuizQuestion copyWith({bool? own, String? replaces}) => QuizQuestion(
    question: question,
    answer: answer,
    kind: kind,
    options: options,
    explain: explain,
    own: own ?? this.own,
    ai: ai,
    replaces: replaces ?? this.replaces,
    topic: topic,
  );
}

/// What is wrong with a question typed by hand, or null when it is fine.
String? questionProblem(QuizQuestion q) {
  if (q.question.isEmpty) return 'Write the question.';
  if (q.answer.isEmpty) return 'Write the answer.';
  if (q.kind == 'choice') {
    if (q.options.length < 2) return 'Give at least two options, one per line.';
    if (!q.options.contains(q.answer)) return 'The answer must be one of the options, written the same way.';
  }
  return null;
}

/// The questions a quiz item holds, in order.
List<QuizQuestion> quizQuestions(StudyItem i) => _questions(itemContent(i));

/// Plan questions the learner deleted (by [QuizQuestion.key]), so a plan
/// sent again does not bring them back.
List<String> quizDropped(StudyItem i) => _dropped(itemContent(i));

List<QuizQuestion> _questions(Map<String, Object?> c) => [
  for (final q in c['questions'] is List ? c['questions'] as List : const [])
    if (q is Map)
      if (QuizQuestion.fromJson(q) case final x when x.question.isNotEmpty && x.answer.isNotEmpty) x,
];

List<String> _dropped(Map<String, Object?> c) => [
  for (final d in c['dropped'] is List ? c['dropped'] as List : const [])
    if (d is String && d.isNotEmpty) d,
];

/// A quiz item's content JSON for [questions], the plan questions the
/// learner [dropped] and the plan's [exam] rules (see exam.dart), if any.
String quizContent(
  List<QuizQuestion> questions, {
  List<String> dropped = const [],
  Map<String, Object?>? exam,
}) => jsonEncode({
  'questions': [for (final q in questions) q.toJson()],
  if (dropped.isNotEmpty) 'dropped': dropped,
  'exam': ?exam,
});

/// The exam rules a quiz content JSON carries, as stored, or null.
Map<String, Object?>? quizExamJson(String content) {
  if (content.isEmpty) return null;
  try {
    final j = jsonDecode(content);
    return j is Map && j['exam'] is Map ? Map<String, Object?>.from(j['exam'] as Map) : null;
  } on FormatException {
    return null;
  }
}

/// A plan's quiz content laid over what the item holds now: the plan's
/// questions (less those the learner deleted or rewrote), then the
/// learner's own and AI questions as they are. The exam rules are the
/// plan's: a plan sent again without them makes it a practice quiz again.
String mergeQuizContent(String planContent, String knownContent) {
  Map<String, Object?> read(String s) {
    if (s.isEmpty) return const {};
    try {
      final j = jsonDecode(s);
      return j is Map<String, Object?> ? j : const {};
    } on FormatException {
      return const {};
    }
  }

  final known = read(knownContent);
  final kept = [
    for (final q in _questions(known))
      if (q.own || q.ai) q,
  ];
  final dropped = _dropped(known);
  final hidden = {
    ...dropped,
    for (final q in kept) q.key,
    for (final q in kept) QuizQuestion.normalKey(q.replaces),
  };
  final plan = [
    for (final q in _questions(read(planContent)))
      if (!hidden.contains(q.key)) q,
  ];
  return quizContent([...plan, ...kept], dropped: dropped, exam: quizExamJson(planContent));
}

/// The stable ref of the review card a missed question becomes. The same
/// question on the same quiz always has the same ref, so a retake never
/// adds a second card.
String quizCardRef(String itemId, QuizQuestion q) => 'quiz.$itemId.${stableHash(q.key)}';

/// Whether a typed or picked answer can be marked right without asking:
/// a picked option must be the answer; a typed one matches it leniently
/// (case, spacing, punctuation and a leading "the" do not matter). Anything
/// else is shown beside the answer for the learner to mark.
bool autoCorrect(QuizQuestion q, String given) =>
    q.kind == 'choice' ? given == q.answer : answerMatches(given, q.answer);

/// A score as a whole percent.
int percentOf(num score, num max) => max <= 0 ? 0 : (score * 100 / max).round();

/// The `kind` of an assessment detail that is a timed exam attempt.
const examKind = 'exam';

/// Whether an assessment's detail is an exam attempt's (see exam.dart).
bool isExamDetail(String detail) {
  if (detail.isEmpty) return false;
  try {
    final j = jsonDecode(detail);
    return j is Map && j['kind'] == examKind;
  } on FormatException {
    return false;
  }
}

/// Whether a result is a quiz's: a practice quiz (no detail) or an exam
/// attempt. Interview drill attempts are not.
bool isQuizResult(Assessment a) => a.detail.isEmpty || isExamDetail(a.detail);

/// The latest quiz result for each topic, as a percent, from the recorded
/// tests (the newest day wins; on one day, the last written). Practice
/// quizzes and exam attempts both count; interview drill attempts are left
/// out.
Map<String, int> lastQuizPercents(Iterable<Assessment> tests) {
  final latest = <String, Assessment>{};
  for (final a in tests) {
    final t = a.topicId;
    if (t == null || a.deleted || !isQuizResult(a)) continue;
    final had = latest[t];
    if (had == null || a.day.compareTo(had.day) > 0 || (a.day == had.day && a.hlc.compareTo(had.hlc) > 0)) {
      latest[t] = a;
    }
  }
  return {for (final e in latest.entries) e.key: percentOf(e.value.score, e.value.max)};
}

/// What an AI is asked for when it writes questions for a topic. Only the
/// topic's and course's titles, the plan's text for it and its item titles
/// are sent; never the learner's notes or answers.
String aiQuizPrompt({
  required String topic,
  required String course,
  String details = '',
  List<String> items = const [],
  List<String> existing = const [],
}) {
  final out = StringBuffer(
    'Write 5 quiz questions that check someone has understood the topic "$topic"'
    '${course.isEmpty ? '' : ' in the course "$course"'}. Mix the kinds: "choice" (3 or 4 options, '
    'the answer equal to one of them), "short" (a short typed answer) and "card" (a question to '
    'answer in your head). Add a one-sentence "explain" to each. Test understanding, not trivia. '
    'Write them in your own words; never copy questions from books or past papers. If you are not '
    'sure of a fact, leave that question out.\n',
  );
  if (details.trim().isNotEmpty) out.write('\nWhat the topic covers:\n${details.trim()}\n');
  if (items.isNotEmpty) out.write('\nStudy items: ${items.join('; ')}\n');
  if (existing.isNotEmpty) out.write('\nDo not repeat these questions: ${existing.join(' | ')}\n');
  out.write(
    '\nReply with JSON only, no other text: '
    '{"quiz": [{"question": "…", "kind": "choice", "options": ["…", "…", "…"], "answer": "…", '
    '"explain": "…"}]}',
  );
  return out.toString();
}

/// The questions in an AI's reply (a `{"quiz": [...]}` object, a bare list,
/// or either inside other text), each marked [QuizQuestion.ai]. At most 10;
/// ones without a question or an answer, or a choice whose answer is not an
/// option, are left out. Throws [FormatException] when there is no JSON.
List<QuizQuestion> parseAiQuestions(String reply) {
  final start = reply.indexOf(RegExp(r'[\[{]'));
  final end = reply.lastIndexOf(RegExp(r'[\]}]'));
  if (start < 0 || end <= start) throw const FormatException('The reply holds no questions.');
  final Object? j;
  try {
    j = jsonDecode(reply.substring(start, end + 1));
  } on FormatException {
    throw const FormatException('The reply could not be read as questions.');
  }
  final list = switch (j) {
    final List l => l,
    final Map m when m['quiz'] is List => m['quiz'] as List,
    final Map m when m['questions'] is List => m['questions'] as List,
    _ => const [],
  };
  final out = <QuizQuestion>[];
  for (final x in list) {
    if (x is! Map) continue;
    final q = QuizQuestion.fromJson({...x, 'own': false, 'ai': true});
    if (questionProblem(q) == null) out.add(q);
    if (out.length == 10) break;
  }
  if (out.isEmpty) throw const FormatException('The reply holds no usable questions.');
  return out;
}
