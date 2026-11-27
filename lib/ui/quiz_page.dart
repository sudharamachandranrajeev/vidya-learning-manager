import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column, View;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/exam.dart';
import '../domain/quiz.dart';
import '../domain/study_items.dart';
import 'charts.dart';
import 'common.dart';
import 'zen.dart';

/// Opens a topic's quiz: a timed exam when the plan made it one (unless
/// [practice] asks for a practice run, which is not counted), else the
/// practice quiz.
Future<void> openQuiz(BuildContext context, StudyItem quiz, {bool practice = false}) {
  final exam = examRules(quiz) != null;
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => exam && !practice ? ExamPage(quiz) : QuizPage(quiz, notCounted: exam)),
  );
}

/// Takes a topic's quiz, one question at a time. A choice is marked as soon
/// as an option is tapped; a typed answer that matches is marked right, and
/// any other is shown beside the answer for the learner to mark; a card is
/// recalled, revealed and self-marked. Each shows its explanation. At the
/// end the score is saved and missed questions become review cards.
class QuizPage extends ConsumerStatefulWidget {
  const QuizPage(this.quiz, {super.key, this.onFinish, this.notCounted = false});
  final StudyItem quiz;

  /// Practising a quiz that is an exam: missed questions still become
  /// review cards, but no result is saved, so it is never an attempt.
  final bool notCounted;

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
        : await ref.mutate(
            (s) =>
                s.book.recordQuiz(widget.quiz, List.of(_right), today: today(), counted: !widget.notCounted),
          );
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
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.notCounted)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _Banner(
                              Icons.info_outline,
                              'Practice, not counted: this is not an exam attempt and no score is saved.',
                            ),
                          ),
                        _result != null
                            ? _Result(
                                _result!,
                                onAgain: _again,
                                journey: widget.onFinish != null,
                                notCounted: widget.notCounted,
                                pass: quizPassPercent(widget.quiz),
                              )
                            : _saving
                            ? const Center(child: CircularProgressIndicator())
                            : _question(context),
                      ],
                    ),
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
  const _Result(
    this.r, {
    required this.onAgain,
    this.journey = false,
    this.notCounted = false,
    this.pass = passPercent,
  });
  final ({int score, int max, int cards}) r;
  final VoidCallback onAgain;

  /// A journey stage's check, which makes no review cards.
  final bool journey;

  /// Practice on an exam quiz: nothing was saved but review cards.
  final bool notCounted;

  /// The pass mark.
  final int pass;

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
              : notCounted
              ? 'Practice only: this score is not saved and is not an exam attempt.'
              : pct >= pass
              ? 'That is $pass% or more, enough for this topic.'
              : 'Under $pass%. Come back to it after another look at the topic.',
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

/// A short notice with an icon, for "not counted" and "seen before".
class _Banner extends StatelessWidget {
  const _Banner(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: muted(context))),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    ),
  );
}

/// The clock an exam reads; tests swap it for one they move by hand.
final examClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// A topic's exam attempts so far, oldest first.
final examAttemptsProvider = FutureProvider.family<List<Assessment>, String>((ref, topicId) async {
  ref.watch(revisionProvider);
  final db = ref.watch(sessionProvider).db;
  final tests = await (db.select(
    db.learnAssessments,
  )..where((a) => a.topicId.equals(topicId) & a.deleted.not())).get();
  return examAttempts(tests, topicId);
});

enum _ExamPhase { intro, running, marking, saving, done }

/// A topic quiz taken as a timed exam: the rules first, then every
/// question with a countdown that never pauses and no feedback, handed in
/// by the learner or by itself when time runs out. Typed answers that do
/// not match, and cards, are marked by the learner after the timer stops.
/// Then the report card: score, pass or fail, time, attempted, the topics
/// to study first and every answer with its explanation. Missed questions
/// become review cards as in a practice quiz.
class ExamPage extends ConsumerStatefulWidget {
  const ExamPage(this.quiz, {super.key});
  final StudyItem quiz;

