/// Interview training screens (role study plan V5): the drill runner, the
/// story bank, the "before the interview" session and the feedback log
/// after a real interview. The rules live in domain/interview.dart.
library;

import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../db/database.dart';
import '../domain/interview.dart';
import '../domain/study_items.dart';
import 'common.dart';
import 'interview_debrief_page.dart' show PastRounds;
import 'spoken_interview_page.dart';
import 'zen.dart';

/// Said on the self-rated drill: it records nothing.
const noRecordingNote =
    'This timer records nothing. Say your answer out loud anyway. To be asked aloud and have your answer '
    'written down, use the interviewer below.';

/// Said on the story bank and the feedback log.
const interviewPrivacyNote =
    'Your stories, scores and feedback stay on this device, or travel only through your own sync. '
    'Nothing is sent anywhere else. You can delete any of them.';

Future<void> openDrill(BuildContext context, String itemId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DrillPage(itemId)));

Future<void> openStoryBank(BuildContext context, {String? programId}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoryBankPage(programId: programId)));

Future<void> openBeforeInterview(BuildContext context, String programId) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => BeforeInterviewPage(programId)));

// ---- drill runner ----

/// Everything the drill runner shows, read in one go.
typedef DrillView = ({
  StudyItem item,
  Topic? topic,
  List<Criterion> criteria,
  DrillEvidence evidence,
  List<Assessment> attempts,
  List<Story> stories,
});

final drillViewProvider = FutureProvider.family<DrillView?, String>((ref, id) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final item = await (db.select(
    db.learnItems,
  )..where((i) => i.id.equals(id) & i.deleted.not())).getSingleOrNull();
  if (item == null) return null;
  final topic = await (db.select(db.learnTopics)..where((t) => t.id.equals(item.topicId))).getSingleOrNull();
  final course = topic == null
      ? null
      : await (db.select(db.learnCourses)..where((c) => c.id.equals(topic.courseId))).getSingleOrNull();
  final pid = course?.programId;
  return (
    item: item,
    topic: topic,
    criteria: pid == null ? const <Criterion>[] : await book.programCriteria(pid),
    evidence: (await book.drillEvidence([id]))[id] ?? const DrillEvidence(),
    attempts: await book.drillAttempts(id),
    stories: await book.storyBank(),
  );
});

