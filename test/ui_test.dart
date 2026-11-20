import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vidya/app/app.dart';
import 'package:vidya/app/modules.dart';
import 'package:vidya/app/providers.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/udyoga_link.dart';

import 'app_harness.dart';
import 'seed.dart';

/// Smoke tests: every page builds, with and without data, on phone and
/// desktop widths, without throwing or overflowing; and the main flows.
void main() {
  final pages = [for (final d in allDestinations) d.label];

  testWidgets('every page builds on a desktop window, empty and with data', (tester) async {
    for (final seeded in [false, true]) {
      final app = AppHarness(tester)..desktop();
      await app.open(seed: seeded ? seedBook : null);
      await app.run();
      for (final label in pages) {
        await app.go(label);
        expect(tester.takeException(), isNull, reason: '$label (seeded: $seeded)');
      }
      await app.close();
    }
  });

  testWidgets('every page builds on a phone', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: seedBook);
    await app.run();
    for (final label in pages) {
      await app.go(label);
      expect(tester.takeException(), isNull, reason: label);
    }
    await app.close();
  });

  testWidgets('starting from a template, finishing a topic earns an achievement', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open();
    await app.run();
    await app.go('Learn');
    await app.tapText('Use a template');
    await app.tapText('Software engineer');
    expect(find.text('Software engineer'), findsOneWidget);
    await app.tapText('Software engineer');
    await app.tapText('Programming fundamentals');
    await app.tap(find.byType(Checkbox).first);
    expect(find.textContaining('Achievement earned: First step'), findsOneWidget);
    await app.close();
  });

  testWidgets('a plan from Udyoga shows interview readiness and rehearses only the stories', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        final plan = parseCurriculum(File('test/fixtures/udyoga-plan.json').readAsStringSync());
        await b.importCurriculum(plan, today: today());
        await b.saveCard('Other deck', 'x', today: today());
      },
    );
    await app.run();
    expect(find.text('Interview readiness'), findsOneWidget);
    await app.tapText('Rehearse 1');
    expect(find.textContaining('Tell your story: Fixture story'), findsOneWidget);
    expect(find.text('Other deck'), findsNothing);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a pasted AI reply previews and imports as a program', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open();
    await app.run();
    await app.go('Learn');
    await app.tapText('Import a plan');
    expect(find.text('Copy AI prompt'), findsOneWidget);
    await app.enter('AI reply', 'not a plan');
    expect(find.textContaining('No plan found'), findsOneWidget);
    await app.enter(
      'AI reply',
      'Here you go:\n```json\n{"format": "vidya-curriculum", "version": 1, '
          '"program": {"title": "Pottery", "goal": "Throw a bowl"}, '
          '"courses": [{"title": "Wheel basics", "dueWeek": 2, "topics": [{"title": "Centering", "details": "Brace your arms."}]}], '
          '"cards": [{"course": "Wheel basics", "front": "First step on the wheel?", "back": "Centering"}]}\n```',
    );
    expect(find.text('1 courses · 1 topics · 1 cards · 0 skills · 0 notes'), findsOneWidget);
    await app.tapText('Import');
    expect(find.text('Pottery'), findsOneWidget);
    expect(find.text('0 of 1 courses'), findsOneWidget);
    // The topic's details became a study-guide note.
    expect(find.textContaining('Achievement earned: First note'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('the connected AI writes a plan in two parts, which import as one program', (tester) async {
    final asked = <List<HelpTurn>>[];
    String part(int k, String course) =>
        '{"format": "vidya-curriculum", "version": 1, "part": "$k of 2", '
        '"program": {"title": "Pottery"}, "courses": [{"title": "$course", "topics": [{"title": "T$k"}]}]}';
    final app = AppHarness(tester)..desktop();
    await app.open(
      seed: (b) =>
          b.db.setLocalSetting('ai.help', jsonEncode(const HelpAiSetup(via: HelpAi.openai).toJson())),
    );
    await app.run(
      overrides: [
        helpAskerProvider.overrideWithValue(
          (setup) async => _FakeAsker(setup, (turns) {
            asked.add([...turns]);
            return asked.length == 1 ? 'Sure!\n${part(1, 'Wheel')}' : part(2, 'Glazing');
          }),
        ),
      ],
    );
    await app.go('Learn');
    await app.tapText('Import a plan');
    await app.tapText('Make it with AI');
    expect(find.text('Written by: ${HelpAi.openai.label}'), findsOneWidget);
    await app.tapText('Write the plan');
    expect(find.text('Say what the plan is for first.'), findsOneWidget);
    await app.enter('What the plan is for', 'Throw a bowl');
    await app.tapText('Write the plan');
    expect(asked, hasLength(2));
    expect(asked.first.single.text, contains('- Goal, exam or qualification: Throw a bowl'));
    expect(asked.last.last.text, 'next part');
    expect(find.text('2 parts · 2 courses · 2 topics · 0 cards · 0 skills · 0 notes'), findsOneWidget);
    await app.tapText('Import');
    expect(find.text('Pottery'), findsOneWidget);
    expect(find.text('0 of 2 courses'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a new card is reviewed and the queue clears', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open();
    await app.run();
    await app.go('Review');
    await app.tapText('Card');
    await app.enter('Front: the question', 'Capital of Japan?');
    await app.enter('Back: the answer', 'Tokyo');
    await app.tapText('Save');
    expect(find.text('1 card due'), findsOneWidget);
    await app.tapText('Begin review');
    await app.tapText('Show answer');
    expect(find.text('Tokyo'), findsOneWidget);
    await app.tapText('Good');
    expect(find.text('All clear.'), findsOneWidget);
    expect(find.textContaining('Achievement earned: First recall'), findsOneWidget);
    await app.tapText('Done');
    expect(find.text('Nothing due'), findsOneWidget);
    await app.close();
  });

  testWidgets('a review session reports to Udyoga when it ends, not on each grade', (tester) async {
    final app = AppHarness(tester)..desktop();
    const planId = 'udyoga.interview-drills';
    await app.open(
      seed: (book) async {
        await book.db
            .into(book.db.bridgeStudyPlans)
            .insert(
              BridgeStudyPlansCompanion.insert(
                id: planId,
                source: 'udyoga',
                plan: File('test/fixtures/udyoga-drills.json').readAsStringSync(),
                updated: '2026-11-19T09:00:00Z',
              ),
            );
        await book.addOfferedPlan((await book.offeredPlans()).single, today: today(), now: 'N1');
      },
    );
    // No gap, so each request reports at once and the test sees when.
    await app.run(
      overrides: [
        progressReporterProvider.overrideWith(
          (ref) => ProgressReporter((now) => app.book.reportToUdyoga(now: now), gap: Duration.zero),
        ),
      ],
    );
    Future<String> sent() => tester
        .runAsync(
          () async => (await (app.session.db.select(
            app.session.db.bridgeStudyProgress,
          )..where((p) => p.id.equals(planId))).getSingle()).progress,
        )
        .then((p) => p!);

    await app.go('Review');
    await app.tapText('Begin review');
    await app.tapText('Show answer');
    await app.tapText('Good');
    expect(await sent(), isNot(contains('drills')), reason: 'a grade alone does not report');
    await app.tester.pageBack();
    await app.settle();
    expect(await sent(), contains('"drills"'), reason: 'the session ended');
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a study plan Udyoga sent through sync is offered on Home and added in one tap', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    await app.open(
      seed: (book) => book.db
          .into(book.db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(
              id: 'udyoga.study-plan',
              source: 'udyoga',
              plan: File('test/fixtures/udyoga-plan.json').readAsStringSync(),
              updated: '2026-11-16T09:00:00Z',
            ),
          ),
    );
    await app.run();
    expect(find.text('A study plan from Udyoga'), findsOneWidget);
    await app.tapText('Add to Vidya');
    expect(find.text('A study plan from Udyoga'), findsNothing);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a plan from the career file is offered as such; with auto-add on it goes in by itself', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    final plan = jsonEncode({
      'format': 'vidya-curriculum',
      'version': 1,
      'program': {'title': 'Example readiness', 'goal': 'Be ready'},
      'courses': [
        {'title': 'Example course', 'kind': 'course', 'topics': []},
      ],
    });
    await app.open(
      seed: (book) => book.db
          .into(book.db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(
              id: '${careerFilePlanPrefix}vidya-example',
              source: 'udyoga',
              plan: plan,
              updated: '2026-11-20T09:00:00Z',
            ),
          ),
    );
    await app.run();
    expect(find.text('A study plan from your career file'), findsOneWidget);
    await app.go('Settings');
    expect(find.text('Plans from your career file'), findsOneWidget);
    // Turning it on is a write: the plan waiting is added at once.
    await app.tapText('Add them automatically');
    await app.go('Home');
    await app.settle();
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && (await app.book.offeredPlans()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await app.settle();
    expect(find.text('A study plan from your career file'), findsNothing);
    final programs = await tester.runAsync(() => app.session.db.select(app.session.db.learnPrograms).get());
    expect(programs!.map((p) => p.title), contains('Example readiness'));
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('the focus timer opens from Home and can be paused', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open();
    await app.run();
    await app.tap(find.byIcon(Icons.self_improvement).first);
    expect(find.text('25:00'), findsOneWidget);
    await app.tapText('15 min');
    expect(find.text('15:00'), findsOneWidget);
    await app.tapText('Begin');
    await app.tapText('Pause');
    expect(find.text('paused'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('streaks are hidden until switched on in Settings', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open(seed: seedBook);
    await app.run();
    await app.go('Home');
    expect(find.text('day streak'), findsNothing);
    await app.go('Progress');
    expect(find.text('Streak'), findsNothing);
    // What the Settings switch does.
    final scope = ProviderScope.containerOf(tester.element(find.byType(VidyaApp)));
    await tester.runAsync(() => scope.read(showStreaksProvider.notifier).set(true));
    await app.settle();
    await app.go('Home');
    expect(find.text('day streak'), findsOneWidget);
    await app.go('Progress');
    expect(find.text('Streak'), findsOneWidget);
    await app.close();
  });
}

/// Answers from [reply] instead of a network AI.
class _FakeAsker extends HelpAsker {
  _FakeAsker(super.setup, this.reply);
  final String Function(List<HelpTurn> turns) reply;

  @override
  Future<String> ask(String system, List<HelpTurn> turns) async => reply(turns);
}
