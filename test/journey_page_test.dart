// The Journey page on a phone: from the program page, the stage timeline
// with the current stage, Udyoga's suggestion, sourced lines against
// general advice, ticking an artefact, a checklist and the coverage check
// on a pasted draft; the stage packs' tools from contact to grow. A
// made-up employer, people and criteria.
import 'dart:async';
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/journey_book.dart';
import 'package:vidya/domain/offer_checker.dart';
import 'package:vidya/domain/stage_packs.dart';
import 'package:vidya/ui/journey_page.dart';

import 'app_harness.dart';

late String _pid;

Future<void> _seed(LearningBook b) async {
  final r = await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 1,
        'program': {'title': 'Prepare: Example Officer at Example Health Trust'},
        'role': 'Example Officer',
        'criteria': [
          {'id': 'e1', 'text': 'Excellent written communication', 'essential': true},
          {'id': 'e2', 'text': 'Experience of managing a diary', 'essential': true},
        ],
        'notes': [
          {'title': 'From Udyoga', 'body': 'The advert.'},
        ],
        'journey': {
          'employer': 'Example Health Trust',
          'role': 'Example Officer',
          'sector': 'nhs',
          'advertUrl': 'https://example.org/jobs/123',
          'closes': addDays(today(), 20),
          'applicationStage': 'applied',
        },
      }),
    ),
    today: today(),
  );
  _pid = r.programId;
  await b.setJourneyStage(_pid, 'apply', now: DateTime.now().toUtc().toIso8601String());
}

/// Taps [f] once scrolled to the middle of the screen, clear of the
/// page's pinned header.
Future<void> _tapMid(AppHarness app, Finder f) async {
  unawaited(Scrollable.ensureVisible(app.tester.element(f), alignment: 0.5));
  await app.tester.pump();
  await app.tester.tap(f);
  await app.settle();
}