String _secondsText(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

String _score(num s) => s % 1 == 0 ? '${s.toInt()}' : s.toStringAsFixed(1);

/// A drill's practice so far, in a line: last score here, Udyoga's score,
/// and the weak flag.
String drillEvidenceText(DrillEvidence e) => [
  if (e.own != null) 'Last here ${e.own}/$drillMax (${niceDate(e.ownDay)})',
  if (e.own != null && e.ownNote.isNotEmpty) e.ownNote,
  if (e.udyoga case final u?) 'Udyoga ${u.text} (${niceDate(u.day)})',
  if (e.asked && e.udyoga == null) 'sent to Udyoga',
  if (!e.practised && !e.asked) 'not practised yet',
  if (e.weak) 'weak: comes first before the interview',
].join(' · ');

/// Practise one drill: the question and what it tests, a timer, answer
/// out loud, then rate yourself on four checks (0–2 each). Scenario
/// questions get the guided frame. The score is saved on the topic and the
/// drill; under 5 of 8 flags it for the "before the interview" session.
class DrillPage extends ConsumerStatefulWidget {
  const DrillPage(this.itemId, {super.key});
  final String itemId;

  @override
  ConsumerState<DrillPage> createState() => _DrillPageState();
}

class _DrillPageState extends ConsumerState<DrillPage> {
  var _length = drillDefaultSeconds;
  var _left = drillDefaultSeconds;
  Timer? _timer;
  final _checks = List<int?>.filled(drillChecks.length, null);
  final _frame = {for (final (k, _) in ScenarioFrame.parts) k: TextEditingController()};
  final _note = TextEditingController();
  bool? _useFrame;
  String _story = '';
  var _saving = false;

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _frame.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    if (_left <= 0) _left = _length;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _left--;
        if (_left <= 0) {
          _left = 0;
          t.cancel();
          _timer = null;
        }
      });
    });
    setState(() {});
  }

  void _pause() => setState(() {
    _timer?.cancel();
    _timer = null;
  });

  void _reset() => setState(() {
    _timer?.cancel();
    _timer = null;
    _left = _length;
  });

  void _adjust(int by) => setState(() {
    _length = (_length + by).clamp(30, 600);
    if (_timer == null) _left = _length;
  });

  Future<void> _save(DrillView v) async {
    if (_checks.any((c) => c == null)) {
      notify(context, 'Rate all four checks first.');
      return;
    }
    setState(() => _saving = true);
    final frame = _useFrame ?? isScenarioDrill(v.item)
        ? ScenarioFrame(
            check: _frame['check']!.text,
            scope: _frame['scope']!.text,
            escalate: _frame['escalate']!.text,
            handover: _frame['handover']!.text,
          )
        : const ScenarioFrame();
    final attempt = DrillAttempt(
      checks: [for (final c in _checks) c!],
      seconds: _length - _left,
      frame: frame,
      story: _story,
      note: _note.text,
    );
    await ref.mutate((s) async {
      await s.book.recordDrill(v.item, attempt, today: today());
      // Using a story on a drill links the two.
      final story = v.stories.where((x) => x.id == _story).firstOrNull;
      if (story != null && !story.drills.contains(v.item.id)) {
        await s.book.linkStory(story, drills: [...story.drills, v.item.id], today: today());
      }
    });
    if (!mounted) return;
    setState(() {
      _saving = false;
      _checks.fillRange(0, _checks.length, null);
      _note.clear();
      _left = _length;
    });
    notify(
      context,
      attempt.weak
          ? 'Saved: ${attempt.score}/$drillMax. Flagged weak, so it comes first before the interview.'
          : 'Saved: ${attempt.score}/$drillMax.',
    );
  }

  Future<void> _udyoga(StudyItem drill) async {
    await ref.mutate((s) => s.book.askUdyogaToPractise(drill, now: DateTime.now().toUtc().toIso8601String()));
    if (mounted) {
      notify(
        context,
        'Sent to Udyoga. Its interview simulator can pick it up when both apps sync with the same account; '
        'its score shows here when it comes back.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(drillViewProvider(widget.itemId)),
      builder: (v) {
        if (v == null) return const Scaffold(body: Center(child: Text('This drill was deleted.')));
        return Scaffold(
          appBar: AppBar(title: const Text('Practise a drill')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _body(context, v)),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  List<Widget> _body(BuildContext context, DrillView v) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final criterion = drillCriterionText(v.item, v.criteria);
    final rubric = itemContent(v.item)['rubric'];
    final scenario = _useFrame ?? isScenarioDrill(v.item);
    final linked = [
      for (final s in v.stories)
        if (s.drills.contains(v.item.id)) s,
    ];
    final others = [
      for (final s in v.stories)
        if (!s.drills.contains(v.item.id)) s,
    ];
    final score = _checks.every((c) => c != null) ? drillScore([for (final c in _checks) c!]) : null;
    return [
      if (v.topic != null) Text(v.topic!.title, style: text.labelLarge),
      const SizedBox(height: 4),
      Text(drillQuestion(v.item), style: text.titleLarge),
      const SizedBox(height: 8),
      Text(
        criterion.isEmpty ? 'Not tagged with a criterion yet.' : 'Tests: $criterion',
        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      if (rubric is String && rubric.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text('What a good answer covers: $rubric', style: text.bodyMedium),
      ],
      const SizedBox(height: 4),
      Text(
        drillEvidenceText(v.evidence),
        style: text.bodySmall?.copyWith(color: v.evidence.weak ? scheme.error : null),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Answer out loud',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                _secondsText(_left),
                key: const Key('drill-timer'),
                style: text.displaySmall?.copyWith(color: _left == 0 ? scheme.error : null),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                IconButton(
                  tooltip: '30 seconds less',
                  icon: const Icon(Icons.remove),
                  onPressed: () => _adjust(-30),
                ),
                if (_timer == null)
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_left == _length ? 'Start' : 'Go on'),
                    onPressed: _start,
                  )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                    onPressed: _pause,
                  ),
                TextButton(onPressed: _reset, child: const Text('Reset')),
                IconButton(
                  tooltip: '30 seconds more',
                  icon: const Icon(Icons.add),
                  onPressed: () => _adjust(30),
                ),
              ],
            ),
            Text(
              'About ${_length ~/ 60 > 0 ? '${_length ~/ 60} min' : ''}${_length % 60 > 0 ? ' ${_length % 60} s' : ''}. '
              'Speak as you would to the panel, then rate yourself below.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(noRecordingNote, style: text.bodySmall),
          ],
        ),
      ),
      SectionCard(
        title: 'Scenario frame',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use the scenario frame'),
              subtitle: const Text(
                'For "what would you do" questions: check, stay in scope, escalate, hand over.',
              ),
              value: scenario,
              onChanged: (on) => setState(() => _useFrame = on),
            ),
            if (scenario)
              for (final (k, label) in ScenarioFrame.parts) Field(_frame[k]!, label, lines: 2),
          ],
        ),
      ),
      SectionCard(
        title: 'Rate yourself',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (k, (_, label, help)) in drillChecks.indexed) ...[
              Text(label, style: text.titleSmall),
              Text(help, style: text.bodySmall),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                key: Key('check-$k'),
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
            if (v.stories.isNotEmpty)
              Choice<String>(
                label: 'Story you used (optional)',
                value: _story,
                options: {
                  '': 'None',
                  for (final s in [...linked, ...others]) s.id: s.title,
                },
                onChanged: (s) => setState(() => _story = s),
              ),
            Field(_note, 'Note to self (optional)', lines: 2),
            Text(
              score == null
                  ? 'Score: rate all four checks.'
                  : 'Score: $score/$drillMax${drillWeak(score) ? ' (weak, under $drillWeakBelow)' : ''}',
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save this attempt'),
              onPressed: _saving ? null : () => _save(v),
            ),
          ],
        ),
      ),
      SectionCard(
        title: 'Practise with the interviewer',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The interviewer asks this drill aloud, follows up on what your answer leaves out and writes it '
              'down on this device. Type instead if you prefer. With an AI connected it also scores your words '
              'against the criterion on a real panel scale.',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('Practise with the interviewer'),
                onPressed: () => openSpokenInterview(context, itemId: v.item.id),
              ),
            ),
          ],
        ),
      ),
      SectionCard(
        title: 'Practise in Udyoga (optional)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Hand this drill to Udyoga\'s voice simulator, which asks it aloud and scores your answer. '
              'Its score comes back here through your own sync.',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.record_voice_over_outlined),
                label: Text(v.evidence.asked ? 'Send to Udyoga again' : 'Practise in Udyoga'),
                onPressed: () => _udyoga(v.item),
              ),
            ),
          ],
        ),
      ),
      if (v.attempts.isNotEmpty)
        SectionCard(
          title: 'Past attempts',
          child: Column(children: [for (final a in v.attempts) _AttemptTile(a)]),
        ),
    ];
  }
}

