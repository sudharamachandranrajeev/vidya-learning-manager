/// Capstones (assess plan A3): the card on a topic or course page, and the
/// sitting: the capstone's drills back-to-back with one clock, each asked by
/// the panel its plan set, then the result on the 1–5 rubric scale with the
/// average, the lowest score, pass or fail and the passes in a row. The
/// rules live in domain/capstone.dart.
///
/// Each drill is answered the way any drill is: out loud and rated on the
/// four checks here, or with the interviewer (which opens on the drill's
/// panel and level); its result counts once saved on the drill.
library;

import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' as ie;

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/capstone.dart';
import '../domain/interview.dart';
import '../domain/spoken_interview.dart';
import 'common.dart';
import 'spoken_interview_page.dart';
import 'zen.dart';

Future<void> openCapstone(BuildContext context, String itemId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CapstonePage(itemId)));

/// A capstone, its drills, its sittings (oldest first) and each drill's
/// attempts.
typedef CapstoneView = ({
  StudyItem item,
  CapstoneRules rules,
  List<StudyItem> drills,
  List<(Assessment, CapstoneSitting)> sittings,
  Map<String, List<Assessment>> attempts,
  List<Criterion> criteria,
});

final capstoneViewProvider = FutureProvider.family<CapstoneView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final item = await (db.select(
    db.learnItems,
  )..where((i) => i.id.equals(id) & i.deleted.not())).getSingleOrNull();
  final rules = item == null ? null : capstoneRules(item);
  if (item == null || rules == null) return null;
  final drills = await book.capstoneDrills(item);
  final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(item.topicId))).getSingleOrNull();
  final course = topic == null
      ? null
      : await (db.select(db.learnCourses)..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
  final pid = course?.programId;
  return (
    item: item,
    rules: rules,
    drills: drills,
    sittings: await book.capstoneSittings(id),
    attempts: {for (final d in drills) d.id: await book.drillAttempts(d.id)},
    criteria: pid == null ? const <Criterion>[] : await book.programCriteria(pid),
  );
});

/// A capstone's unfinished sitting on this device, or null.
final capstoneProgressProvider = FutureProvider.family<CapstoneProgress?, String>((ref, id) async {
  final db = ref.watch(sessionProvider).db;
  return CapstoneProgress.parse(await db.localSetting(capstoneProgressKey(id)));
});

String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// The panel a drill is asked by, in words.
String _panelText(StudyItem d) {
  final p = drillPreset(d);
  final persona = p.persona == null ? null : ie.Persona.of(p.persona!);
  return [
    persona == null ? 'Your usual panel' : '${persona.label} panel',
    if (p.level case final l?) 'level $l',
  ].join(', ');
}

/// The capstone on a topic or course page: its rules, the passes in a row
/// and the last sitting, and the button to start one.
class CapstoneCard extends ConsumerWidget {
  const CapstoneCard(this.itemId, {super.key});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(capstoneViewProvider(itemId)).value;
    if (v == null) return const SizedBox.shrink();
    final open = ref.watch(capstoneProgressProvider(itemId)).value;
    final t = Theme.of(context).textTheme;
    final streak = capstoneStreak([for (final (_, s) in v.sittings) s]);
    final last = v.sittings.lastOrNull?.$2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            streak >= v.rules.passesInRow ? Icons.workspace_premium : Icons.workspace_premium_outlined,
          ),
          title: Text(v.item.title),
          subtitle: Text(
            [
              '${v.drills.length} ${v.drills.length == 1 ? 'drill' : 'drills'} in one sitting',
              v.rules.summary,
            ].join(' · '),
          ),
        ),
        Text(
          [
            streakText(streak, v.rules),
            if (open != null) 'a sitting is under way, ${open.summary(DateTime.now())}',
            if (last != null)
              'last sitting ${last.average.toStringAsFixed(1)}/5, ${last.passed ? 'passed' : 'not passed'}',
          ].join(' · '),
          key: Key('capstone-streak-$itemId'),
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.flag_outlined),
            label: Text(
              open != null
                  ? 'Resume capstone'
                  : v.sittings.isEmpty
                  ? 'Start capstone'
                  : 'Open capstone',
            ),
            onPressed: v.drills.isEmpty
                ? null
                : () async {
                    await openCapstone(context, itemId);
                    ref.invalidate(capstoneProgressProvider(itemId));
                  },
          ),
        ),
      ],
    );
  }
}

class CapstonePage extends ConsumerStatefulWidget {
  const CapstonePage(this.itemId, {super.key});
  final String itemId;

