import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/quiz.dart';
import '../domain/study_items.dart';
import 'common.dart';
import 'zen.dart';

Future<void> openQuiz(BuildContext context, StudyItem quiz) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuizPage(quiz)));

/// Takes a topic's quiz, one question at a time. A choice is marked as soon
/// as an option is tapped; a typed answer that matches is marked right, and
/// any other is shown beside the answer for the learner to mark; a card is
/// recalled, revealed and self-marked. Each shows its explanation. At the
/// end the score is saved and missed questions become review cards.
class QuizPage extends ConsumerStatefulWidget {
  const QuizPage(this.quiz, {super.key, this.onFinish});
  final StudyItem quiz;

  /// Saves the result in place of the topic quiz's own record (a journey
  /// stage's check keeps its result on the journey).
  final Future<({int score, int max, int cards})> Function(List<bool> right)? onFinish;

  @override
  ConsumerState<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends ConsumerState<QuizPage> {
  late final List<QuizQuestion> _questions = quizQuestions(widget.quiz);
  final _typed = TextEditingController();
  final _right = <bool>[];

  /// What was picked or typed for the question on screen; null until then.
  String? _given;

  /// Whether the answer is showing (a card revealed, a typed answer checked).
  bool _shown = false;

  /// Whether the answer on screen was marked right; null while the learner
  /// still has to mark it.
  bool? _correct;
  ({int score, int max, int cards})? _result;
  var _saving = false;

  int get _index => _right.length;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _pick(String option) {
    if (_shown) return;
    setState(() {
      _given = option;
      _shown = true;
      _correct = autoCorrect(_questions[_index], option);
    });
  }

  void _check() {
    final typed = _typed.text.trim();
    if (typed.isEmpty) return;
    setState(() {
      _given = typed;
      _shown = true;
      // A match is marked right; anything else waits for the learner.
      _correct = autoCorrect(_questions[_index], typed) ? true : null;
    });
  }

  Future<void> _next(bool right) async {
    _right.add(right);
    _typed.clear();
    setState(() {
      _given = null;
      _shown = false;
      _correct = null;
    });
    if (_index < _questions.length) return;
    setState(() => _saving = true);
    final onFinish = widget.onFinish;
    final r = onFinish != null
        ? await onFinish(List.of(_right))
        : await ref.mutate((s) => s.book.recordQuiz(widget.quiz, List.of(_right), today: today()));
    if (mounted) {
      setState(() {
        _result = r;
        _saving = false;
      });
    }
  }

  void _again() => setState(() {
    _right.clear();
    _result = null;
  });

  @override
  Widget build(BuildContext context) => Backdrop(
    child: Scaffold(
      appBar: AppBar(title: Text(widget.quiz.title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _questions.isEmpty
                  ? const Text('This quiz has no questions yet. Add some on the topic page.')
                  : _result != null
                  ? _Result(_result!, onAgain: _again, journey: widget.onFinish != null)
                  : _saving
                  ? const Center(child: CircularProgressIndicator())
                  : _question(context),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _question(BuildContext context) {
    final q = _questions[_index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Question ${_index + 1} of ${_questions.length}', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: _index / _questions.length),
        const SizedBox(height: 16),
        Text(q.question, style: theme.textTheme.titleLarge),
        if (q.ai)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Written by AI', style: theme.textTheme.labelMedium?.copyWith(color: muted(context))),
          ),
        const SizedBox(height: 16),
        ...switch (q.kind) {
          'choice' => [
            for (final o in q.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    side: !_shown
                        ? null
                        : o == q.answer
                        ? BorderSide(color: scheme.primary, width: 2)
                        : o == _given
                        ? BorderSide(color: scheme.error, width: 2)
                        : null,
                  ),
                  onPressed: _shown ? null : () => _pick(o),
                  child: Row(
                    children: [
                      Expanded(child: Text(o)),
                      if (_shown && o == q.answer) Icon(Icons.check, color: scheme.primary),
                      if (_shown && o == _given && o != q.answer) Icon(Icons.close, color: scheme.error),
                    ],
                  ),
                ),
              ),
          ],
          'short' => [
            TextField(
              controller: _typed,
              enabled: !_shown,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Your answer'),
              onSubmitted: (_) => _check(),
            ),
            const SizedBox(height: 8),
            if (!_shown) FilledButton(onPressed: _check, child: const Text('Check')),
          ],
          _ => [
            if (!_shown)
              FilledButton(onPressed: () => setState(() => _shown = true), child: const Text('Show answer')),
          ],
        },
        if (_shown) ...[
          const SizedBox(height: 12),
          _Feedback(q, correct: _correct, typed: q.kind == 'short' ? _given : null),
          const SizedBox(height: 12),
          if (_correct != null)
            FilledButton(
              onPressed: () => _next(_correct!),
              child: Text(_index + 1 == _questions.length ? 'See my score' : 'Next'),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text(q.kind == 'card' ? 'I knew it' : 'I was right'),
                  onPressed: () => _next(true),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.close),
                  label: Text(q.kind == 'card' ? 'I did not' : 'I was wrong'),
                  onPressed: () => _next(false),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

/// The answer, the explanation and, once marked, whether it was right.
class _Feedback extends StatelessWidget {
  const _Feedback(this.q, {required this.correct, this.typed});
  final QuizQuestion q;
  final bool? correct;
  final String? typed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(switch (correct) {
              true => 'Right.',
              false => 'Not quite.',
              null => q.kind == 'card' ? 'Did you know it?' : 'Compare your answer with this one.',
            }, style: t.titleMedium),
            const SizedBox(height: 6),
            if (typed != null && correct == null) Text('You wrote: $typed'),
            Text('Answer: ${q.answer}'),
            if (q.explain.isNotEmpty) ...[const SizedBox(height: 6), Text(q.explain, style: t.bodyMedium)],
          ],
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result(this.r, {required this.onAgain, this.journey = false});
  final ({int score, int max, int cards}) r;
  final VoidCallback onAgain;

  /// A journey stage's check, which makes no review cards.
  final bool journey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pct = percentOf(r.score, r.max);
    final missed = r.max - r.score;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${r.score} of ${r.max} right ($pct%)', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          journey
              ? (pct >= passPercent
                    ? 'That is $passPercent% or more: the stage\'s check is done.'
                    : 'Under $passPercent%. Read the stage again and try once more.')
              : pct >= passPercent
              ? 'That is $passPercent% or more, enough for this topic.'
              : 'Under $passPercent%. Come back to it after another look at the topic.',
        ),
        if (missed > 0 && !journey) ...[
          const SizedBox(height: 8),
          Text(
            r.cards > 0
                ? '${r.cards} missed ${r.cards == 1 ? 'question is' : 'questions are'} now review cards, '
                      'so they come back on a schedule.'
                : 'The missed questions are already review cards.',
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(journey ? 'Back to the journey' : 'Back to the topic'),
            ),
            OutlinedButton(onPressed: onAgain, child: const Text('Try again')),
          ],
        ),
      ],
    );
  }
}