class _AttemptTile extends ConsumerWidget {
  const _AttemptTile(this.a);
  final Assessment a;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = DrillAttempt.parse(a.detail);
    final lines = [
      if (d != null && d.seconds > 0) 'Spoke for ${_secondsText(d.seconds)}',
      if (d != null && !d.frame.isEmpty)
        for (final (k, label) in ScenarioFrame.parts)
          if (d.frame.part(k).trim().isNotEmpty) '$label: ${d.frame.part(k).trim()}',
      if (d != null && d.note.isNotEmpty) 'Note: ${d.note}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${_score(a.score)}/${_score(a.max)} · ${niceDate(a.day)}${drillWeak(a.score) ? ' · weak' : ''}',
      ),
      subtitle: lines.isEmpty ? null : Text(lines.join('\n')),
      trailing: IconButton(
        tooltip: 'Delete attempt',
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          if (await askSure(context, 'Delete this attempt?', 'Its score and notes are deleted.') &&
              context.mounted) {
            await ref.mutate((s) => s.book.remove(s.db.learnAssessments, a.id));
          }
        },
      ),
    );
  }
}

/// Adds the learner's own drill to a topic: the question, and what it
/// tests (one of the program's criteria, or words).
Future<void> addDrillDialog(
  BuildContext context,
  WidgetRef ref,
  String topicId,
  List<Criterion> criteria,
) async {
  final question = TextEditingController();
  final words = TextEditingController();
  var picked = '';
  var scenario = false;
  await showFormDialog(
    context,
    title: 'Add an interview drill',
    fields: (setState) => [
      Field(question, 'Question', lines: 2, autofocus: true, hint: 'Tell me about a time you…'),
      if (criteria.isNotEmpty)
        Choice<String>(
          label: 'What it tests',
          value: picked,
          options: {'': 'Something else (type below)', for (final c in criteria) c.ref: c.body},
          onChanged: (v) => setState(() => picked = v),
        ),
      if (picked.isEmpty) Field(words, 'What it tests (optional)', hint: 'Teamwork, a value, a skill'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Scenario question'),
        subtitle: const Text('Offers the check / scope / escalate / hand over frame.'),
        value: scenario || isScenarioQuestion(question.text),
        onChanged: (v) => setState(() => scenario = v),
      ),
    ],
    onSave: () async {
      if (question.text.trim().isEmpty) return 'Write the question first.';
      await ref.mutate(
        (s) => s.book.addDrill(
          topicId,
          question.text,
          criterion: picked.isNotEmpty ? picked : words.text,
          scenario: scenario || isScenarioQuestion(question.text) ? true : null,
        ),
      );
      return null;
    },
  );
}

