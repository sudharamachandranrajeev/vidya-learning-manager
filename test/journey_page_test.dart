// The Journey page on a phone: from the program page, the stage timeline
// with the current stage, Udyoga's suggestion, sourced lines against
// general advice, ticking an artefact, a checklist and the coverage check
// on a pasted draft. A made-up employer and criteria.
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/journey_book.dart';
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