  @override
  ConsumerState<CapstonePage> createState() => _CapstonePageState();
}

class _CapstonePageState extends ConsumerState<CapstonePage> {
  /// When the sitting started; null before it starts.
  DateTime? _started;
  Timer? _tick;
  int _seconds = 0;

  /// The drills of the sitting, fixed when it starts.
  List<StudyItem> _drills = const [];
  int _index = 0;
  final _results = <CapstoneDrill>[];

  /// Attempt ids each drill had before the sitting: a newer one came from
  /// the interviewer during it.
  final _before = <String, Set<String>>{};
  final _checks = List<int?>.filled(drillChecks.length, null);
  bool _busy = false;

  /// The saved sitting, once finished.
  CapstoneSitting? _done;
  int _streak = 0;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String get _key => capstoneProgressKey(widget.itemId);

  /// Keeps the sitting so far on this device (see [CapstoneProgress]), or
  /// clears it when [clear].
  Future<void> _persist({bool clear = false}) async {
    final db = ref.read(sessionProvider).db;
    final start = _started;
    await db.setLocalSetting(
      _key,
      clear || start == null
          ? ''
          : CapstoneProgress(
              start: start,
              drills: [for (final d in _drills) d.id],
              index: _index,
              results: [..._results],
              before: {for (final MapEntry(:key, :value) in _before.entries) key: value.toList()},
            ).encode(),
    );
    ref.invalidate(capstoneProgressProvider(widget.itemId));
  }