// ---- story bank ----

/// The story bank's rows: stories, and the criteria and drills they can be
/// linked to (one program's, or everyone's).
typedef StoryBankView = ({List<Story> stories, List<Criterion> criteria, List<StudyItem> drills});

final storyBankProvider = FutureProvider.family<StoryBankView, String?>((ref, programId) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final criteria = programId != null
      ? await book.programCriteria(programId)
      : await (db.select(db.learnCriteria)
              ..where((c) => c.deleted.not())
              ..orderBy([(c) => OrderingTerm.asc(c.programId), (c) => OrderingTerm.asc(c.ord)]))
            .get();
  var drills =
      await (db.select(db.learnItems)
            ..where((i) => i.deleted.not() & i.type.equals('interview drill') & i.retired.equals(''))
            ..orderBy([(i) => OrderingTerm.asc(i.topicId), (i) => OrderingTerm.asc(i.ord)]))
          .get();
  if (programId != null) {
    drills = (await book.programDrills(programId)).drills;
  }
  return (stories: await book.storyBank(), criteria: criteria, drills: drills);
});

/// Stories in one place: Udyoga's story cards and your own, each shown as
/// STAR (Situation, Task, Action, Result) or CAR (Context, Action, Result)
/// from the same text, with the criteria and drills it is linked to.
class StoryBankPage extends ConsumerStatefulWidget {
  const StoryBankPage({super.key, this.programId});

  /// Limits the criteria and drills offered for links to one program.
  final String? programId;

  @override
  ConsumerState<StoryBankPage> createState() => _StoryBankPageState();
}

class _StoryBankPageState extends ConsumerState<StoryBankPage> {
  var _car = false;

