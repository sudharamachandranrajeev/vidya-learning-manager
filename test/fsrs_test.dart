// FSRS scheduling, the migration from SM-2 (a replay of the review log),
// the switch back, the ready-by cap, and leech flagging. Fictional cards.
import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/review.dart';

import 'app_harness.dart';
import 'support.dart';

const day0 = '2026-10-01';

CardReview review(String cardId, String day, Grade g, {int n = 0}) => CardReview(
  id: '$cardId.$day.$n',
  hlc: '$day.$n',
  deleted: false,
  cardId: cardId,
  day: day,
  grade: g.index,
);

Flashcard blank(String id) => Flashcard(
  id: id,
  hlc: '',
  deleted: false,
  front: 'Which knot holds a lantern hook?',
  back: 'A bowline',
  deck: 'Lanterns',
  image: '',
  audio: '',
  due: day0,
  interval: 0,
  ease: 2.5,
  reps: 0,
  lapses: 0,
  created: day0,
  ref: '',
  plan: '',
  retired: '',
);

void main() {
  group('FSRS', () {
    test('a first review starts from the published initial stability and difficulty', () {
      final m = nextMemory(null, Grade.good, day0);
      // FSRS-6 defaults: S0(good) = w2, D0(good) = w4 - e^(w5 * 2) + 1.
      expect(m.stability, closeTo(3.2602, 1e-4));
      expect(m.difficulty, closeTo(4.8846, 1e-3));
      expect(nextSchedule(blank('c'), Grade.good, day0).interval, 3);
      expect(nextSchedule(blank('c'), Grade.again, day0).interval, 0);
      expect(nextSchedule(blank('c'), Grade.easy, day0).interval, 16); // w3 = 16.1507
    });

    test('a replayed log matches the reference memory state of dart-fsrs / py-fsrs', () {
      // test_memo_state: Again, Good the same day, then Good after 1, 3, 8
      // and 21 days, and once more the same day: S 49.4472, D 6.8271.
      final c = blank('m').copyWith(reps: 6, lapses: 1);
      final days = [day0, day0, addDays(day0, 1), addDays(day0, 4), addDays(day0, 12), addDays(day0, 33)];
      final log = [
        review('m', days[0], Grade.again),
        for (var i = 1; i < days.length; i++) review('m', days[i], Grade.good, n: i),
        review('m', days.last, Grade.good, n: 9),
      ];
      final m = memoryState(c, log)!;
      expect(m.stability, closeTo(49.4472, 1e-3));
      expect(m.difficulty, closeTo(6.8271, 1e-3));
      expect(m.lastDay, days.last);
      // The log's order on disk does not matter; other cards' reviews are ignored.
      final shuffled = [...log.reversed, review('other', day0, Grade.again)];
      expect(memoryState(c, shuffled), m);
    });

    test('at 90% retention the gap equals the stability; recall is 90% on the due day', () {
      for (final s in [1.0, 3.26, 10.4, 49.4472, 300.0]) {
        expect(fsrsInterval(s), s.round());
      }
      final m = (stability: 20.0, difficulty: 5.0, lastDay: day0);
      expect(recallOn(m, addDays(day0, 20)), closeTo(desiredRetention, 1e-9));
      expect(recallOn(m, day0), 1);
      expect(fsrsInterval(1e9), fsrsMaxInterval);
    });

    test('pace scales FSRS gaps too, never a forgotten card', () {
      final c = blank('p').copyWith(reps: 3, interval: 10, due: day0);
      int gap(Grade g, ReviewPace p) => nextSchedule(c, g, addDays(day0, 0), pace: p).interval;
      final good = [for (final p in ReviewPace.values) gap(Grade.good, p)];
      expect(good[0] > good[1] && good[1] > good[2], isTrue, reason: '$good');
      for (final p in ReviewPace.values) {
        expect(gap(Grade.again, p), 0);
        expect(gap(Grade.hard, p) <= gap(Grade.good, p) && gap(Grade.good, p) < gap(Grade.easy, p), isTrue);
      }
    });

    test('too little history: the memory starts from the card\'s own interval and ease', () {
      final c = blank('s').copyWith(interval: 30, reps: 4, ease: 2.5, due: '2026-10-31');
      final m = memoryState(c, const [])!;
      expect((m.stability, m.difficulty, m.lastDay), (30.0, 5.0, day0));
      // A log shorter than the card's run of recalls is not trusted either.
      expect(memoryState(c, [review('s', '2026-09-01', Grade.good)]), m);
      // Remembered on its due day, the gap grows.
      expect(nextSchedule(c, Grade.good, '2026-10-31').interval, greaterThan(30));
      // A hard card (low ease) seeds a high difficulty.
      expect(seedMemory(c.copyWith(ease: 1.3)).difficulty, 10);
      expect(memoryState(blank('new'), const []), isNull);
    });

    test('the ready-by cap still applies to FSRS gaps', () {
      final c = blank('r').copyWith(interval: 40, reps: 5, due: day0);
      final free = nextSchedule(c, Grade.good, day0);
      expect(free.due.compareTo('2026-10-20') > 0, isTrue);
      final capped = nextSchedule(c, Grade.good, day0, readyBy: '2026-10-20');
      expect(capped.due.compareTo('2026-10-20') < 0 && capped.due.compareTo(day0) > 0, isTrue);
      expect(capped.interval, daysBetween(day0, capped.due));
      expect(capped, capSchedule(free, today: day0, readyBy: '2026-10-20', slot: dueSlot(c.id)));
    });
  });

  group('migration and the setting', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    Future<Flashcard> card() async => (await book.db.select(book.db.learnCards).get()).single;

    test('FSRS is the default; the choice is a synced pref', () async {
      expect(await book.reviewScheduler(), ReviewScheduler.fsrs);
      await book.setReviewScheduler(ReviewScheduler.sm2);
      expect(await book.reviewScheduler(), ReviewScheduler.sm2);
      final pref = await (book.db.select(
        book.db.prefs,
      )..where((p) => p.id.equals(LearningBook.schedulerKey))).getSingle();
      expect(pref.value, 'sm2');
      expect(await book.db.customSelect("SELECT 1 FROM outbox WHERE entity = 'prefs'").get(), isNotEmpty);
      expect(ReviewScheduler.named('nonsense'), ReviewScheduler.fsrs);
    });

    test('switching replays the SM-2 history, rewrites nothing, and switching back loses nothing', () async {
      await book.setReviewScheduler(ReviewScheduler.sm2);
      await book.saveCard('Lamp oil for frost?', 'Colza', today: day0);
      var c = await card();
      for (final g in [Grade.good, Grade.good, Grade.again, Grade.good]) {
        await book.reviewCard(c, g, today: c.due);
        c = await card();
      }
      final sm2 = c;
      final history = await book.cardHistory(c.id);
      expect(history.map((r) => r.grade), [2, 2, 0, 2]);

      // To FSRS: no card row changes; the memory is the log's replay, the
      // same every time it is read.
      await book.setReviewScheduler(ReviewScheduler.fsrs);
      expect(await card(), sm2);
      final m = memoryState(sm2, history)!;
      MemoryState? replay;
      for (final r in history) {
        replay = nextMemory(replay, Grade.values[r.grade], r.day);
      }
      expect(m, replay);
      expect(memoryState(sm2, await book.cardHistory(c.id)), m);

      // An FSRS review: the gap comes from the memory, SM-2's numbers move on.
      await book.reviewCard(sm2, Grade.good, today: sm2.due);
      final f = await card();
      final want = fsrsInterval(nextMemory(m, Grade.good, sm2.due).stability);
      expect(f.interval, want);
      expect((f.reps, f.lapses, f.ease), (sm2.reps + 1, 1, sm2.ease));

      // Back to SM-2: the next gap is SM-2's, from the card's interval and ease.
      await book.setReviewScheduler(ReviewScheduler.sm2);
      await book.reviewCard(f, Grade.good, today: f.due);
      expect(
        (await card()).interval,
        [f.interval + 1, (f.interval * f.ease).round()].reduce((a, b) => a > b ? a : b),
      );
    });

    test('a forgotten card comes back today under FSRS and counts a lapse', () async {
      await book.saveCard('Wick height?', 'A finger', today: day0);
      await book.reviewCard(await card(), Grade.good, today: day0);
      final before = await card();
      await book.reviewCard(before, Grade.again, today: before.due);
      final c = await card();
      expect((c.interval, c.due, c.reps, c.lapses), (0, before.due, 0, 1));
    });
  });

  group('leeches', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    test('flagged at 4 lapses, kept ones again only after 4 more, never suspended', () async {
      final c = blank('l');
      expect(isLeech(c.copyWith(lapses: 3)), isFalse);
      expect(isLeech(c.copyWith(lapses: 4)), isTrue);
      expect(isLeech(c.copyWith(lapses: 7), keptAt: 4), isFalse);
      expect(isLeech(c.copyWith(lapses: 8), keptAt: 4), isTrue);

      await book.saveCard('Fog bell rhythm?', 'Two short, one long', today: day0);
      var card = (await book.db.select(book.db.learnCards).get()).single;
      for (var i = 0; i < 4; i++) {
        await book.reviewCard(card, Grade.again, today: day0);
        card = (await book.db.select(book.db.learnCards).get()).single;
      }
      expect((card.lapses, card.retired, card.due), (4, '', day0));
      expect(isLeech(card), isTrue);
      await book.keepLeech(card);
      expect(await book.keptLeeches(), {card.id: 4});
      expect(isLeech(card, keptAt: (await book.keptLeeches())[card.id]!), isFalse);
    });

    test('split adds an editable copy with a fresh schedule and keeps the original', () async {
      await book.saveCard('Fog bell rhythm and meaning?', 'Two short, one long: ships near', today: day0);
      final c = (await book.db.select(book.db.learnCards).get()).single.copyWith(lapses: 5, interval: 2);
      await book.save(book.db.learnCards, c, c.id);
      final original = (await book.db.select(book.db.learnCards).get()).single;
      final id = await book.splitCard(original, today: '2026-10-05');
      final all = await book.db.select(book.db.learnCards).get();
      expect(all, hasLength(2));
      final copy = all.firstWhere((x) => x.id == id);
      expect((copy.front, copy.back, copy.deck), (c.front, c.back, c.deck));
      expect((copy.lapses, copy.interval, copy.due, copy.ref), (0, 0, '2026-10-05', ''));
      expect(all.firstWhere((x) => x.id == c.id), original);
    });
  });

  testWidgets('a leech shows a banner in review with Rewrite, Split and Keep, and a list on Review', (
    tester,
  ) async {
    final app = AppHarness(tester)..desktop();
    await app.open(
      seed: (b) async {
        await b.saveCard('Fog bell rhythm?', 'Two short, one long', today: today());
        await b.saveCard('Beacon colour?', 'Green', today: today());
        final cards = await b.db.select(b.db.learnCards).get();
        final leech = cards.firstWhere((c) => c.front.startsWith('Fog')).copyWith(lapses: 4, ease: 1.7);
        await b.save(b.db.learnCards, leech, leech.id);
        final near = cards.firstWhere((c) => c.front.startsWith('Beacon')).copyWith(lapses: 3);
        await b.save(b.db.learnCards, near, near.id);
      },
    );
    await app.run();
    await app.go('Review');
    expect(find.text('Hard to remember'), findsOneWidget);
    expect(find.text('Rewrite'), findsOneWidget, reason: 'only the 4-lapse card');

    await app.tapText('Begin review');
    // The queue is in due order; find the leech whichever comes first.
    if (find.text('Fog bell rhythm?').evaluate().isEmpty) {
      expect(find.textContaining('Forgotten'), findsNothing);
      await app.tapText('Show answer');
      await app.tapText('Good');
    }
    expect(find.text('Fog bell rhythm?'), findsWidgets);
    expect(find.textContaining('Forgotten 4 times'), findsOneWidget);
    expect(find.textContaining('not set aside'), findsOneWidget);

    await app.tapText('Rewrite');
    expect(find.text('Edit card'), findsOneWidget);
    await app.enter('Front: the question', 'Fog bell: how many short rings?');
    await app.tapText('Save');
    expect(find.text('Fog bell: how many short rings?'), findsOneWidget);

    await app.tapText('Split');
    expect(find.text('Edit card'), findsOneWidget);
    await app.tapText('Save'); // this card
    expect(find.text('Edit card'), findsOneWidget);
    await app.enter('Front: the question', 'Fog bell: what does the long ring mean?');
    await app.tapText('Save'); // the copy
    final fronts = await tester.runAsync(
      () async => [for (final c in await app.book.db.select(app.book.db.learnCards).get()) c.front],
    );
    expect(
      fronts,
      containsAll(['Fog bell: how many short rings?', 'Fog bell: what does the long ring mean?']),
    );

    await app.tapText('Keep');
    expect(find.textContaining('Forgotten 4 times'), findsNothing);
    final cards = await tester.runAsync(() => app.book.db.select(app.book.db.learnCards).get());
    expect(cards!.every((c) => c.retired.isEmpty), isTrue, reason: 'nothing suspended');
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