/// Opens the list of a topic's quiz questions to add, edit and delete.
Future<void> openQuizEditor(BuildContext context, String topicId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuizEditorPage(topicId)));

/// The topic's quiz item (null until it has one), re-read after each write.
final _quizOfProvider =
    FutureProvider.family<({Topic topic, Course? course, StudyItem? quiz, List<StudyItem> items}), String>((
      ref,
      topicId,
    ) async {
      ref.watch(revisionProvider);
      final db = ref.watch(sessionProvider).db;
      final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(topicId))).getSingle();
      final course = await (db.select(
        db.learnCourses,
      )..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
      final items = activeItems(
        await (db.select(db.learnItems)..where((i) => i.topicId.equals(topicId) & i.deleted.not())).get(),
      );
      return (
        topic: topic,
        course: course,
        quiz: items.where((i) => i.type == 'quiz').firstOrNull,
        items: items,
      );
    });

/// A topic's quiz questions: the plan's, the learner's own and any an AI
/// wrote (labelled). All can be edited; an edited plan question is kept as
/// the learner's, and a deleted one does not come back with the plan.
class QuizEditorPage extends ConsumerWidget {
  const QuizEditorPage(this.topicId, {super.key});
  final String topicId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(_quizOfProvider(topicId)),
      builder: (v) {
        final quiz = v.quiz;
        final questions = quiz == null ? <QuizQuestion>[] : quizQuestions(quiz);
        final dropped = quiz == null ? <String>[] : quizDropped(quiz);
        Future<void> write(List<QuizQuestion> next, {List<String>? drop}) =>
            ref.mutate((s) => s.book.saveQuizQuestions(topicId, next, dropped: drop ?? dropped));
        return Scaffold(
          appBar: AppBar(title: Text('Questions: ${v.topic.title}')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () async {
              final q = await questionDialog(context);
              if (q != null) await write([...questions, q]);
            },
            icon: const Icon(Icons.add),
            label: const Text('Question'),
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 96 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '3 to 10 questions work best. Missed questions become review cards. '
                        'Questions from the plan stay in step with it; ones you add or change are kept.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: muted(context)),
                      ),
                      const SizedBox(height: 8),
                      _AiQuestions(
                        v.topic,
                        v.course,
                        v.items,
                        questions,
                        onAdd: (more) => write([...questions, ...more]),
                      ),
                      const SizedBox(height: 8),
                      if (questions.isEmpty) const Text('No questions yet.'),
                      for (final (k, q) in questions.indexed)
                        Card(
                          child: ListTile(
                            title: Text(q.question),
                            subtitle: Text(
                              [
                                questionKinds[q.kind] ?? q.kind,
                                'answer: ${q.answer}',
                                q.ai ? 'AI' : (q.own ? 'yours' : 'from the plan'),
                              ].join(' · '),
                            ),
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Question actions',
                              onSelected: (a) async {
                                if (a == 'edit') {
                                  final e = await questionDialog(context, q: q);
                                  if (e == null) return;
                                  final kept = e.copyWith(
                                    own: true,
                                    replaces: q.own || q.ai ? q.replaces : q.question,
                                  );
                                  await write(
                                    [...questions]
                                      ..[k] = QuizQuestion.fromJson({...kept.toJson(), 'ai': q.ai}),
                                  );
                                } else if (a == 'delete') {
                                  if (!await askSure(context, 'Delete question?', q.question) ||
                                      !context.mounted) {
                                    return;
                                  }
                                  final fromPlan = !q.own && !q.ai
                                      ? q.key
                                      : QuizQuestion.normalKey(q.replaces);
                                  await write(
                                    [...questions]..removeAt(k),
                                    drop: [
                                      ...dropped,
                                      if (fromPlan.isNotEmpty && !dropped.contains(fromPlan)) fromPlan,
                                    ],
                                  );
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'edit', child: Text('Edit')),
                                PopupMenuItem(value: 'delete', child: Text('Delete')),
                              ],
                            ),
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

/// Adds or edits one question. Returns it, or null when cancelled.
Future<QuizQuestion?> questionDialog(BuildContext context, {QuizQuestion? q}) async {
  final question = TextEditingController(text: q?.question ?? '');
  final answer = TextEditingController(text: q?.answer ?? '');
  final options = TextEditingController(text: q?.options.join('\n') ?? '');
  final explain = TextEditingController(text: q?.explain ?? '');
  var kind = q?.kind ?? 'short';
  QuizQuestion? out;
  QuizQuestion read() => QuizQuestion(
    question: question.text.trim(),
    answer: answer.text.trim(),
    kind: kind,
    options: kind == 'choice'
        ? [
            for (final o in options.text.split('\n'))
              if (o.trim().isNotEmpty) o.trim(),
          ]
        : const [],
    explain: explain.text.trim(),
    own: true,
  );
  await showFormDialog(
    context,
    title: q == null ? 'Add question' : 'Edit question',
    fields: (setState) => [
      Choice(label: 'Kind', value: kind, options: questionKinds, onChanged: (v) => setState(() => kind = v)),
      Field(question, 'Question', autofocus: q == null, lines: 2),
      if (kind == 'choice') Field(options, 'Options, one per line', lines: 4),
      Field(answer, kind == 'choice' ? 'Right option (as written above)' : 'Answer'),
      Field(explain, 'Why (optional)', lines: 2),
    ],
    onSave: () async {
      final x = read();
      final problem = questionProblem(x);
      if (problem != null) return problem;
      out = x;
      return null;
    },
  );
  return out;
}

/// "Write questions with AI": only through an AI the learner connected in
/// Ask AI (a chat website cannot answer here). The questions come back
/// labelled AI and editable.
class _AiQuestions extends ConsumerStatefulWidget {
  const _AiQuestions(this.topic, this.course, this.items, this.existing, {required this.onAdd});
  final Topic topic;
  final Course? course;
  final List<StudyItem> items;
  final List<QuizQuestion> existing;
  final Future<void> Function(List<QuizQuestion>) onAdd;

  @override
  ConsumerState<_AiQuestions> createState() => _AiQuestionsState();
}

class _AiQuestionsState extends ConsumerState<_AiQuestions> {
  var _busy = false;

  Future<void> _write(HelpAiSetup setup) async {
    setState(() => _busy = true);
    try {
      final db = ref.read(sessionProvider).db;
      // The plan's text for the topic, not the learner's own note.
      final note = await (db.select(
        db.learnNotes,
      )..where((n) => n.id.equals(topicNoteId(widget.topic.id)))).getSingleOrNull();
      final details = note != null && hasPlanNoteTag(note) ? note.body : '';
      final asker = await ref.read(helpAskerProvider)(setup);
      final reply = await asker.ask(
        'You write short quiz questions for a learning app. Reply with JSON only.',
        [
          (
            user: true,
            text: aiQuizPrompt(
              topic: widget.topic.title,
              course: widget.course?.title ?? '',
              details: details,
              items: [
                for (final i in widget.items)
                  if (i.type != 'quiz') i.title,
              ],
              existing: [for (final q in widget.existing) q.question],
            ),
          ),
        ],
      );
      final known = {for (final q in widget.existing) q.key};
      final fresh = [
        for (final q in parseAiQuestions(reply))
          if (known.add(q.key)) q,
      ];
      await widget.onAdd(fresh);
      if (mounted) {
        notify(context, '${fresh.length} questions written by AI added. Check them before you rely on them.');
      }
    } catch (e) {
      if (mounted) notify(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(helpAiProvider).value ?? const HelpAiSetup();
    final connected = setup.via != HelpAi.chat;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              connected
                  ? 'Let ${setup.via.label} write a few questions. The topic and item titles are sent, '
                        'not your notes. They are labelled AI and you can edit them.'
                  : 'To have AI write questions here, connect an AI in Ask AI. A chat website cannot send '
                        'questions back.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (connected)
                  FilledButton.tonalIcon(
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined),
                    label: const Text('Write questions with AI'),
                    onPressed: _busy ? null : () => _write(setup),
                  ),
                TextButton(
                  onPressed: _busy ? null : () => showAskAiSetup(context),
                  child: Text(connected ? 'Change AI' : 'Connect an AI'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