  @override
  Widget build(BuildContext context) => Backdrop(
    child: AsyncView(
      ref.watch(storyBankProvider(widget.programId)),
      builder: (v) => Scaffold(
        appBar: AppBar(title: const Text('Story bank')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => storyDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Story'),
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
                      'Ten to fifteen true stories from your own work cover most interviews. Say each one aloud '
                      'in about two minutes. STAR and CAR are the same story told two ways.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('STAR')),
                        ButtonSegment(value: true, label: Text('CAR')),
                      ],
                      selected: {_car},
                      onSelectionChanged: (s) => setState(() => _car = s.first),
                    ),
                    const SizedBox(height: 12),
                    if (v.stories.isEmpty)
                      const Text(
                        'No stories yet. Add your own, or send your story bank from Udyoga: its stories show here.',
                      ),
                    for (final s in v.stories) _StoryCard(s, v, car: _car),
                    const SizedBox(height: 8),
                    Text(interviewPrivacyNote, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StoryCard extends ConsumerWidget {
  const _StoryCard(this.s, this.v, {required this.car});
  final Story s;
  final StoryBankView v;
  final bool car;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final criteria = [
      for (final c in v.criteria)
        if (s.criteria.contains(c.id)) c.body,
    ];
    final drills = [
      for (final d in v.drills)
        if (s.drills.contains(d.id)) d.title,
    ];
    return SectionCard(
      title: s.title,
      trailing: PopupMenuButton<String>(
        tooltip: 'Story actions',
        onSelected: (k) async {
          switch (k) {
            case 'edit':
              await storyDialog(context, ref, story: s);
            case 'link':
              await linkStoryDialog(context, ref, s, v);
            case 'delete':
              if (await askSure(
                    context,
                    s.fromUdyoga ? 'Remove links?' : 'Delete story?',
                    s.fromUdyoga
                        ? 'The story stays (it belongs to Udyoga); its links to criteria and drills are removed.'
                        : s.title,
                    action: s.fromUdyoga ? 'Remove' : 'Delete',
                  ) &&
                  context.mounted) {
                await ref.mutate((x) => x.book.deleteStory(s));
              }
          }
        },
        itemBuilder: (_) => [
          if (!s.fromUdyoga) const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(value: 'link', child: Text('Link to criteria and drills')),
          PopupMenuItem(value: 'delete', child: Text(s.fromUdyoga ? 'Remove links' : 'Delete')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.fromUdyoga ? 'From Udyoga (edit it there)' : 'Yours', style: text.labelMedium),
          const SizedBox(height: 4),
          for (final (label, body) in car ? s.car : s.star)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$label: ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: body),
                  ],
                ),
              ),
            ),
          if (criteria.isNotEmpty) Text('Shows: ${criteria.join('; ')}', style: text.bodySmall),
          if (drills.isNotEmpty) Text('Answers: ${drills.join('; ')}', style: text.bodySmall),
          if (criteria.isEmpty && drills.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Link to criteria and drills'),
                onPressed: () => linkStoryDialog(context, ref, s, v),
              ),
            ),
        ],
      ),
    );
  }
}

