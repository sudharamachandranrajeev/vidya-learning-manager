/// Stress tests (assess plan A5): the card on a topic or course page, and
/// the runner: the brief, then the table against a countdown that never
/// pauses (an action and a one-line reason per row, handed in by itself at
/// zero), then the automatic checks and a self-rating on four checks. The
/// rules live in domain/scenario.dart.
///
/// The table is one card per row at every width, so it never scrolls
/// sideways, and each row is one semantic group for a screen reader.
library;

import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column, View;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/exam.dart' show clockText, crossedAnnounceMark, examLocked, timeLeftText;
import '../domain/interview.dart' show drillMax, drillScore, rubricOf5;
import '../domain/scenario.dart';
import 'common.dart';
import 'quiz_page.dart' show ExamCountdown, examClockProvider;
import 'markdown.dart';
import 'zen.dart';

Future<void> openScenario(BuildContext context, String itemId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScenarioPage(itemId)));

/// A stress test and its attempts, oldest first.
typedef ScenarioView = ({StudyItem item, Scenario scenario, List<(Assessment, ScenarioAttempt)> attempts});

final scenarioViewProvider = FutureProvider.family<ScenarioView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final item = await (db.select(
    db.learnItems,
  )..where((i) => i.id.equals(id) & i.deleted.not())).getSingleOrNull();
  final scenario = item == null ? null : scenarioOf(item);
  if (item == null || scenario == null) return null;
  return (item: item, scenario: scenario, attempts: await book.scenarioAttempts(id));
});

/// "No high-risk row untouched · rating 4/5 · done".
String attemptText(ScenarioAttempt a) {
  final u = a.findings.untouchedHigh.length;
  return [
    u == 0 ? 'no high-risk row untouched' : '$u high-risk ${u == 1 ? 'row' : 'rows'} untouched',
    'rating ${a.of5}/5',
    a.passed ? 'done' : 'not yet done',
  ].join(' · ');
}

/// A stress test on a topic or course page: its size, the last attempt and
/// the button to start one.
class ScenarioCard extends ConsumerWidget {
  const ScenarioCard(this.itemId, {super.key});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(scenarioViewProvider(itemId)).value;
    if (v == null) return const SizedBox.shrink();
    final last = v.attempts.lastOrNull?.$2;
    final next = scenarioNextDay(v.scenario, [for (final (a, _) in v.attempts) a]);
    final locked = examLocked(next, today());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(v.item.done != null ? Icons.fact_check : Icons.fact_check_outlined),
          title: Text(v.item.title),
          subtitle: Text('Stress test · ${v.scenario.summary}'),
        ),
        Text(
          last == null ? 'Not tried yet' : 'Last attempt: ${attemptText(last)}',
          key: Key('scenario-last-$itemId'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (locked)
          Text(
            'Next counted attempt from ${niceDate(next!)}.',
            key: Key('scenario-lock-$itemId'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.play_arrow),
            label: Text(last == null ? 'Start stress test' : 'Open stress test'),
            onPressed: () => openScenario(context, itemId),
          ),
        ),
      ],
    );
  }
}

enum _Phase { intro, running, rating, saving, done }

class ScenarioPage extends ConsumerStatefulWidget {
  const ScenarioPage(this.itemId, {super.key});
  final String itemId;

  @override
  ConsumerState<ScenarioPage> createState() => _ScenarioPageState();
}

class _ScenarioPageState extends ConsumerState<ScenarioPage> {
  var _phase = _Phase.intro;

  /// The scenario as it was when the attempt began.
  Scenario? _s;
  var _picks = <String>[];
  var _reasons = <TextEditingController>[];
  final _checks = List<int?>.filled(scenarioChecks.length, null);

  DateTime? _start;
  Timer? _tick;
  var _seconds = 0;
  var _timedOut = false;
  var _lastLeft = 0;
  ScenarioAttempt? _saved;
  String? _error;

  /// A practice run while the retake wait lasts: never saved, never kept.
  var _practice = false;

  /// Whether a saved, unfinished attempt has been looked for yet.
  var _checked = false;
  Timer? _persistSoon;