  @override
  ConsumerState<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends ConsumerState<ExamPage> {
  late final ExamRules _rules = examRules(widget.quiz) ?? ExamRules(minutes: 1);
  late final List<QuizQuestion> _pool = quizQuestions(widget.quiz);
  var _phase = _ExamPhase.intro;

  /// The questions in the order asked, and per question what was given.
  var _shown = <QuizQuestion>[];
  var _given = <String>[];
  var _typed = <TextEditingController>[];

  /// Per question: marked right, wrong, or null while the learner marks it.
  var _marks = <bool?>[];

  /// The questions the learner marks after handing in (in asked order).
  var _toMark = <int>[];
  var _index = 0;

  DateTime? _start;
  Timer? _tick;
  var _seconds = 0;
  var _timedOut = false;
  late int _lastLeft = _limit;
  ExamResult? _result;
  var _cards = 0;

  /// How much of the attempt came up before, as it stood when it began.
  ({bool smallPool, int repeats, int asked})? _seenAtStart;
  String? _error;

  /// Whether a saved, unfinished attempt has been looked for yet.
  var _checked = false;
  Timer? _persistSoon;

  int get _limit => _rules.minutes * 60;
  DateTime _now() => _clock();

  // Read once, so the attempt can still be saved while the page closes.
  late final DateTime Function() _clock;
  late final AppDatabase _db;
  int get _elapsed => _start == null ? _seconds : _now().difference(_start!).inSeconds;
  int get _left => (_limit - _elapsed).clamp(0, _limit);

  @override
  void initState() {
    super.initState();
    _clock = ref.read(examClockProvider);
    _db = ref.read(sessionProvider).db;
    _restore();
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_persistSoon?.isActive ?? false) {
      _persistSoon!.cancel();
      _persist();
    }
    for (final c in _typed) {
      c.dispose();
    }
    super.dispose();
  }