/// Writes or edits one of your own stories, in four parts.
Future<void> storyDialog(BuildContext context, WidgetRef ref, {Story? story}) async {
  final title = TextEditingController(text: story?.title);
  final parts = {
    'Situation': TextEditingController(text: story?.situation),
    'Task': TextEditingController(text: story?.task),
    'Action': TextEditingController(text: story?.action),
    'Result': TextEditingController(text: story?.result),
  };
  await showFormDialog(
    context,
    title: story == null ? 'New story' : 'Edit story',
    fields: (_) => [
      Field(title, 'Title', autofocus: story == null, hint: 'The night the rota fell apart'),
      Field(parts['Situation']!, 'Situation', lines: 2, hint: 'Where you were and what was at stake'),
      Field(parts['Task']!, 'Task', lines: 2, hint: 'What you had to do'),
      Field(parts['Action']!, 'Action', lines: 3, hint: 'What you did, in the first person'),
      Field(parts['Result']!, 'Result', lines: 2, hint: 'What changed, with a number if you can'),
      Text(
        'CAR uses the same text: its Context is the situation and task together.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
    onSave: () async {
      if (title.text.trim().isEmpty) return 'Give the story a title.';
      if (parts['Action']!.text.trim().isEmpty) return 'Say what you did (the Action).';
      await ref.mutate(
        (s) => s.book.saveStory(
          id: story?.id,
          title: title.text,
          situation: parts['Situation']!.text,
          task: parts['Task']!.text,
          action: parts['Action']!.text,
          result: parts['Result']!.text,
          criteria: story?.criteria ?? const [],
          drills: story?.drills ?? const [],
          today: today(),
        ),
      );
      return null;
    },
  );
}

/// Picks the criteria a story shows and the drills it answers.
Future<void> linkStoryDialog(BuildContext context, WidgetRef ref, Story s, StoryBankView v) async {
  final criteria = {...s.criteria};
  final drills = {...s.drills};
  await showFormDialog(
    context,
    title: 'Link "${s.title}"',
    fields: (setState) => [
      Text('Criteria it shows', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      if (v.criteria.isEmpty) const Text('No criteria yet. Plans from Udyoga bring the role\'s criteria.'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in v.criteria)
            FilterChip(
              label: Text(c.body, overflow: TextOverflow.ellipsis),
              selected: criteria.contains(c.id),
              onSelected: (on) => setState(() => on ? criteria.add(c.id) : criteria.remove(c.id)),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text('Drills it answers', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      if (v.drills.isEmpty) const Text('No interview drills yet.'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final d in v.drills)
            FilterChip(
              label: Text(d.title, overflow: TextOverflow.ellipsis),
              selected: drills.contains(d.id),
              onSelected: (on) => setState(() => on ? drills.add(d.id) : drills.remove(d.id)),
            ),
        ],
      ),
    ],
    onSave: () async {
      await ref.mutate(
        (x) => x.book.linkStory(s, criteria: criteria.toList(), drills: drills.toList(), today: today()),
      );
      return null;
    },
  );
}

// ---- before the interview ----

final beforeInterviewProvider = FutureProvider.family<({Program program, BeforeInterview plan})?, String>((
  ref,
  id,
) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  final db = book.db;
  final p = await (db.select(
    db.learnPrograms,
  )..where((x) => x.id.equals(id) & x.deleted.not())).getSingleOrNull();
  if (p == null) return null;
  return (program: p, plan: await book.beforeInterview(id));
});

/// One program's review before an interview: the weak criteria first, then
/// the stories linked to them, then the drills, with the interview day's
/// countdown. After the interview, log how it went.
class BeforeInterviewPage extends ConsumerWidget {
  const BeforeInterviewPage(this.programId, {super.key});
  final String programId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Backdrop(
    child: AsyncView(
      ref.watch(beforeInterviewProvider(programId)),
      builder: (v) {
        if (v == null) return const Scaffold(body: Center(child: Text('This program was deleted.')));
        final plan = v.plan;
        final text = Theme.of(context).textTheme;
        final day = ref.watch(todayProvider);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Before the interview'),
            actions: [
              IconButton(
                tooltip: 'Story bank',
                icon: const Icon(Icons.menu_book_outlined),
                onPressed: () => openStoryBank(context, programId: programId),
              ),
            ],
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        v.program.role.isNotEmpty ? v.program.role : v.program.title,
                        style: text.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      DatePick(
                        label: 'Interview date',
                        value: plan.interviewDate,
                        onChanged: (d) => ref.mutate((s) => s.book.setInterviewDate(programId, d)),
                      ),
                      if (plan.interviewDate != null)
                        Text(interviewCountdown(plan.interviewDate!, day), style: text.titleMedium),
                      const SizedBox(height: 12),
                      SectionCard(
                        title: 'Mock interview',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Your weak drills, asked aloud by the interviewer, with follow-ups and a debrief. '
                              'Results go back to the drills below.',
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                icon: const Icon(Icons.record_voice_over_outlined),
                                label: const Text('Start a mock interview'),
                                onPressed: () => openSpokenInterview(context, programId: programId),
                              ),
                            ),
                            PastRounds(programId: programId),
                          ],
                        ),
                      ),
                      SectionCard(
                        title: '1. Weak criteria',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (plan.weak.isEmpty)
                              Text(
                                plan.covered.isEmpty
                                    ? 'No criteria yet. Plans from Udyoga bring the role\'s criteria.'
                                    : 'Every criterion is covered, as Job readiness counts it.',
                              ),
                            for (final c in plan.weak)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  c.state == CriterionState.missing
                                      ? Icons.radio_button_unchecked
                                      : Icons.error_outline,
                                ),
                                title: Text(c.criterion.body),
                                subtitle: Text(
                                  [
                                    c.criterion.essential ? 'Essential' : 'Desirable',
                                    c.state.label,
                                    ...c.reasons.map((r) => r.label),
                                    ...c.evidence,
                                  ].join(' · '),
                                ),
                              ),
                          ],
                        ),
                      ),
                      SectionCard(
                        title: '2. Stories for them',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (plan.stories.isEmpty)
                              const Text(
                                'No stories linked to these criteria yet. Link one in the story bank.',
                              ),
                            for (final s in plan.stories)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.auto_stories_outlined),
                                title: Text(s.title),
                                subtitle: Text(
                                  s.car.map((p) => '${p.$1}: ${p.$2}').join('\n'),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => openStoryBank(context, programId: programId),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                icon: const Icon(Icons.menu_book_outlined),
                                label: const Text('Open the story bank'),
                                onPressed: () => openStoryBank(context, programId: programId),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SectionCard(
                        title: '3. Drills',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (plan.drills.isEmpty) const Text('No interview drills in this program yet.'),
                            for (final d in plan.drills)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  d.evidence.weak ? Icons.flag : Icons.record_voice_over_outlined,
                                  color: d.evidence.weak ? Theme.of(context).colorScheme.error : null,
                                ),
                                title: Text(d.item.title),
                                subtitle: Text(
                                  [
                                    if (d.criterion != null) 'tests ${d.criterion!.body}',
                                    drillEvidenceText(d.evidence),
                                  ].join(' · '),
                                ),
                                onTap: () => openDrill(context, d.item.id),
                              ),
                          ],
                        ),
                      ),
                      if (plan.covered.isNotEmpty)
                        SectionCard(
                          title: 'Covered',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final c in plan.covered)
                                Text('• ${c.criterion.body} (${c.evidence.join('; ')})'),
                            ],
                          ),
                        ),
                      SectionCard(
                        title: 'After the interview',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Write down which questions or criteria went badly while you remember. Each one '
                              'becomes a drill to practise, and the log goes in your Notes.',
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.edit_note),
                                label: const Text('Log a real interview'),
                                onPressed: () =>
                                    Navigator.of(context)
                                        .push(MaterialPageRoute(builder: (_) => FeedbackPage(programId))),
                              ),
                            ),
                          ],
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

