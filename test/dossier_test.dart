// The job dossier (journey plan J5): the quote check that makes a card
// verified, freshness by source cycle, facts Udyoga proposes, the
// artefacts built only from checked cards, "not found in your sources",
// and the version 11 to 12 upgrade. The readers are in
// dossier_readers_test.dart. Employers, figures and
// text are made up.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/dossier.dart';
import 'package:vidya/domain/dossier_book.dart';
import 'package:vidya/domain/journey.dart';
import 'package:vidya/domain/journey_book.dart';

import 'support.dart';

const now = '2026-11-22T10:00:00.000Z';
const today = '2026-11-22';

const boardText =
    'Board of Directors, 4 September 2026.\n'
    'The board approved the business case for a new electronic patient record, going live in May 2027. '
    'Sickness absence fell to 4.9% in July.\n'
    'The Chief Nurse presented the safer staffing review.';

void main() {
  group('the quote check', () {
    test('passes the same words in order, ignoring case, punctuation and curly quotes', () {
      const text = 'The Trust’s “Digital First” plan runs to 2028. It is funded.';
      expect(quoteInSource("the trust's digital first plan runs to 2028", text), isTrue);
      expect(quoteInSource('THE TRUST’S "DIGITAL FIRST" PLAN', text), isTrue);
      expect(quoteInSource('digital first plan runs to 2029', text), isFalse, reason: 'a changed figure');
      expect(quoteInSource('plan runs to 2028 and beyond', text), isFalse);
    });

    test('refuses skipped words, short quotes and an empty one, saying why', () {
      expect(quoteInSource('The board … record', boardText), isFalse);
      expect(quoteInSource('The board approved', boardText), isFalse, reason: 'three words');
      expect(quoteProblem('', boardText), contains('no supporting sentence'));
      expect(quoteProblem('The board ... record', boardText), contains('skips words'));
      expect(quoteProblem('fell to 4.9%', boardText), contains('too short'));
      expect(quoteProblem('Sickness absence fell to 5.9% in July', boardText), contains('not in the source'));
      expect(quoteProblem('Sickness absence fell to 4.9% in July', boardText), isNull);
    });

    test('a proposal is verified only when its quote is in the text', () {
      final r = checkProposals([
        const FactProposal(
          claim: 'A new EPR goes live in May 2027.',
          quote: 'The board approved the business case for a new electronic patient record, going live in May 2027.',
        ),
        const FactProposal(
          claim: 'Absence is the lowest in the region.',
          quote: 'Absence is the lowest in the region.',
        ),
        const FactProposal(claim: 'No quote at all.'),
      ], boardText);
      expect(r.verified.single.claim, contains('EPR'));
      expect(r.unmatched, hasLength(2));
    });

    test('sentences are split at marks and lines; short pieces are dropped', () {
      expect(sentencesOf(boardText), [
        'Board of Directors, 4 September 2026.',
        'The board approved the business case for a new electronic patient record, going live in May 2027.',
        'Sickness absence fell to 4.9% in July.',
        'The Chief Nurse presented the safer staffing review.',
      ]);
    });
  });

  group('freshness by source cycle', () {
    test('each kind has its own cycle, from the source\'s own date', () {
      expect(staleAfterFor('staff-survey', sourceDate: '2026-03-12'), '2027-03-12');
      expect(staleAfterFor('cqc', sourceDate: '2025-05-20'), '2027-05-20');
      expect(staleAfterFor('board', sourceDate: '2026-09-04'), '2026-12-04');
      expect(staleAfterFor('pay', sourceDate: '2026-05-01'), '2027-04-01');
      expect(staleAfterFor('pay', sourceDate: '2026-02-01'), '2026-04-01');
      expect(staleAfterFor('team', sourceDate: '2026-01-31'), '2026-07-31');
      expect(staleAfterFor('other', sourceDate: '2026-02-01'), '2027-02-01');
    });

    test('without a source date it counts from when it was read; with neither, never', () {
      expect(staleAfterFor('board', fetchedAt: now), '2027-02-22');
      expect(staleAfterFor('board'), '');
      expect(isStale('2026-12-04', '2026-12-03'), isFalse);
      expect(isStale('2026-12-04', '2026-12-04'), isTrue);
      expect(isStale('', '2099-01-01'), isFalse);
    });
  });

  group('cards in the database', () {
    late LearningBook book;
    late String pid;
    setUp(() async {
      book = LearningBook(await Store.open(memoryDatabase()));
      pid = await book.addProgram('Prepare: Example Officer at Example Health Trust', '', today: today);
    });
    tearDown(() => book.db.close());

    Future<String> board() => book.addFactSource(
      pid,
      employer: 'Example Health Trust',
      kind: 'board',
      url: 'https://example.org/board/2026-09',
      title: 'Board papers, September 2026',
      sourceDate: '2026-09-04',
      body: boardText,
      now: now,
    );

    test('proposals: matched ones are saved verified with their source; the rest come back', () async {
      final src = await board();
      final r = await book.addProposals(
        src,
        [
          const FactProposal(
            claim: 'Absence fell to 4.9%.',
            quote: 'Sickness absence fell to 4.9% in July.',
            kind: 'board',
          ),
          const FactProposal(claim: 'Made up.', quote: 'The trust won an award for kindness.'),
        ],
        origin: 'ai',
        now: now,
      );
      expect(r.added, 1);
      expect(r.unmatched.single.claim, 'Made up.');
      final c = (await book.factCards(pid)).single;
      expect(
        (c.status, c.kind, c.sourceDate, c.sourceTitle, c.staleAfter, c.origin, c.fetchedAt),
        ('verified', 'board', '2026-09-04', 'Board papers, September 2026', '2026-12-04', 'ai', now),
      );
      // The same quote from the same source is not added twice.
      final again = await book.addProposals(
        src,
        [const FactProposal(claim: 'Again.', quote: 'Sickness absence fell to 4.9% in July.')],
        origin: 'ai',
        now: now,
      );
      expect(again.added, 0);
    });

    test('every fact from pasted reviews is anecdotal', () async {
      final src = await book.addFactSource(
        pid,
        kind: 'reviews',
        title: 'Reviews I read',
        body: 'Rotas are published six weeks ahead on most wards.',
        now: now,
      );
      await book.addProposals(
        src,
        [
          const FactProposal(
            claim: 'Rotas come out six weeks ahead.',
            quote: 'Rotas are published six weeks ahead on most wards.',
            kind: 'team',
          ),
        ],
        origin: 'ai',
        now: now,
      );
      expect((await book.factCards(pid)).single.kind, 'reviews-anecdotal');
    });

    test(
      'the learner\'s own fact: verified with a matching quote, else checked-by-me or inference',
      () async {
        final src = await board();
        final a = await book.addOwnFact(
          pid,
          claim: 'A new EPR in 2027.',
          quote: 'going live in May 2027',
          kind: 'systems',
          sourceId: src,
          now: now,
        );
        final b = await book.addOwnFact(
          pid,
          claim: 'The manager started in 2025.',
          kind: 'team',
          checkedMyself: true,
          now: now,
        );
        final c = await book.addOwnFact(
          pid,
          claim: 'They are hiring a lot.',
          quote: 'They are hiring lots of people.',
          kind: 'other',
          sourceId: src,
          now: now,
        );
        expect((a.status, b.status, c.status), ('verified', 'user-confirmed', 'inference'));
        await book.confirmFact(c.id, now: now);
        expect((await book.factCard(c.id))!.status, 'user-confirmed');
      },
    );

    test('a quote attached by hand must be in the text', () async {
      final src = await board();
      final c = await book.addOwnFact(pid, claim: 'Staffing is being reviewed.', kind: 'board', now: now);
      expect(
        await book.attachQuote(c.id, src, 'Staffing is under review', now: now),
        contains('not in the source'),
      );
      expect((await book.factCard(c.id))!.status, 'inference');
      expect(
        await book.attachQuote(c.id, src, 'The Chief Nurse presented the safer staffing review.', now: now),
        isNull,
      );
      final card = (await book.factCard(c.id))!;
      expect((card.status, card.sourceId, card.sourceDate), ('verified', src, '2026-09-04'));
    });

    test('changing a card\'s kind changes its freshness', () async {
      final src = await board();
      await book.addProposals(
        src,
        [const FactProposal(claim: 'x', quote: 'Sickness absence fell to 4.9% in July.', kind: 'board')],
        origin: 'ai',
        now: now,
      );
      final c = (await book.factCards(pid)).single;
      await book.setFactKind(c.id, 'staff-survey', now: now);
      expect((await book.factCard(c.id))!.staleAfter, '2027-09-04');
    });
  });

  group('facts Udyoga proposes', () {
    late LearningBook book;
    setUp(() async => book = LearningBook(await Store.open(memoryDatabase())));
    tearDown(() => book.db.close());

    Map<String, Object?> plan() => {
      'format': 'vidya-curriculum',
      'version': 3,
      'program': {'title': 'Prepare: Example Officer at Example Health Trust'},
      'journey': {
        'employer': 'Example Health Trust',
        'role': 'Example Officer',
        'sector': 'nhs',
        'advertText': 'Example Officer, Band 4. Support the digital team.',
        'facts': [
          {
            'claim': 'Sickness absence fell to 4.9% in July 2026.',
            'url': 'https://example.org/board/2026-09',
            'title': 'Board papers',
          },
          {'claim': 'Rated outstanding for caring.', 'url': 'https://example.org/cqc'},
          {'claim': 'No link, so not kept.'},
        ],
      },
    };

    test('arrive as inference cards, once, and are verified when their page\'s text supports them', () async {
      final r = await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      var cards = await book.factCards(r.programId);
      expect(cards.map((c) => (c.status, c.origin, c.quote)), [
        ('inference', 'udyoga', ''),
        ('inference', 'udyoga', ''),
      ]);
      expect(cards.map((c) => c.kind), unorderedEquals(['other', 'cqc']));
      // Sent again: not added twice.
      await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      expect(await book.factCards(r.programId), hasLength(2));

      // The learner pastes the board papers from the same page.
      await book.addFactSource(
        r.programId,
        kind: 'board',
        url: 'http://www.example.org/board/2026-09/',
        sourceDate: '2026-09-04',
        body: boardText,
        now: now,
      );
      cards = await book.factCards(r.programId);
      final absence = cards.firstWhere((c) => c.claim.startsWith('Sickness'));
      expect(
        absence.status,
        'inference',
        reason: 'the paper says July, not July 2026: every number must be there',
      );

      await book.addFactSource(
        r.programId,
        kind: 'board',
        url: 'https://example.org/board/2026-09',
        sourceDate: '2026-09-04',
        body: 'In July 2026 sickness absence fell to 4.9%, the lowest this year.',
        now: now,
      );
      cards = await book.factCards(r.programId);
      final checked = cards.firstWhere((c) => c.claim.startsWith('Sickness'));
      expect(
        (checked.status, checked.quote),
        ('verified', 'In July 2026 sickness absence fell to 4.9%, the lowest this year.'),
      );
      expect(cards.firstWhere((c) => c.kind == 'cqc').status, 'inference', reason: 'no text from its page');
    });

    test('the advert Udyoga sent can be kept as a source', () async {
      final r = await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
      final j = (await book.journeyView(r.programId))!.journey;
      final id = await book.addAdvertSource(r.programId, j, now: now);
      expect((await book.factSource(id!))!.body, contains('Band 4'));
      expect(await book.addAdvertSource(r.programId, const Journey(), now: now), isNull);
    });
  });

  group('artefacts and asking', () {
    CardFacts card(
      String id,
      String kind, {
      String status = 'verified',
      String stale = '2099-01-01',
      String claim = '',
    }) => (
      id: id,
      claim: claim.isEmpty ? 'The trust plans a new EPR in 2027.' : claim,
      kind: kind,
      status: status,
      sourceTitle: 'Board papers',
      sourceDate: '2026-09-04',
      staleAfter: stale,
    );

    test(
      'why-here points use only verified or checked cards, never inference or anecdote, one per kind first',
      () {
        final points = whyHerePoints([
          card('a', 'strategy'),
          card('b', 'strategy'),
          card('c', 'values', status: 'user-confirmed', claim: 'Its values put patients first.'),
          card('d', 'systems', status: 'inference'),
          card('e', 'reviews-anecdotal'),
        ], today: today);
        expect(points.map((p) => p.cardId), ['a', 'c', 'b']);
        expect(points.first.text, 'The trust plans a new EPR in 2027 (Board papers, 4 Sep 2026)');
      },
    );

    test('fresh cards come before stale ones', () {
      final points = whyHerePoints([
        card('old', 'strategy', stale: '2026-01-01'),
        card('new', 'values'),
      ], today: today);
      expect(points.map((p) => p.cardId), ['new', 'old']);
    });

    test('questions to ask come from checked cards, concerns first, each linking its card', () {
      final qs = questionsToAsk([
        card('s', 'strategy'),
        card('q', 'staff-survey', claim: 'Only 52% of staff would recommend it as a place to work.'),
        card('r', 'reviews-anecdotal', claim: 'Rotas come out late.'),
        card('i', 'cqc', status: 'inference'),
      ], today: today);
      expect(qs.map((q) => q.cardId), ['q', 's', 'r']);
      expect(qs.first.text, startsWith('I read that only 52% of staff'));
      expect(qs.last.text, 'Some staff reviews say rotas come out late. How is that for this team now?');
      expect(questionsToAsk([card('i', 'cqc', status: 'inference')], today: today), isEmpty);
    });

    test('asking finds cards and source sentences, or nothing: never a guess', () {
      final cards = [(id: 'c1', claim: 'A new EPR goes live in May 2027.', quote: '')];
      final sources = [(id: 's1', body: boardText)];
      final epr = askDossier(
        'When does the electronic patient record go live?',
        cards: cards,
        sources: sources,
      );
      expect(epr.sentences.single.sentence, contains('electronic patient record'));
      final card = askDossier('EPR', cards: cards, sources: sources);
      expect(card.cardIds, ['c1']);
      final none = askDossier('What is the parking like?', cards: cards, sources: sources);
      expect((none.cardIds.isEmpty, none.sentences.isEmpty), (true, true));
      expect(whereToLook('What is the pay band?').first.label, contains('Agenda for Change'));
    });

    test('an AI reply without the asked-for object is refused; facts still face the quote check', () async {
      final src = FactSource(
        id: 's',
        programId: 'p',
        employer: '',
        kind: 'board',
        url: '',
        title: 'Board',
        sourceDate: '',
        fetchedAt: now,
        body: boardText,
        deleted: false,
        hlc: '',
      );
      await expectLater(
        aiFactProposals((_, _) async => 'Here are some facts: the board met.', src),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('nothing was added'))),
      );
      final got = await aiFactProposals((system, text) async {
        expect(system, contains('copied character for character'));
        expect(text, contains('Sickness absence'));
        return '```json\n{"facts": [{"claim": "Absence fell.", "quote": "Sickness absence fell to 4.9% in July.", '
            '"kind": "nonsense"}, {"claim": "Invented.", "quote": "Profits doubled this year."}]}\n```';
      }, src);
      expect(got.first.kind, 'board', reason: 'an unknown kind takes the source\'s');
      final checked = checkProposals(got, src.body);
      expect((checked.verified.length, checked.unmatched.single.claim), (1, 'Invented.'));
    });
  });

  test('a version 11 database gains the dossier tables and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v11.db');
    var db = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db));
    final plan = {
      'format': 'vidya-curriculum',
      'version': 3,
      'program': {'title': 'Prepare: Example Officer'},
      'criteria': [
        {'id': 'e1', 'text': 'Excellent written communication', 'essential': true},
      ],
      'journey': {'employer': 'Example Health Trust', 'role': 'Example Officer', 'sector': 'nhs'},
    };
    final pid = (await b.importCurriculum(parseCurriculum(jsonEncode(plan)), today: today)).programId;
    await b.setJourneyStage(pid, 'research', now: now);
    Future<List<Object>> rows(AppDatabase db) async => [
      ...(await db.select(db.learnPrograms).get()).map((r) => (r.id, r.title, r.role)),
      ...(await db.select(db.learnCriteria).get()).map((r) => (r.id, r.body, r.essential)),
      ...(await db.select(db.learnJourneys).get()).map((r) => (r.id, r.journey, r.stage, r.progress)),
    ];
    final before = await rows(db);
    // Back to version 11: no dossier tables.
    for (final sql in [
      'DROP INDEX IF EXISTS learn_fact_sources_program',
      'DROP INDEX IF EXISTS learn_facts_program',
      'DROP TABLE learn_fact_sources',
      'DROP TABLE learn_facts',
      'PRAGMA user_version = 11',
    ]) {
      await db.customStatement(sql);
    }
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db));
    expect(await rows(db), before);
    expect((await b.journeyView(pid))!.current, 'research');
    // The new tables work.
    final src = await b.addFactSource(pid, kind: 'board', body: boardText, now: now);
    expect(
      (await b.addProposals(
        src,
        [const FactProposal(claim: 'x', quote: 'Sickness absence fell to 4.9% in July.')],
        origin: 'you',
        now: now,
      )).added,
      1,
    );
    final indexes = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get();
    expect(
      indexes.map((r) => r.read<String>('name')),
      containsAll(['learn_fact_sources_program', 'learn_facts_program']),
    );
    await db.close();
    await dir.delete(recursive: true);
  });
}