void main() {
  testWidgets('the Journey page: timeline, suggestion, sources, artefacts and the criteria check', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await app.go('Learn');
    await app.tapText('Prepare: Example Officer at Example Health Trust');
    expect(find.byKey(const Key('journey-tile')), findsOneWidget);
    expect(find.textContaining('Stage 4 of 13: Apply'), findsOneWidget);
    expect(find.textContaining('Udyoga suggests Wait and follow up'), findsOneWidget);
    await app.tap(find.byKey(const Key('journey-tile')));
    expect(find.byType(JourneyPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The header and the timeline: every stage, the current one marked.
    expect(find.text('Example Officer at Example Health Trust'), findsOneWidget);
    expect(find.textContaining('NHS template, sources checked 21 Nov 2026'), findsOneWidget);
    for (final id in ['decide', 'apply', 'grow']) {
      expect(find.byKey(Key('journey-stage-$id')), findsOneWidget);
    }
    expect(find.text('You are here'), findsOneWidget);
    expect(find.text('Udyoga says: Applied'), findsOneWidget);

    // Apply: sourced lines with their date, advice labelled as such.
    expect(find.textContaining('Source: RCN: job applications · checked 21 Nov 2026'), findsOneWidget);
    expect(find.text('General advice'), findsWidgets);
    expect(find.text('Evidence for: Excellent written communication'), findsOneWidget);

    // Tick an artefact.
    await app.tap(find.byKey(const Key('journey-produce-Supporting statement draft')));
    var v = await tester.runAsync(() => app.book.journeyView(_pid));
    expect(v!.of('apply').produced.keys, ['Supporting statement draft']);

    // The criteria check on a pasted draft.
    await tester.ensureVisible(find.byKey(const Key('journey-draft')));
    await tester.enterText(
      find.byKey(const Key('journey-draft')),
      'My excellent written communication shows in the minutes I take.',
    );
    await tester.pump();
    expect(find.textContaining('10 words: about 5 for each essential criterion'), findsOneWidget);
    await app.tap(find.byKey(const Key('journey-check-draft')));
    expect(find.text('Uses the criterion\'s words'), findsOneWidget);
    expect(find.textContaining('Not found'), findsOneWidget);
    expect(find.text('1 of 2 essential criteria in their own words'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Take Udyoga's suggestion: Wait and follow up becomes the current stage.
    await app.tap(find.byKey(const Key('journey-suggested')));
    expect(find.text('Udyoga says: Applied'), findsNothing);
    expect(find.text('Wait and follow up'), findsWidgets);
    v = await tester.runAsync(() => app.book.journeyView(_pid));
    expect((v!.current, v.suggested), ('follow-up', null));

    // Its checklist: ticking every item does the check.
    for (final item in [
      'I know the shortlisting date, or when to ask',
      'My chase email is written',
      'I kept a copy of the advert and of what I sent',
    ]) {
      await app.tap(find.byKey(Key('journey-tick-$item')));
    }
    expect(find.textContaining('All 3 ticked'), findsOneWidget);

    // Another stage opens without moving there; its quiz is offered.
    await app.tap(find.byKey(const Key('journey-stage-offer')));
    expect(find.byKey(const Key('journey-move')), findsOneWidget);
    expect(find.byKey(const Key('journey-quiz')), findsOneWidget);
    expect(find.text('May be out of date: check the source'), findsNothing);
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('the stage packs: templates, offer checker, checks, joining, 90 days and grow', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    await app.run();
    await app.go('Learn');
    await app.tapText('Prepare: Example Officer at Example Health Trust');
    await app.tap(find.byKey(const Key('journey-tile')));

    // Contact: the informal-call template, filled from the journey; no
    // Udyoga button until Udyoga has sent a plan.
    await app.tap(find.byKey(const Key('journey-stage-contact')));
    expect(find.text('Contact templates'), findsOneWidget);
    await app.tap(find.byKey(const Key('pack-template-informal-call')));
    expect(find.textContaining('Dear Hiring Manager,'), findsWidgets);
    expect(find.textContaining('Still to fill: Your name'), findsOneWidget);
    expect(find.byKey(const Key('pack-copy-informal-call')), findsOneWidget);
    expect(find.byKey(const Key('pack-udyoga-informal-call')), findsNothing);

    // The learner's details refill it: the manager's name only once entered.
    await app.tap(find.byKey(const Key('pack-fills')));
    await app.enter('Hiring manager\'s name (only if you know it)', 'Sam Example');
    await app.enter('Your name', 'Alex Example');
    await app.tapText('Save');
    expect(find.textContaining('Dear Sam Example,'), findsWidgets);
    expect(find.textContaining('Still to fill'), findsNothing);

    // Offer: check a promotion at the bottom of Band 5.
    await app.tap(find.byKey(const Key('journey-stage-offer')));
    expect(find.text('Email templates'), findsOneWidget);
    expect(find.text(notLegalAdvice), findsOneWidget);
    await app.enter('Band or grade', 'Band 5');
    await app.enter('Pay point or step offered (1 is the bottom)', '1');
    await app.enter('Full-time salary (£ a year)', '32073');
    await tester.ensureVisible(find.byKey(const Key('offer-promotion')));
    await app.tap(find.byKey(const Key('offer-promotion')));
    await app.tap(find.byKey(const Key('offer-check')));
    expect(find.text('Normal'), findsOneWidget);
    expect(find.textContaining('as this offer does'), findsOneWidget);
    var v = await tester.runAsync(() => app.book.journeyView(_pid));
    expect(OfferFacts.fromJson(Map.from(v!.of('offer').pack['facts'] as Map)).salary, 32073);
    expect(tester.takeException(), isNull);

    // Checks: Vidya's own list for an NHS post, with the IAT note.
    await app.tap(find.byKey(const Key('journey-stage-checks')));
    expect(find.text('Your checks'), findsOneWidget);
    for (final kind in ['identity', 'references', 'criminal_record', 'health', 'iat']) {
      expect(find.byKey(Key('pack-check-$kind')), findsOneWidget);
    }
    await app.tap(find.byKey(const Key('pack-check-iat')));
    expect(find.textContaining('Say yes'), findsOneWidget);

    // Joining: a person becomes a flashcard; the training list starts.
    await app.tap(find.byKey(const Key('journey-stage-joining')));
    await app.tap(find.byKey(Key('pack-day-one-${dayOneStarter.first}')));
    await app.tap(find.byKey(const Key('pack-add-people')));
    await app.enter('Name', 'Sam Example');
    await app.enter('Role, and how you work with them', 'Ward manager');
    await app.tapText('Save');
    expect(find.text('Ward manager'), findsOneWidget);
    final cards = await tester.runAsync(() => app.book.db.select(app.book.db.learnCards).get());
    expect(cards!.single.deck, 'Who\'s who: Example Health Trust');
    await app.tap(find.byKey(const Key('pack-training-start')));
    expect(find.byKey(Key('pack-training-${trainingStarter('nhs').first}')), findsOneWidget);

    // First 90 days: a win goes to the story bank.
    await app.tap(find.byKey(const Key('journey-stage-first-90-days')));
    await tester.ensureVisible(find.byKey(const Key('pack-win')));
    await tester.enterText(find.byKey(const Key('pack-win')), 'Cleared the referral backlog in two weeks.');
    await _tapMid(app, find.byKey(const Key('pack-win-add')));
    await _tapMid(app, find.text('To story bank'));
    expect(find.text('In the story bank'), findsOneWidget);
    final bank = await tester.runAsync(() => app.book.storyBank());
    expect(bank!.single.title, 'Cleared the referral backlog in two weeks');

    // Grow: the next role gets its own readiness.
    await app.tap(find.byKey(const Key('journey-stage-grow')));
    await app.enter('Next role\'s title', 'Senior Example Officer');
    await app.enter(
      'Its criteria, one a line ("Desirable:" or "(D)" for desirable ones)',
      'Leads a small team',
    );
    await app.tap(find.byKey(const Key('pack-next-start')));
    expect(find.textContaining('Leads a small team'), findsWidgets);
    v = await tester.runAsync(() => app.book.journeyView(_pid));
    expect(v!.of('grow').pack['nextProgram'], isA<String>());
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('a role program without a journey can start one', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        _pid = await b.addProgram('Example analyst', '', today: today());
        final p = await (b.db.select(b.db.learnPrograms)..where((x) => x.id.equals(_pid))).getSingle();
        await b.save(b.db.learnPrograms, p.copyWith(role: 'Example analyst'), _pid);
      },
    );
    await app.run();
    await app.go('Learn');
    await app.tapText('Example analyst');
    await app.tap(find.byKey(const Key('journey-tile')));
    expect(find.text('Start a job journey'), findsOneWidget);
    await app.tap(find.byKey(const Key('journey-start')));
    expect(find.text('You are here'), findsOneWidget);
    expect(find.textContaining('NHS template'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