  /// Each phase opens at its top: the checks after handing in, the verdict
  /// after saving.
  final _scroll = ScrollController();
  void _toTop() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  late final DateTime Function() _clock;
  late final AppDatabase _db;

  int get _limit => (_s?.minutes ?? Scenario.defaultMinutes) * 60;
  int get _elapsed => _start == null ? _seconds : _clock().difference(_start!).inSeconds;
  int get _left => (_limit - _elapsed).clamp(0, _limit);
  String get _key => scenarioProgressKey(widget.itemId);

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
    for (final c in _reasons) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _announce(String text) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), text, Directionality.of(context));
  }

  void _setUp(Scenario s, {List<String>? picks, List<String>? reasons}) {
    for (final c in _reasons) {
      c.dispose();
    }
    _s = s;
    _picks = picks != null ? List.of(picks) : List.filled(s.rows.length, '');
    _reasons = [
      for (var k = 0; k < s.rows.length; k++)
        TextEditingController(text: reasons != null && k < reasons.length ? reasons[k] : '')
          ..addListener(_persistLater),
    ];
    _checks.fillRange(0, _checks.length, null);
  }

  /// Picks up an attempt the app was closed or killed in: the time has kept
  /// running from its start, so it may be handed in at once.
  Future<void> _restore() async {
    final v = await ref.read(scenarioViewProvider(widget.itemId).future);
    if (v == null) {
      if (mounted) setState(() => _checked = true);
      return;
    }
    final saved = ScenarioProgress.parse(await _db.localSetting(_key), v.scenario.rows.length);
    if (!mounted) return;
    if (saved == null) {
      setState(() => _checked = true);
      return;
    }
    _setUp(v.scenario, picks: saved.picks, reasons: saved.reasons);
    _checked = true;
    if (saved.handedIn != null) {
      setState(() {
        _seconds = saved.handedIn!.clamp(0, _limit);
        _timedOut = saved.timedOut;
        _phase = _Phase.rating;
      });
      return;
    }
    _start = saved.start;
    setState(() => _phase = _Phase.running);
    if (_left <= 0) {
      _announce('Time ran out while you were away. Your work has been handed in.');
      _handIn(timedOut: true);
      return;
    }
    _lastLeft = _left;
    _announce('Stress test resumed. ${timeLeftText(_left)}.');
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  /// Saves the unfinished attempt on this device (see [ScenarioProgress]).
  Future<void> _persist() async {
    if (_practice) return;
    if (_s == null || (_phase != _Phase.running && _phase != _Phase.rating)) return;
    final p = ScenarioProgress(
      start: _start ?? _clock().subtract(Duration(seconds: _seconds)),
      picks: _picks,
      reasons: [for (final c in _reasons) c.text.trim()],
      handedIn: _phase == _Phase.rating ? _seconds : null,
      timedOut: _timedOut,
    );
    await _db.setLocalSetting(_key, p.encode());
  }

  void _persistLater() {
    if (_phase != _Phase.running) return;
    _persistSoon?.cancel();
    _persistSoon = Timer(const Duration(milliseconds: 600), _persist);
  }

  void _begin(ScenarioView v, {bool practice = false}) {
    setState(() {
      _practice = practice;
      _setUp(v.scenario);
      _start = _clock();
      _seconds = 0;
      _timedOut = false;
      _saved = null;
      _lastLeft = _limit;
      _phase = _Phase.running;
    });
    _toTop();
    _persist();
    _announce('Stress test started. ${timeLeftText(_limit)}. The timer does not pause.');
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (_phase != _Phase.running) return;
    final left = _left;
    if (left <= 0) {
      _announce('Time is up. Your work has been handed in.');
      _handIn(timedOut: true);
      return;
    }
    final mark = crossedAnnounceMark(_lastLeft, left, total: _limit);
    _lastLeft = left;
    if (mark != null) _announce(timeLeftText(mark));
    setState(() {});
  }

  void _pick(int row, String action) {
    setState(() => _picks[row] = action);
    _persist();
  }

  /// Stops the clock; the checks and the rating are left.
  void _handIn({bool timedOut = false}) {
    if (_phase != _Phase.running) return;
    _tick?.cancel();
    _persistSoon?.cancel();
    setState(() {
      _seconds = _elapsed.clamp(0, _limit);
      _start = null;
      _timedOut = timedOut;
      _phase = _Phase.rating;
    });
    _toTop();
    _persist();
  }

  Future<void> _confirmHandIn() async {
    final open = _picks.where((p) => p.isEmpty).length;
    final ok = await askSure(
      context,
      'Hand in now?',
      [
        if (open > 0) '$open ${open == 1 ? 'row has' : 'rows have'} no action.',
        'The timer stops and your work is checked.',
      ].join(' '),
      action: 'Hand in',
    );
    if (ok && mounted) _handIn();
  }

  ScenarioAttempt _attempt() => ScenarioAttempt(
    scenario: _s!,
    picks: List.of(_picks),
    reasons: [for (final c in _reasons) c.text.trim()],
    checks: [for (final c in _checks) c ?? 0],
    seconds: _seconds,
    timedOut: _timedOut,
  );

  Future<void> _save(ScenarioView v) async {
    if (_checks.any((c) => c == null)) return notify(context, 'Rate all four checks first.');
    final attempt = _attempt();
    if (_practice) {
      setState(() {
        _saved = attempt;
        _phase = _Phase.done;
      });
      _toTop();
      _announce('Practice, not counted. ${attemptText(attempt)}.');
      return;
    }
    setState(() => _phase = _Phase.saving);
    try {
      await ref.mutate((s) => s.book.recordScenario(v.item, attempt, today: today()));
      await _db.setLocalSetting(_key, '');
      if (!mounted) return;
      setState(() {
        _saved = attempt;
        _phase = _Phase.done;
      });
      _toTop();
      _announce('Saved. ${attemptText(attempt)}.');
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(scenarioViewProvider(widget.itemId)),
      builder: (v) {
        if (v == null) {
          return const Scaffold(body: Center(child: Text('This stress test is no longer in the plan.')));
        }
        final running = _phase == _Phase.running;
        return PopScope(
          // Leaving while the clock runs asks to hand in; leaving while
          // rating keeps the work on this device until it is rated.
          canPop: !running,
          onPopInvokedWithResult: (popped, _) {
            if (!popped && running) _confirmHandIn();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(v.item.title),
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
                  if (running) ExamCountdown(left: _left, limit: _limit),
                  Expanded(
                    child: ListView(
                      key: const Key('scenario-list'),
                      controller: _scroll,
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                      children: [
                        for (final w
                            in _error != null
                                ? [Text(_error!)]
                                : switch (_phase) {
                                    _Phase.intro =>
                                      _checked
                                          ? _intro(v)
                                          : const [Center(child: CircularProgressIndicator())],
                                    _Phase.running => _table(),
                                    _Phase.rating => [..._checksView(_attempt()), ..._rating(v)],
                                    _Phase.saving => const [Center(child: CircularProgressIndicator())],
                                    _Phase.done => _done(_saved!),
                                  })
                          Center(
                            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: w),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  List<Widget> _intro(ScenarioView v) {
    final t = Theme.of(context).textTheme;
    final s = v.scenario;
    final next = scenarioNextDay(s, [for (final (a, _) in v.attempts) a]);
    return [
      Text('Stress test', style: t.headlineSmall),
      const SizedBox(height: 8),
      if (s.brief.isNotEmpty) SectionCard(title: 'The brief', child: MarkdownText(s.brief)),
      Text(
        '${s.rows.length} ${s.rows.length == 1 ? 'row' : 'rows'} in ${s.minutes} minutes. For each row, choose '
        'one of: ${s.actions.map(actionLabel).join(', ')}, and add a reason if you like.',
      ),
      const SizedBox(height: 8),
      const Text(
        'The timer does not pause, even if you leave the app. When time runs out, your work is handed in '
        'by itself. Rows that could do harm are not marked: finding them is part of the test.',
      ),
      if (s.rubric.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(title: 'What good work looks like', child: MarkdownText(s.rubric)),
      ],
      if (s.retakeDays > 0) ...[
        const SizedBox(height: 8),
        Text(
          'After an attempt, the next one counts from ${s.retakeDays} '
          '${s.retakeDays == 1 ? 'day' : 'days'} later.',
        ),
      ],
      const SizedBox(height: 12),
      if (examLocked(next, today())) ...[
        Text(
          'Next counted attempt from ${niceDate(next!)}. You can practise before then; it is not saved.',
          key: const Key('scenario-locked'),
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () => _begin(v, practice: true),
            child: const Text('Practise anyway (not counted)'),
          ),
        ),
      ] else
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start the stress test'),
            onPressed: () => _begin(v),
          ),
        ),
      if (v.attempts.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(
          title: 'Past attempts',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (a, at) in v.attempts.reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(niceDate(a.day)),
                  subtitle: Text(
                    [
                      attemptText(at),
                      'took ${clockText(at.seconds)}',
                      if (at.timedOut) 'time ran out',
                    ].join(' · '),
                  ),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        'Done when an attempt leaves no high-risk row untouched and you rate it at least '
        '$scenarioPassOutOf8 of $drillMax (${rubricOf5(scenarioPassOutOf8)}/5).',
        style: t.bodySmall,
      ),
    ];
  }

  /// "Item: T001" lines for a row.
  List<Widget> _cells(int i) {
    final s = _s!;
    final t = Theme.of(context).textTheme;
    return [
      for (final (k, col) in s.columns.indexed)
        if (s.rows[i].cells[k].isNotEmpty)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$col: ', style: t.labelLarge),
                TextSpan(text: s.rows[i].cells[k]),
              ],
            ),
          ),
    ];
  }

  /// The table, one card per row.
  List<Widget> _table() {
    final s = _s!;
    final t = Theme.of(context).textTheme;
    final done = _picks.where((p) => p.isNotEmpty).length;
    return [
      Text('$done of ${s.rows.length} rows have an action', style: t.labelLarge),
      const SizedBox(height: 8),
      for (var i = 0; i < s.rows.length; i++)
        Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Row ${i + 1} of ${s.rows.length}',
          child: Card(
            key: Key('scenario-row-$i'),
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Row ${i + 1}', style: t.titleSmall),
                  ..._cells(i),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final a in s.actions)
                        ChoiceChip(
                          key: Key('scenario-pick-$i-$a'),
                          label: Text(actionLabel(a)),
                          selected: _picks[i] == a,
                          onSelected: (on) => _pick(i, on ? a : ''),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    key: Key('scenario-reason-$i'),
                    controller: _reasons[i],
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: 'Reason (optional)', counterText: ''),
                  ),
                ],
              ),
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(onPressed: _confirmHandIn, child: const Text('Hand in')),
      ),
    ];
  }

  /// "Row 3 (T003)".
  String _rowName(Scenario s, int i) {
    final first = s.rows[i].cells.first;
    return first.isEmpty ? 'Row ${i + 1}' : 'Row ${i + 1} ($first)';
  }

  /// The automatic checks: untouched high-risk rows first, then the rows
  /// with an expected action, the count per action and the time.
  List<Widget> _checksView(ScenarioAttempt a) {
    final t = Theme.of(context).textTheme;
    final s = a.scenario;
    final f = a.findings;
    final error = Theme.of(context).colorScheme.error;
    final expected = [...f.mismatched, ...f.matched];
    return [
      SectionCard(
        title: 'Checks',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (f.untouchedHigh.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: StatusPill('No high-risk row left untouched', status: KitStatus.good),
              )
            else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: StatusPill(
                  'High-risk rows left untouched: ${f.untouchedHigh.length}',
                  key: const Key('scenario-untouched'),
                  status: KitStatus.critical,
                ),
              ),
              for (final i in f.untouchedHigh)
                Semantics(
                  container: true,
                  label: 'Warning: high-risk row left untouched',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.error_outline, color: error),
                    title: Text(_rowName(s, i), style: TextStyle(color: error)),
                    subtitle: Text(
                      [
                        s.rows[i].cells.skip(1).where((c) => c.isNotEmpty).join(' · '),
                        if (s.rows[i].why.isNotEmpty) 'Model answer: ${s.rows[i].why}',
                      ].where((x) => x.isNotEmpty).join('\n'),
                    ),
                  ),
                ),
            ],
            if (expected.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Matched the expected action on ${f.matched.length} of ${expected.length} '
                '${expected.length == 1 ? 'row' : 'rows'}',
                key: const Key('scenario-matched'),
                style: t.titleSmall,
              ),
              for (final i in expected)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(f.matched.contains(i) ? Icons.check_circle_outline : Icons.compare_arrows),
                  title: Text(_rowName(s, i)),
                  subtitle: Text(
                    [
                      'You: ${a.picks[i].isEmpty ? 'no action' : actionLabel(a.picks[i])}'
                          ' · expected: ${actionLabel(s.rows[i].expect)}'
                          '${f.matched.contains(i) ? ' (matched)' : ' (different)'}',
                      if (a.reasons[i].isNotEmpty) 'Your reason: ${a.reasons[i]}',
                      if (s.rows[i].why.isNotEmpty) 'Model answer: ${s.rows[i].why}',
                    ].join('\n'),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              [
                for (final act in s.actions) '${actionLabel(act)} ${f.counts[act] ?? 0}',
                'No action ${f.counts[''] ?? 0}',
              ].join(' · '),
              key: const Key('scenario-counts'),
            ),
            Text(
              'Time used ${clockText(a.seconds)} of ${clockText(s.minutes * 60)}'
              '${a.timedOut ? ' (time ran out)' : ''}',
              key: const Key('scenario-time'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _rating(ScenarioView v) {
    final t = Theme.of(context).textTheme;
    final s = _s!;
    final all = _checks.every((c) => c != null);
    final score = all ? drillScore([for (final c in _checks) c!]) : null;
    return [
      SectionCard(
        title: 'Rate yourself',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s.rubric.isNotEmpty) ...[
              Text('The rubric', style: t.titleSmall),
              MarkdownText(s.rubric),
              const SizedBox(height: 12),
            ],
            for (final (k, (_, label, help)) in scenarioChecks.indexed) ...[
              Text(label, style: t.titleSmall),
              Text(help, style: t.bodySmall),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                key: Key('scenario-check-$k'),
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('No')),
                  ButtonSegment(value: 1, label: Text('Partly')),
                  ButtonSegment(value: 2, label: Text('Yes')),
                ],
                selected: {?_checks[k]},
                onSelectionChanged: (sel) => setState(() => _checks[k] = sel.firstOrNull),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              score == null
                  ? 'Score: rate all four checks.'
                  : 'Score: ${rubricOf5(score)}/5 ($score/$drillMax)',
              key: const Key('scenario-score'),
              style: t.titleSmall,
            ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(onPressed: () => _save(v), child: const Text('Save my rating')),
      ),
    ];
  }

  List<Widget> _done(ScenarioAttempt a) => [
    if (_practice)
      Text(
        'Practice, not counted: nothing was saved.',
        key: const Key('scenario-practice'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
    Align(
      alignment: Alignment.centerLeft,
      child: StatusPill(
        a.passed ? 'Done' : 'Not done yet',
        key: const Key('scenario-verdict'),
        status: a.passed ? KitStatus.good : KitStatus.warning,
      ),
    ),
    const SizedBox(height: 8),
    Text(attemptText(a)),
    if (!a.passed)
      Text(
        'Done needs no high-risk row untouched and a rating of at least '
        '${rubricOf5(scenarioPassOutOf8)}/5. Try again when you are ready.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    const SizedBox(height: 8),
    ..._checksView(a),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton(
        onPressed: () => setState(() {
          _saved = null;
          _practice = false;
          _phase = _Phase.intro;
        }),
        child: const Text('Back to the stress test'),
      ),
    ),
  ];
}
