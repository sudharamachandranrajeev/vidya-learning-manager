// The framework self-assessment page (assess plan A6) at large text on a
// phone: the draft banner, descriptors at the target stage, a rating with
// a note, evidence from a tagged story and "Work on next". Made-up data.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';

import 'app_harness.dart';
import 'framework_test.dart' show lmf, plan, today, udyogaPlan;

Future<void> seed(LearningBook b) async {
  await b.db
      .into(b.db.bridgeStudyPlans)
      .insert(BridgeStudyPlansCompanion.insert(id: 'u1', source: 'udyoga', plan: udyogaPlan(), updated: 'T'));
  await b.importCurriculum(parseCurriculum(jsonEncode(plan(framework: lmf()))), today: today);
}

void main() {
  testWidgets('large text on a phone: banner, rating, evidence and work on next', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: seed);
    await app.run();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.go('Learn');
    await app.tapText('Clinic team lead');
    await app.tap(find.byKey(const Key('framework-tile')));
    expect(tester.takeException(), isNull, reason: 'the program page and its tile');

    expect(find.byKey(const Key('framework-draft')), findsOneWidget);
    expect(find.text('Draft structure — check final wording.'), findsOneWidget);
    final list = find.descendant(
      of: find.byKey(const Key('framework-list')),
      matching: find.byType(Scrollable),
    );
    // Standards with no tagged story are gaps before any rating.
    expect(find.byKey(const Key('framework-gap-self_safety')), findsOneWidget);
    expect(find.text('Safe rotas'), findsWidgets, reason: 'the gap links its topic');

    final rate = find.byKey(const Key('framework-rate-self_communicating'));
    await tester.scrollUntilVisible(rate, 200, scrollable: list.first);
    expect(find.text('At stage one for self_communicating'), findsOneWidget);
    expect(find.textContaining('Rota swap at the made-up clinic'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the standards at large text');

    await app.tap(rate);
    await app.tap(find.byKey(const Key('framework-rating-1')));
    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'Need practice');
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'the rating dialog at large text');
    await app.tapText('Save rating');

    expect(find.textContaining('Starting (1/4)'), findsOneWidget);
    expect(find.text('Need practice'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('framework-gaps')), -200, scrollable: list.first);
    expect(find.byKey(const Key('framework-gap-self_communicating')), findsOneWidget);
    expect(find.text('Rated 1 or less'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