  void _run() {
    _tick?.cancel();
    _seconds = DateTime.now().difference(_started!).inSeconds;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _started;
      if (mounted && start != null) setState(() => _seconds = DateTime.now().difference(start).inSeconds);
    });
  }

  void _start(CapstoneView v) {
    setState(() {
      _started = DateTime.now();
      _seconds = 0;
      _drills = v.drills;
      _index = 0;
      _results.clear();
      _done = null;
      _checks.fillRange(0, _checks.length, null);
      _before
        ..clear()
        ..addAll({
          for (final d in v.drills) d.id: {for (final a in v.attempts[d.id] ?? const []) a.id},
        });
    });
    _run();
    _persist();
  }

  /// Picks up a saved sitting: its drills still in the capstone, the
  /// answers so far and the clock still running from its start.
  void _resume(CapstoneView v, CapstoneProgress p) {
    final byId = {for (final d in v.drills) d.id: d};
    final drills = [for (final id in p.drills) ?byId[id]];
    if (drills.isEmpty) {
      _persist(clear: true);
      return;
    }
    setState(() {
      _started = p.start;
      _drills = drills;
      _results
        ..clear()
        ..addAll(p.results.where((r) => byId.containsKey(r.id)).take(drills.length - 1));
      _index = _results.length.clamp(0, drills.length - 1);
      _done = null;
      _checks.fillRange(0, _checks.length, null);
      _before
        ..clear()
        ..addAll({for (final d in drills) d.id: (p.before[d.id] ?? const []).toSet()});
    });
    _run();
  }

  /// The drill's newest attempt saved during the sitting (from the
  /// interviewer's debrief), or null.
  Assessment? _fromInterviewer(CapstoneView v, StudyItem d) => (v.attempts[d.id] ?? const [])
      .where((a) => !(_before[d.id] ?? const {}).contains(a.id) && a.max > 0)
      .firstOrNull;

  Future<void> _next(CapstoneView v, {bool skip = false}) async {
    final d = _drills[_index];
    final interviewer = _fromInterviewer(v, d);
    final self = _checks.every((c) => c != null) ? [for (final c in _checks) c!] : null;
    if (!skip && interviewer == null && self == null) {
      return notify(context, 'Rate all four checks, or answer with the interviewer first.');
    }
    setState(() => _busy = true);
    var result = CapstoneDrill(id: d.id, title: drillQuestion(d), persona: drillPersona(d));
    if (!skip && self != null) {
      // Rated here: saved on the drill like any attempt.
      final attempt = DrillAttempt(checks: self, note: 'Capstone sitting');
      final id = await ref.mutate((s) => s.book.recordDrill(d, attempt, today: today()));
      _before[d.id] = {...?_before[d.id], id};
      result = CapstoneDrill(
        id: d.id,
        title: result.title,
        persona: result.persona,
        outOf8: attempt.score,
        attempt: id,
      );
    } else if (!skip && interviewer != null) {
      result = CapstoneDrill(
        id: d.id,
        title: result.title,
        persona: result.persona,
        outOf8: (interviewer.score * drillMax / interviewer.max).round().clamp(0, drillMax),
        attempt: interviewer.id,
      );
    }
    _results.add(result);
    _checks.fillRange(0, _checks.length, null);
    if (_index + 1 < _drills.length) {
      setState(() {
        _index++;
        _busy = false;
      });
      await _persist();
      return;
    }
    _tick?.cancel();
    final seconds = DateTime.now().difference(_started!).inSeconds;
    final sitting = CapstoneSitting(drills: [..._results], rules: v.rules, seconds: seconds);
    await ref.mutate((s) => s.book.recordCapstone(v.item, sitting, today: today()));
    await _persist(clear: true);
    final all = await ref.read(sessionProvider).book.capstoneSittings(v.item.id);
    if (!mounted) return;
    setState(() {
      _done = sitting;
      _streak = capstoneStreak([for (final (_, s) in all) s]);
      _seconds = seconds;
      _started = null;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(capstoneViewProvider(widget.itemId)),
      builder: (v) {
        if (v == null) {
          return const Scaffold(body: Center(child: Text('This capstone is no longer in the plan.')));
        }
        // Leaving mid-sitting keeps it on this device, to resume later.
        return PopScope(
          onPopInvokedWithResult: (popped, _) {
            if (popped && _started != null && _done == null) {
              notify(context, 'Sitting kept on this device. Open the capstone to resume it.');
            }
          },
          child: Scaffold(
            appBar: AppBar(title: Text(v.item.title)),
            body: ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _done != null
                          ? _result(v, _done!)
                          : _started != null
                          ? _sitting(v)
                          : _intro(v),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  List<Widget> _intro(CapstoneView v) {
    final t = Theme.of(context).textTheme;
    final streak = capstoneStreak([for (final (_, s) in v.sittings) s]);
    return [
      Text(
        'All ${v.drills.length} drills in one sitting, one after another, each asked by its own panel. '
        '${v.rules.minutes != null ? 'The clock shows ${v.rules.minutes} minutes for the whole sitting; it '
                  'does not stop you, and the time is noted. ' : ''}'
        'Pass: ${v.rules.summary}.',
        style: t.bodyMedium,
      ),
      const SizedBox(height: 8),
      Text(streakText(streak, v.rules), key: const Key('capstone-streak'), style: t.titleSmall),
      const SizedBox(height: 12),
      SectionCard(
        title: 'The drills',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, d) in v.drills.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
                title: Text(drillQuestion(d)),
                subtitle: Text(_panelText(d)),
              ),
            if (v.drills.any((d) => drillPreset(d).persona == ie.PersonaKind.challenging))
              Text('$challengingAbout $safeRehearsalNote', style: t.bodySmall),
          ],
        ),
      ),
      if (ref.watch(capstoneProgressProvider(widget.itemId)).value case final p?) ...[
        Text(
          'You have a sitting under way: ${p.summary(DateTime.now())}. The clock kept running.',
          key: const Key('capstone-resume-note'),
          style: t.bodyMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Resume sitting'),
              onPressed: () => _resume(v, p),
            ),
            TextButton(
              onPressed: () async {
                if (await askSure(
                      context,
                      'Start again?',
                      'The sitting under way is dropped. Drills already rated stay saved on the drills.',
                      action: 'Start again',
                    ) &&
                    mounted) {
                  _start(v);
                }
              },
              child: const Text('Start again'),
            ),
          ],
        ),
      ] else
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start capstone'),
          onPressed: v.drills.isEmpty ? null : () => _start(v),
        ),
      if (v.sittings.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(
          title: 'Past sittings',
          child: Column(
            children: [
              for (final (a, s) in v.sittings.reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${niceDate(a.day)} · average ${s.average.toStringAsFixed(1)}/5 · lowest ${s.minimum}/5',
                  ),
                  subtitle: Text(
                    [
                      s.passed ? 'Passed' : 'Not passed',
                      if (s.seconds > 0) 'took ${_clock(s.seconds)}',
                      if (s.overTime) 'over time',
                    ].join(' · '),
                  ),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _sitting(CapstoneView v) {
    final t = Theme.of(context).textTheme;
    final d = _drills[_index];
    final limit = v.rules.minutes;
    final over = limit != null && _seconds > limit * 60;
    final interviewer = _fromInterviewer(v, d);
    final self = _checks.every((c) => c != null) ? drillScore([for (final c in _checks) c!]) : null;
    final preset = drillPreset(d);
    final persona = preset.persona == null ? null : ie.Persona.of(preset.persona!);
    final criterion = drillCriterionText(d, v.criteria);
    final last = _index + 1 >= _drills.length;
    return [
      Text(
        'Time ${_clock(_seconds)}${limit == null ? '' : ' of ${_clock(limit * 60)}'}',
        key: const Key('capstone-clock'),
        style: t.titleMedium?.copyWith(color: over ? KitStatus.warning.color : null),
      ),
      if (over)
        Text(
          'Over the time. Finish when you can; the time is noted.',
          style: TextStyle(color: KitStatus.warning.color),
        ),
      const SizedBox(height: 4),
      Text('Drill ${_index + 1} of ${_drills.length}', style: t.labelLarge),
      LinearProgressIndicator(value: (_index + 1) / _drills.length),
      const SizedBox(height: 12),
      SectionCard(
        title: _panelText(d),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (persona != null) Text(personaAbout(persona), style: t.bodySmall),
            const SizedBox(height: 8),
            SelectableText(drillQuestion(d), style: t.titleMedium),
            if (criterion.isNotEmpty) Text('Tests: $criterion', style: t.bodySmall),
            const SizedBox(height: 8),
            Text(
              'Answer out loud as you would to the panel, then rate yourself below. Or answer with the '
              'interviewer: it asks this drill on its panel, and its score counts once saved on the drill.',
              style: t.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('Answer with the interviewer'),
                onPressed: () => openSpokenInterview(context, itemId: d.id),
              ),
            ),
            if (interviewer != null)
              Text(
                'From the interviewer: ${rubricText(interviewer.score * drillMax / interviewer.max)}',
                key: const Key('capstone-interviewer'),
                style: t.titleSmall,
              ),
          ],
        ),
      ),
      SectionCard(
        title: 'Rate yourself',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (k, (_, label, help)) in drillChecks.indexed) ...[
              Text(label, style: t.titleSmall),
              Text(help, style: t.bodySmall),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                key: Key('cap-check-$k'),
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('No')),
                  ButtonSegment(value: 1, label: Text('Partly')),
                  ButtonSegment(value: 2, label: Text('Yes')),
                ],
                selected: {?_checks[k]},
                onSelectionChanged: (s) => setState(() => _checks[k] = s.firstOrNull),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              self == null ? 'Score: rate all four checks.' : 'Score: ${rubricText(self)} ($self/$drillMax)',
              style: t.titleSmall,
            ),
          ],
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            icon: Icon(last ? Icons.flag_outlined : Icons.arrow_forward),
            label: Text(last ? 'Finish' : 'Next drill'),
            onPressed: _busy ? null : () => _next(v),
          ),
          TextButton(
            onPressed: _busy ? null : () => _next(v, skip: true),
            child: const Text('Skip this drill'),
          ),
        ],
      ),
      Text('A skipped drill means the sitting does not pass.', style: t.bodySmall),
    ];
  }

  List<Widget> _result(CapstoneView v, CapstoneSitting s) {
    final t = Theme.of(context).textTheme;
    return [
      SectionCard(
        title: 'Capstone result',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: StatusPill(
                s.passed ? 'Passed' : 'Not passed',
                status: s.passed ? KitStatus.good : KitStatus.warning,
              ),
            ),
            const SizedBox(height: 8),
            for (final d in s.drills)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(d.title),
                trailing: Text(d.of5 == null ? 'skipped' : '${d.of5}/5', style: t.titleMedium),
              ),
            const Divider(),
            Text(
              'Average ${s.average.toStringAsFixed(1)}/5 (needs ${s.rules.average.toStringAsFixed(1)}) · '
              'lowest ${s.minimum}/5 (needs ${s.rules.minimum})',
              key: const Key('capstone-verdict'),
            ),
            Text(
              'Time ${_clock(s.seconds)}${s.rules.minutes == null ? '' : ' of ${_clock(s.rules.minutes! * 60)}'}'
              '${s.overTime ? ' (over time, noted)' : ''}',
            ),
            const SizedBox(height: 8),
            Text(streakText(_streak, s.rules), key: const Key('capstone-result-streak'), style: t.titleSmall),
            if (!s.passed && s.rules.passesInRow > 1)
              Text('A sitting that does not pass starts the count again.', style: t.bodySmall),
          ],
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: () => setState(() => _done = null),
            child: const Text('Back to the capstone'),
          ),
        ],
      ),
    ];
  }
}