// ---- after a real interview ----

final _criteriaProvider = FutureProvider.family<List<Criterion>, String>((ref, programId) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.programCriteria(programId);
});

/// The feedback log after a real interview: the day, the employer and role,
/// which criteria and questions went badly, and notes. Saved as a note
/// (synced like any note, nowhere else); each weak spot becomes a drill.
class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage(this.programId, {super.key});
  final String programId;

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<FeedbackPage> {
  String _day = today();
  final _role = TextEditingController();
  final _questions = TextEditingController();
  final _notes = TextEditingController();
  final _bad = <String>{};
  var _saving = false;

  @override
  void dispose() {
    _role.dispose();
    _questions.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final r = await ref.mutate(
      (s) => s.book.logInterviewFeedback(
        widget.programId,
        InterviewFeedback(
          day: _day,
          role: _role.text,
          criteria: _bad.toList(),
          questions: _questions.text.split('\n'),
          notes: _notes.text,
        ),
        today: today(),
      ),
    );
    if (!mounted) return;
    notify(
      context,
      'Saved in Notes. ${r.items.isEmpty ? 'No follow-ups added.' : '${r.items.length} follow-up ${r.items.length == 1 ? 'drill' : 'drills'} added.'}',
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Backdrop(
    child: Scaffold(
      appBar: AppBar(title: const Text('Log a real interview')),
      body: AsyncView(
        ref.watch(_criteriaProvider(widget.programId)),
        builder: (criteria) => ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DatePick(
                      label: 'Interview date',
                      value: _day,
                      onChanged: (d) => setState(() => _day = d ?? today()),
                    ),
                    Field(_role, 'Employer and role', hint: 'Example Trust, Band 5 trainer'),
                    if (criteria.isNotEmpty) ...[
                      Text('Criteria that went badly', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in criteria)
                            FilterChip(
                              label: Text(c.body, overflow: TextOverflow.ellipsis),
                              selected: _bad.contains(c.id),
                              onSelected: (on) => setState(() => on ? _bad.add(c.id) : _bad.remove(c.id)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    Field(_questions, 'Questions that went badly (one per line)', lines: 3),
                    Field(_notes, 'Notes', lines: 3, hint: 'What the panel said, what to change next time'),
                    Text(interviewPrivacyNote, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save the log'),
                      onPressed: _saving ? null : _save,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