  void _announce(String text) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), text, Directionality.of(context));
  }

  String get _progressKey => examProgressKey(widget.quiz.id);

  /// Picks up an attempt the app was closed or killed in: the time has
  /// kept running from its start, so it may be handed in at once.
  Future<void> _restore() async {
    final db = _db;
    final saved = ExamProgress.parse(await db.localSetting(_progressKey));
    final m = saved?.against(_pool);
    if (saved == null || m == null) {
      if (saved != null) await db.setLocalSetting(_progressKey, '');
      if (mounted) setState(() => _checked = true);
      return;
    }
    final attempts = await ref.read(examAttemptsProvider(widget.quiz.topicId).future);
    if (!mounted) return;
    _setUp([for (final k in m.order) _pool[k]], attempts, given: m.given);
    _index = saved.index.clamp(0, _shown.length - 1);
    _start = saved.start;
    _checked = true;
    if (saved.handedIn != null) {
      _start = null;
      _seconds = saved.handedIn!.clamp(0, _limit);
      _timedOut = saved.timedOut;
      _markAuto();
      return;
    }
    setState(() => _phase = _ExamPhase.running);
    if (_left <= 0) {
      _announce('Time ran out while you were away. Your exam has been handed in.');
      _handIn(timedOut: true);
      return;
    }
    _lastLeft = _left;
    _announce('Exam resumed. ${timeLeftText(_left)}.');
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _setUp(List<QuizQuestion> shown, List<Assessment> attempts, {List<String>? given}) {
    final earlier = [for (final a in attempts) ?ExamResult.of(a)];
    _shown = shown;
    _seenAtStart = seenBefore(
      pool: _pool.length,
      rules: _rules,
      asking: [for (final q in shown) questionId(q)],
      earlier: earlier,
    );
    _given = given != null ? List.of(given) : List.filled(shown.length, '');
    _typed = [
      for (final (k, q) in shown.indexed)
        TextEditingController(text: q.kind == 'choice' ? '' : _given[k])..addListener(_persistLater),
    ];
    _marks = List.filled(shown.length, null);
    _index = 0;
  }

  /// What is given so far, read from the fields.
  List<String> get _answers => [
    for (var k = 0; k < _shown.length; k++) _shown[k].kind == 'choice' ? _given[k] : _typed[k].text.trim(),
  ];

  /// Saves the unfinished attempt on this device (see [ExamProgress]).
  Future<void> _persist() async {
    final start = _start;
    if (_shown.isEmpty || (start == null && _phase != _ExamPhase.marking)) return;
    final p = ExamProgress(
      start: start ?? _now().subtract(Duration(seconds: _seconds)),
      asked: [for (final q in _shown) questionId(q)],
      given: _answers,
      index: _index,
      handedIn: _phase == _ExamPhase.marking ? _seconds : null,
      timedOut: _timedOut,
    );
    await _db.setLocalSetting(_progressKey, p.encode());
  }

  /// Typing saves after a short pause rather than on every key.
  void _persistLater() {
    if (_phase != _ExamPhase.running) return;
    _persistSoon?.cancel();
    _persistSoon = Timer(const Duration(milliseconds: 600), _persist);
  }

  void _go(int index) {
    setState(() => _index = index);
    _persist();
  }

  void _begin(List<Assessment> attempts) {
    final earlier = [for (final a in attempts) ?ExamResult.of(a)];
    final order = pickExamQuestions(_pool, _rules, earlier: earlier);
    setState(() {
      _setUp([for (final k in order) _pool[k]], attempts);
      _start = _now();
      _lastLeft = _limit;
      _phase = _ExamPhase.running;
    });
    _persist();
    _announce('Exam started. ${timeLeftText(_limit)}. The timer does not pause.');
    // The clock, not the ticks, is the measure: a slow frame or a paused
    // app loses nothing, and the time keeps running while away.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (_phase != _ExamPhase.running) return;
    final left = _left;
    if (left <= 0) {
      _announce('Time is up. Your exam has been handed in.');
      _handIn(timedOut: true);
      return;
    }
    final mark = crossedAnnounceMark(_lastLeft, left, total: _limit);
    _lastLeft = left;
    if (mark != null) _announce(timeLeftText(mark));
    setState(() {});
  }

  /// Stops the clock and marks what can be marked; the rest waits for the
  /// learner. A blank answer is wrong and not attempted.
  void _handIn({bool timedOut = false}) {
    if (_phase != _ExamPhase.running) return;
    _tick?.cancel();
    _persistSoon?.cancel();
    _seconds = _elapsed.clamp(0, _limit);
    _start = null;
    _timedOut = timedOut;
    _markAuto();
  }

  /// Marks what can be marked; the rest waits for the learner.
  void _markAuto() {
    final answers = _answers;
    for (var k = 0; k < _shown.length; k++) {
      final q = _shown[k];
      final given = answers[k];
      _given[k] = given;
      _marks[k] = given.isEmpty
          ? false
          : q.kind == 'card'
          ? null
          : autoCorrect(q, given)
          ? true
          : (q.kind == 'choice' ? false : null);
    }
    _toMark = [
      for (var k = 0; k < _marks.length; k++)
        if (_marks[k] == null) k,
    ];
    if (_toMark.isNotEmpty) {
      setState(() => _phase = _ExamPhase.marking);
      _persist();
    } else {
      _save();
    }
  }

  Future<void> _confirmHandIn() async {
    final blank = [
      for (var k = 0; k < _shown.length; k++)
        if ((_shown[k].kind == 'choice' ? _given[k] : _typed[k].text.trim()).isEmpty) k,
    ].length;
    final ok = await askSure(
      context,
      'Hand in now?',
      [
        if (blank > 0) '$blank ${blank == 1 ? 'question has' : 'questions have'} no answer.',
        'The timer stops and the exam is marked.',
      ].join(' '),
      action: 'Hand in',
    );
    if (ok && mounted) _handIn();
  }

  Future<void> _save() async {
    setState(() => _phase = _ExamPhase.saving);
    final right = [for (final m in _marks) m ?? false];
    final result = scoreExam(
      shown: _shown,
      right: right,
      attempted: [for (final g in _given) g.isNotEmpty],
      seconds: _seconds,
      rules: _rules,
      topicTitle: _topicTitle,
      timedOut: _timedOut,
    );
    try {
      final r = await ref.mutate(
        (s) => s.book.recordExam(widget.quiz, _shown, right, result, today: today()),
      );
      await _db.setLocalSetting(_progressKey, '');
      if (!mounted) return;
      setState(() {
        _result = result;
        _cards = r.cards;
        _phase = _ExamPhase.done;
      });
      _announce('Exam marked: ${result.percent}%, ${result.passed ? 'passed' : 'not passed'}.');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  String get _topicTitle =>
      widget.quiz.title.startsWith('Quiz: ') ? widget.quiz.title.substring(6) : widget.quiz.title;

  @override
  Widget build(BuildContext context) {
    final attempts = ref.watch(examAttemptsProvider(widget.quiz.topicId)).value;
    final running = _phase == _ExamPhase.running;
    return PopScope(
      // Once started, an attempt is always recorded: leaving asks to hand
      // in, and leaving while marking saves the unmarked ones as wrong.
      canPop: _phase == _ExamPhase.intro || _phase == _ExamPhase.done || _error != null,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        if (running) {
          _confirmHandIn();
        } else if (_phase == _ExamPhase.marking) {
          _save();
        }
      },
      child: Backdrop(
        child: Scaffold(
          appBar: AppBar(
            title: Text(examTitle(widget.quiz)),
            automaticallyImplyLeading: !running,
            actions: [
              if (running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton(onPressed: _confirmHandIn, child: const Text('Hand in')),
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (running) _Countdown(left: _left, limit: _limit),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: _error != null
                              ? Text(_error!)
                              : _pool.isEmpty
                              ? const Text('This exam has no questions yet.')
                              : switch (_phase) {
                                  _ExamPhase.intro =>
                                    attempts == null || !_checked
                                        ? const Center(child: CircularProgressIndicator())
                                        : _intro(context, attempts),
                                  _ExamPhase.running => _question(context),
                                  _ExamPhase.marking => _marking(context),
                                  _ExamPhase.saving => const Center(child: CircularProgressIndicator()),
                                  _ExamPhase.done => _report(context),
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context, List<Assessment> attempts) {
    final t = Theme.of(context).textTheme;
    final next = examNextDay(attempts, _rules);
    final locked = examLocked(next, today());
    final warn = smallPoolText(
      seenBefore(pool: _pool.length, rules: _rules, asking: const [], earlier: const []),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Timed exam', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          [
            '${_pool.length} questions in ${minutesText(_rules.minutes)}.',
            'Pass mark ${_rules.passPercent}%.',
            if (_rules.shuffle) 'The questions come in a new order each time.',
          ].join(' '),
        ),
        const SizedBox(height: 8),
        const Text(
          'The timer does not pause, even if you leave the app. You see no answers until you hand in; '
          'when time runs out, the exam is handed in by itself.',
        ),
        if (_rules.retakeDays > 0) ...[
          const SizedBox(height: 8),
          Text(
            'After an attempt, the next one counts from ${_rules.retakeDays} '
            '${_rules.retakeDays == 1 ? 'day' : 'days'} later.',
          ),
        ],
        if (warn != null) ...[const SizedBox(height: 12), _Banner(Icons.history, warn)],
        const SizedBox(height: 16),
        if (locked) ...[
          _Banner(
            Icons.lock_clock,
            'Next attempt from ${niceDate(next!)}. You can practise before then; it is not counted.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => Navigator.of(
                  context,
                ).pushReplacement(MaterialPageRoute(builder: (_) => QuizPage(widget.quiz, notCounted: true))),
                child: const Text('Practise anyway (not counted)'),
              ),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
            ],
          ),
        ] else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.timer_outlined),
                label: const Text('Start the exam'),
                onPressed: () => _begin(attempts),
              ),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
            ],
          ),
      ],
    );
  }

  Widget _question(BuildContext context) {
    final q = _shown[_index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = _index + 1 == _shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Question ${_index + 1} of ${_shown.length}', style: theme.textTheme.labelLarge),
        const SizedBox(height: 16),
        Text(q.question, style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        if (q.kind == 'choice')
          for (final o in q.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                selected: _given[_index] == o,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    side: _given[_index] == o ? BorderSide(color: scheme.primary, width: 2) : null,
                  ),
                  onPressed: () {
                    setState(() => _given[_index] = o);
                    _persist();
                  },
                  child: Row(
                    children: [
                      Icon(_given[_index] == o ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                      const SizedBox(width: 12),
                      Expanded(child: Text(o)),
                    ],
                  ),
                ),
              ),
            )
        else
          TextField(
            key: ValueKey('exam-answer-$_index'),
            controller: _typed[_index],
            autofocus: true,
            minLines: 1,
            maxLines: q.kind == 'card' ? 4 : 1,
            decoration: InputDecoration(
              labelText: 'Your answer',
              helperText: q.kind == 'card' ? 'You mark this one yourself when you hand in.' : null,
              helperMaxLines: 2,
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_index > 0) OutlinedButton(onPressed: () => _go(_index - 1), child: const Text('Back')),
            if (last)
              FilledButton(onPressed: _confirmHandIn, child: const Text('Hand in'))
            else
              FilledButton(onPressed: () => _go(_index + 1), child: const Text('Next')),
          ],
        ),
      ],
    );
  }

  Widget _marking(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Mark your answers', style: t.headlineSmall),
        const SizedBox(height: 8),
        Text(
          _timedOut
              ? 'Time ran out and the exam was handed in. Compare these with the answers and mark each one.'
              : 'The timer has stopped. Compare these with the answers and mark each one.',
        ),
        const SizedBox(height: 12),
        for (final k in _toMark)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_shown[k].question, style: t.titleMedium),
                  const SizedBox(height: 6),
                  Text('You wrote: ${_given[k]}'),
                  Text('Answer: ${_shown[k].answer}'),
                  if (_shown[k].explain.isNotEmpty) ...[const SizedBox(height: 6), Text(_shown[k].explain)],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('I was right'),
                        selected: _marks[k] == true,
                        onSelected: (_) => setState(() => _marks[k] = true),
                      ),
                      ChoiceChip(
                        label: const Text('I was wrong'),
                        selected: _marks[k] == false,
                        onSelected: (_) => setState(() => _marks[k] = false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _marks.contains(null) ? null : _save, child: const Text('See my report')),
      ],
    );
  }

  Widget _report(BuildContext context) {
    final r = _result!;
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final scheme = theme.colorScheme;
    final next = _rules.retakeDays > 0 ? addDays(today(), _rules.retakeDays) : null;
    final seen = _seenAtStart;
    final first = r.studyFirst;
    final missed = r.total - r.right;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${r.percent}% · ${r.passed ? 'Passed' : 'Not passed'}', style: t.headlineSmall),
        const SizedBox(height: 4),
        Text('${r.right} of ${r.total} right. Pass mark ${r.passPercent}%.', style: t.bodyLarge),
        const SizedBox(height: 8),
        Text(
          [
            'Time taken ${clockText(r.seconds)} of ${clockText(r.limitSeconds)}'
                '${r.timedOut ? ' (time ran out)' : ''}.',
            'Answered ${r.attempted} of ${r.total}.',
          ].join(' '),
        ),
        if (next != null) ...[const SizedBox(height: 8), Text('Next attempt from ${niceDate(next)}.')],
        if (seen != null) ...[
          const SizedBox(height: 12),
          _Banner(Icons.history, [seenBeforeText(seen), ?smallPoolText(seen)].join(' ')),
        ],
        if (r.topics.length > 1 || first.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('By topic', style: t.titleMedium),
          for (final ts in r.topics)
            Meter(ts.topic, ts.total == 0 ? 0 : ts.right / ts.total, trailing: '${ts.right} of ${ts.total}'),
        ],
        if (first.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Study these first', style: t.titleMedium),
          const SizedBox(height: 4),
          for (final (i, name) in first.indexed) Text('${i + 1}. $name'),
        ],
        if (missed > 0) ...[
          const SizedBox(height: 12),
          Text(
            _cards > 0
                ? '$_cards missed ${_cards == 1 ? 'question is' : 'questions are'} now review cards, '
                      'so they come back on a schedule.'
                : 'The missed questions are already review cards.',
          ),
        ],
        const SizedBox(height: 16),
        Text('All answers', style: t.titleMedium),
        for (var k = 0; k < _shown.length; k++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: (_marks[k] ?? false) ? 'Right' : 'Wrong',
                    child: Icon(
                      (_marks[k] ?? false) ? Icons.check : Icons.close,
                      color: (_marks[k] ?? false) ? scheme.primary : scheme.error,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${k + 1}. ${_shown[k].question}', style: t.titleSmall),
                        const SizedBox(height: 4),
                        Text(_given[k].isEmpty ? 'No answer' : 'You: ${_given[k]}'),
                        Text('Answer: ${_shown[k].answer}'),
                        if (_shown[k].explain.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(_shown[k].explain, style: t.bodyMedium?.copyWith(color: muted(context))),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back to the topic')),
      ],
    );
  }
}

/// The time left, large and plain: no animation (so reduced motion is
/// kept), and read by a screen reader only when it is focused; the page
/// announces it at set points instead of every second.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.left, required this.limit});
  final int left, limit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final low = left <= 60;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Time left: ${timeLeftText(left)}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Icon(Icons.timer_outlined, color: low ? scheme.error : null),
                Text(
                  clockText(left),
                  style: t.headlineMedium?.merge(tabular).copyWith(color: low ? scheme.error : null),
                ),
                Text('left', style: t.bodyMedium?.copyWith(color: muted(context))),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: limit == 0 ? 0 : left / limit, minHeight: 6),
          ],
        ),
      ),
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
