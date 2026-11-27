// Assessment polish B4: a trend chart per standard, and story cards'
// `tags` and `happened` kept when a plan is imported from a file (no
// Udyoga link). Made-up plan: a community clinic's team lead.

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show Store;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/framework.dart';
import 'package:vidya/ui/charts.dart';

import 'app_harness.dart';
import 'framework_test.dart' show lmf, plan, today;
import 'support.dart';

/// The clinic plan with Udyoga-style tagged story cards in it, as a file.
String filePlan({String part = '', List<Map<String, Object?>>? cards}) => jsonEncode({
  ...plan(),
  'part': ?(part.isEmpty ? null : part),
  'cards':
      cards ??
      [
        {
          'id': 'udyoga.story.s1',
          'deck': 'Interview stories',
          'front': 'Tell your story: Rota swap at the made-up clinic (Teamwork)',
          'back': 'Action: Talked it through with each nurse.',
          'tags': [
            {'framework': 'nhs_lmf', 'item': 'self_communicating', 'title': ''},
          ],
          'happened': '2026-03-01',
        },
        {'id': 'udyoga.story.s2', 'front': 'Tell your story: Untagged', 'back': 'Action: x'},
      ],
});

Map<String, Object?> card(String id, String item, {String happened = ''}) => {
  'id': id,
  'front': 'Tell your story: Story $id',
  'back': 'Action: x',
  'tags': [
    {'framework': 'nhs_lmf', 'item': item},
  ],
  'happened': ?(happened.isEmpty ? null : happened),
};

void main() {
  group('tags and happened from a file', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    Future<String> pid() async => (await book.db.select(book.db.learnPrograms).getSingle()).id;

    test('the parser keeps tagged cards on the plan', () {
      final p = parseCurriculum(filePlan());
      expect(p.stories.single.title, 'Rota swap at the made-up clinic');
      expect(p.stories.single.happened, '2026-03-01');
      expect(p.stories.single.tags.single.item, 'self_communicating');
      expect(p.cards, hasLength(2), reason: 'both still become review cards');
    });

    test('a plan imported from a file evidences its framework with the story and its day', () async {
      await book.importCurriculum(parseCurriculum(filePlan()), today: today);
      final v = (await book.frameworkView(await pid()))!;
      final s = v.standards.firstWhere((x) => x.standard.id == 'self_communicating');
      expect(s.evidence.single.title, 'Rota swap at the made-up clinic');
      expect(s.evidence.single.happened, '2026-03-01');
      expect(s.gapReasons, isEmpty);
      // Kept in a synced pref, not a new column: the schema is unchanged.
      expect(book.db.schemaVersion, 12);
      final key = storyTagsKey(await pid());
      expect([for (final p in await book.db.select(book.db.prefs).get()) p.id], contains(key));
    });

    test('a whole plan sent again replaces the stories; a part adds to them', () async {
      await book.importCurriculum(parseCurriculum(filePlan()), today: today);
      final id = await pid();
      Future<List<String>> titles() async => [for (final s in await book.taggedStories()) s.title];
      await book.importCurriculum(
        parseCurriculum(filePlan(cards: [card('a', 'self_safety', happened: '2026-05-02')])),
        today: today,
      );
      expect(await titles(), ['Story a']);
      await book.importCurriculum(
        parseCurriculum(filePlan(part: '2 of 2', cards: [card('b', 'care_collaboration')])),
        today: today,
      );
      expect(await titles(), ['Story a', 'Story b']);
      // A whole plan with cards but none tagged clears them.
      await book.importCurriculum(
        parseCurriculum(
          filePlan(
            cards: [
              {'id': 'c', 'front': 'Plain', 'back': 'x'},
            ],
          ),
        ),
        today: today,
      );
      expect(await titles(), isEmpty);
      expect(await book.framework(id), isNotNull);
    });

    test('encode and decode round-trip; junk reads as none', () {
      final stories = parseCurriculum(filePlan()).stories;
      final back = decodeTaggedStories(encodeTaggedStories(stories));
      expect(back.single.title, stories.single.title);
      expect(back.single.happened, '2026-03-01');
      expect(back.single.ref, 'udyoga.story.s1');
      expect(decodeTaggedStories(''), isEmpty);
      expect(decodeTaggedStories('{nope'), isEmpty);
      expect(decodeTaggedStories('[1]'), isEmpty);
    });

    test('the trend window is the last 12 ratings, oldest first', () {
      final h = [
        for (var k = 0; k < 15; k++)
          (
            day: '2026-01-${(k + 1).toString().padLeft(2, '0')}',
            rating: FrameworkRating(framework: 'f', standard: 's', stage: '1', rating: k % 5),
          ),
      ];
      expect(trendWindow(h), hasLength(trendPoints));
      expect(trendWindow(h).first.day, '2026-01-04');
      expect(trendWindow(h.take(3).toList()), hasLength(3));
    });
  });

  testWidgets('large text on a phone: a standard rated twice draws its trend, read out as words', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) async {
        await b.importCurriculum(parseCurriculum(jsonEncode(plan(framework: lmf()))), today: today);
        final id = (await b.db.select(b.db.learnPrograms).getSingle()).id;
        final f = (await b.framework(id))!;
        final s = f.standards.firstWhere((x) => x.id == 'self_communicating');
        await b.rateStandard(id, f, s, stage: '1', rating: 1, today: '2026-10-01');
        await b.rateStandard(id, f, s, stage: '1', rating: 3, today: today);
      },
    );
    await app.run();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await app.go('Learn');
    await app.tapText('Clinic team lead');
    await app.tap(find.byKey(const Key('framework-tile')));
    final trend = find.byKey(const Key('framework-trend-self_communicating'));
    final list = find.descendant(
      of: find.byKey(const Key('framework-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(trend, 200, scrollable: list.first);
    expect(tester.widget<Sparkline>(find.descendant(of: trend, matching: find.byType(Sparkline))).values, [
      1,
      3,
    ]);
    expect(
      find.bySemanticsLabel(RegExp(r'Ratings over time, oldest first: .*1 of 4, .*3 of 4')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('framework-trend-self_safety')), findsNothing, reason: 'one rating or none');
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await app.close();
  });
}
