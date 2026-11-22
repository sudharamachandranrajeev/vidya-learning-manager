// The stage packs (J8): email templates and their fill-ins, the offer
// checker's dated rules, checks imported from Udyoga's finalise checklist,
// people and acronyms into spaced review, wins into the story bank,
// monthly check-ins, the next role's readiness and drafts handed to
// Udyoga. Employers, people and figures in the fixtures are made up.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/journey.dart';
import 'package:vidya/domain/journey_book.dart';
import 'package:vidya/domain/offer_checker.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/stage_emails.dart';
import 'package:vidya/domain/stage_packs.dart';
import 'package:vidya/domain/stage_packs_book.dart';

import 'support.dart';

const today = '2026-11-22';
const now = '2026-11-22T10:00:00.000Z';

const job = Journey(
  employer: 'Example Health Trust',
  role: 'Example Officer',
  sector: 'nhs',
  closes: '2026-12-10',
);

Map<String, Object?> jobPlan({Map<String, Object?> journey = const {}}) => {
  'format': 'vidya-curriculum',
  'version': 3,
  'program': {'title': 'Prepare: Example Officer at Example Health Trust'},
  'role': 'Example Officer',
  'criteria': [
    {'id': 'e1', 'text': 'Excellent written communication', 'essential': true},
  ],
  'journey': {'employer': 'Example Health Trust', 'role': 'Example Officer', 'sector': 'nhs', ...journey},
};

void main() {
  group('email templates', () {
    test('every later stage has its templates, each with the heads-ups that apply', () {
      expect(emailTemplatesFor('contact').map((t) => t.id), ['informal-call', 'call-plan']);
      expect(emailTemplatesFor('follow-up').map((t) => t.id), ['chase']);
      expect(emailTemplatesFor('after').map((t) => t.id), ['feedback', 'thank-you']);
      expect(emailTemplatesFor('offer').map((t) => t.id), [
        'step-query',
        'accept',
        'decline',
        'withdraw',
        'notice',
      ]);
      expect(
        emailTemplate('informal-call')!.headsUp.map((l) => l.text),
        contains(startsWith('Do not ask about pay')),
      );
      final thanks = emailTemplate('thank-you')!;
      expect(thanks.optional, isTrue);
      expect(thanks.headsUp.single.source!.url, contains('uk.finance.yahoo.com'));
      expect(thanks.headsUp.single.text, startsWith('Optional'));
      expect(
        emailTemplate('notice')!.headsUp.every((l) => l.source?.url.contains('acas.org.uk') ?? false),
        isTrue,
      );
    });

    test('every heads-up is sourced and dated, or general advice', () {
      for (final t in emailTemplates) {
        for (final l in t.headsUp) {
          if (l.sourced) expect(isValidIsoDate(l.source!.date), isTrue, reason: '${t.id}: ${l.text}');
        }
      }
    });

    test('the journey and the learner fill it in; the manager only when entered', () {
      var e = fillEmail(emailTemplate('informal-call')!, job, const {});
      expect(e.subject, 'Informal chat about the Example Officer post');
      expect(e.body, startsWith('Dear Hiring Manager,'));
      expect(e.body, contains('the Example Officer post at Example Health Trust'));
      expect(e.body, endsWith('Kind regards,\n[your name]'));
      expect(e.missing, ['myName']);
      e = fillEmail(emailTemplate('informal-call')!, job, const {
        'manager': 'Sam Example',
        'myName': 'Alex Example',
      });
      expect(e.body, startsWith('Dear Sam Example,'));
      expect(e.missing, isEmpty);
      final chase = fillEmail(emailTemplate('chase')!, job, const {}, date: (d) => 'NICE $d');
      expect(chase.body, contains('which closed on NICE 2026-12-10'));
      expect(emailText(chase), startsWith('Subject: Application for Example Officer\n\n'));
    });

    test('the feedback request asks the score per question and what a higher score needed', () {
      final e = fillEmail(emailTemplate('feedback')!, job, const {'interviewDate': '3 December'});
      expect(e.body, contains('the score I got for each question'));
      expect(e.body, contains('what a higher score would have needed'));
      expect(e.body, contains('on 3 December'));
    });
  });

  group('offer checker', () {
    test('promotion to the bottom of the new band is normal, with its dated source', () {
      final f = checkOffer(
        const OfferFacts(band: 'Band 5', point: 1, salary: 32073, promotion: true),
        sector: 'nhs',
        today: today,
      );
      expect(f.map((x) => x.kind), [FindingKind.normal]);
      expect(f.single.line.text, contains('as this offer does'));
      expect(f.single.line.source!.url, contains('pay-promotion'));
      expect(f.single.line.source!.date, '2026-11-21');
    });

    test('a promotion above the bottom says to get it in writing', () {
      final f = checkOffer(
        const OfferFacts(band: '5', point: 3, salary: 34000, promotion: true),
        sector: 'nhs',
        today: today,
      );
      expect(f.single.line.text, contains('get that in writing before you accept'));
    });

    test('joining at the bottom: ask about experience credit in writing before accepting', () {
      final f = checkOffer(
        const OfferFacts(band: '4', salary: 28392, relevantYears: 3),
        sector: 'nhs',
        today: today,
      );
      expect(f.single.kind, FindingKind.ask);
      expect(f.single.line.text, contains('completed years only (you entered 3)'));
      expect(f.single.line.text, contains('in writing, before you accept'));
    });

    test('a salary outside the band, a long probation and a start inside the notice are flagged', () {
      final f = checkOffer(
        const OfferFacts(
          band: '3',
          salary: 30000,
          probationMonths: 9,
          startDate: '2026-12-01',
          noticeWeeks: 4,
        ),
        sector: 'nhs',
        today: today,
      );
      expect(f.map((x) => x.kind), [FindingKind.watch, FindingKind.ask, FindingKind.watch]);
      expect(f[0].line.text, contains('outside Band 3\'s 2026/27 range (£25,760 to £27,476)'));
      expect(f[2].line.text, contains('before your 4-week notice'));
      expect(f[2].line.source!.url, contains('acas'));
    });

    test('the 2026/27 cards are flagged once April 2027 comes', () {
      const facts = OfferFacts(band: '5', salary: 32073, promotion: true);
      expect(
        checkOffer(facts, sector: 'nhs', today: '2027-03-31').map((x) => x.kind),
        isNot(contains(FindingKind.stale)),
      );
      final f = checkOffer(facts, sector: 'nhs', today: '2027-04-01');
      expect(f.first.kind, FindingKind.stale);
      expect(f.first.line.staleOn('2027-04-01'), isTrue);
      for (final c in afcRuleCards) {
        expect(c.staleOn('2027-04-01'), isTrue, reason: c.id);
        expect(c.source.date, isNotEmpty);
      }
    });

    test('a band with no dated figures says where to look', () {
      final f = checkOffer(
        const OfferFacts(band: 'Band 7'),
        sector: 'nhs',
        today: today,
      );
      expect(f.single.line.text, contains('no dated figures for Band 7'));
    });

    test('a university offer is checked against its grade table, or the range the learner typed', () {
      var f = checkOffer(
        const OfferFacts(band: 'Grade 6', salary: 33951),
        sector: 'university',
        employer: 'University of Leeds',
        today: '2026-07-01',
      );
      expect(f.single.kind, FindingKind.ask);
      expect(f.single.line.text, contains('bottom of Grade 6'));
      expect(f.single.line.source!.url, contains('hr.leeds.ac.uk'));
      f = checkOffer(
        const OfferFacts(band: '5', salary: 34000),
        sector: 'university',
        employer: 'University of Leeds',
        today: '2026-07-01',
      );
      expect(f.single.line.text, contains('outside Grade 5\'s range (£29,588 to £33,002)'));
      // Past August 2026 the table is flagged.
      f = checkOffer(
        const OfferFacts(band: '5', salary: 30000),
        sector: 'university',
        employer: 'University of Leeds',
        today: today,
      );
      expect(f.map((x) => x.kind), [FindingKind.stale, FindingKind.normal]);
      f = checkOffer(
        const OfferFacts(band: '7', salary: 40000),
        sector: 'university',
        employer: 'Exampleton University',
        today: today,
      );
      expect(f.single.line.text, contains('no grade table'));
      f = checkOffer(
        const OfferFacts(band: '7', salary: 50000, rangeMin: 41000, rangeMax: 48000),
        sector: 'university',
        employer: 'Exampleton University',
        today: today,
      );
      expect(f.single.kind, FindingKind.watch);
      expect(f.single.line.sourced, isFalse);
    });

    test('offer facts survive a round trip, money typed with a pound sign included', () {
      final f = OfferFacts.fromJson({
        'band': ' Band 5 ',
        'salary': '£32,073',
        'hours': '30',
        'fixedTerm': true,
      });
      expect((f.bandKey, f.salary, f.hours, f.fixedTerm), ('5', 32073, 30.0, true));
      expect(OfferFacts.fromJson(f.toJson()).toJson(), f.toJson());
      expect(const OfferFacts().isEmpty, isTrue);
      expect(notLegalAdvice, startsWith('Not legal'));
    });

    test('the evidence table has one row per earlier role, blanks for the learner to fill', () {
      expect(evidenceTable(const []).split('\n'), hasLength(3));
      final t = evidenceTable([
        {
          'role': 'Ward clerk',
          'employer': 'Example Hospital',
          'from': '2021-04',
          'to': '2025-03',
          'years': '3',
        },
      ]);
      expect(t, contains('| Ward clerk | Example Hospital | 2021-04 | 2025-03 | 3 | [ ] | [ ] |'));
      expect(t.split('\n').first, startsWith('| Role | Employer'));
    });
  });

  group('checks, joining and after', () {
    test('Udyoga\'s finalise checklist is used, with the IAT note added for NHS posts', () {
      // Written by Udyoga's tests (test/fixtures/udyoga-checks-plan.json there).
      final p = parseCurriculum(File('test/fixtures/udyoga-checks-plan.json').readAsStringSync());
      final checks = packChecks(p.journey!, const {});
      expect(checks.where((c) => c.fromUdyoga), hasLength(9));
      expect(checks.last.kind, 'iat');
      expect(checks.first.status, 'done');
      final overdue = overdueChecks(checks, '2026-12-29');
      expect(overdue.map((c) => c.kind), [
        'references',
        'criminal_record',
        'health',
        'qualifications',
        'forms',
      ]);
      expect(overdueChecks(checks, '2026-12-28'), isEmpty);
      expect(checks[2].dueSoonOn('2026-12-26'), isTrue);
    });

    test('without Udyoga, Vidya\'s own list for the sector', () {
      expect(packChecks(const Journey(sector: 'nhs'), const {}).map((c) => c.kind), [
        'identity',
        'references',
        'criminal_record',
        'health',
        'iat',
      ]);
      expect(packChecks(const Journey(sector: 'private'), const {}).map((c) => c.kind), [
        'identity',
        'references',
      ]);
    });

    test('check notes: references by sector, DBS Update Service and IAT, sourced and dated', () {
      expect(checkNotes('references', 'nhs').single.text, contains('6 months'));
      expect(checkNotes('references', 'nhs').single.text, contains('3 years'));
      expect(checkNotes('references', 'private').single.sourced, isFalse);
      final dbs = checkNotes('criminal_record', 'nhs').single;
      expect(dbs.text, contains('within 30 days'));
      expect(dbs.source!.date, packsChecked);
      final iat = checkNotes('iat', 'nhs');
      expect(iat.first.text, contains('Say yes'));
      expect(iat.last.text, contains('missing on day one'));
    });

    test('probation reviews, months that end short, check-ins and the next role\'s criteria', () {
      expect(addMonths('2027-01-31', 1), '2027-02-28');
      expect(addMonths('2026-11-22', 14), '2028-01-22');
      expect(probationReviews('2027-01-04', 6).map((r) => r.day), [
        '2027-02-04',
        '2027-04-04',
        '2027-06-20',
        '2027-07-04',
      ]);
      expect(probationNotes('university').first.source!.url, contains('leeds'));
      expect(nextCheckIn(start: '2027-01-04'), '2027-02-04');
      expect(nextCheckIn(last: '2027-02-10', start: '2027-01-04'), '2027-03-10');
      expect(nextCheckIn(), isNull);
      expect(parseNextCriteria('- Degree or equivalent\n2. Desirable: PRINCE2\nLeads a small team (D)\n\n'), [
        (text: 'Degree or equivalent', essential: true),
        (text: 'PRINCE2', essential: false),
        (text: 'Leads a small team', essential: false),
      ]);
    });
  });

  group('in the book', () {
    late AppDatabase db;
    late LearningBook book;
    late String pid;
    setUp(() async {
      db = memoryDatabase();
      book = LearningBook(await Store.open(db));
      pid = (await book.importCurriculum(parseCurriculum(jsonEncode(jobPlan())), today: today)).programId;
    });
    tearDown(() => db.close());

    test('fill-ins and pack data stay when other work and a resent plan change the journey', () async {
      await book.setJourneyFills(pid, {'manager': ' Sam Example ', 'myName': 'Alex Example'}, now: now);
      await book.setOfferFacts(pid, const OfferFacts(band: '5', salary: 32073), now: now);
      await book.setProduced(pid, 'offer', 'Notice letter to your current employer', true, now: now);
      await book.importCurriculum(
        parseCurriculum(jsonEncode(jobPlan(journey: {'applicationStage': 'offer'}))),
        today: today,
      );
      await book.setJourneyFills(pid, {'myName': ''}, now: now);
      final v = (await book.journeyView(pid))!;
      expect(v.fills, {'manager': 'Sam Example'});
      expect(OfferFacts.fromJson(Map.from(v.of('offer').pack['facts'] as Map)).salary, 32073);
      expect(v.of('offer').produced, contains('Notice letter to your current employer'));
      expect(v.current, 'offer', reason: 'Udyoga\'s offer stage picks it');
    });

    test('Vidya\'s own checks keep a status, a done day and a due date', () async {
      await book.setOwnCheck(pid, 'references', status: 'sent', due: '2026-11-20', now: now);
      await book.setOwnCheck(pid, 'identity', status: 'done', now: now);
      var v = (await book.journeyView(pid))!;
      var checks = packChecks(v.journey, v.of('checks').pack);
      expect(checks.firstWhere((c) => c.kind == 'identity').done, today);
      expect(overdueChecks(checks, today).single.kind, 'references');
      await book.setOwnCheck(pid, 'references', due: '', now: now);
      v = (await book.journeyView(pid))!;
      checks = packChecks(v.journey, v.of('checks').pack);
      expect(checks.firstWhere((c) => c.kind == 'references').due, isNull);
      expect(checks.firstWhere((c) => c.kind == 'references').status, 'sent');
    });

    test('people and acronyms become flashcards due today; the same name changes in place', () async {
      await book.addPackCard(
        pid,
        'people',
        front: 'Sam Example',
        back: 'Ward manager',
        today: today,
        now: now,
      );
      await book.addPackCard(
        pid,
        'acronyms',
        front: 'EPR',
        back: 'Electronic patient record',
        today: today,
        now: now,
      );
      var cards = await db.select(db.learnCards).get();
      expect(cards.map((c) => (c.deck, c.front, c.due)), [
        ('Who\'s who: Example Health Trust', 'Sam Example', today),
        ('Acronyms and systems: Example Health Trust', 'EPR', today),
      ]);
      final id = cards.first.id;
      await book.addPackCard(
        pid,
        'people',
        front: 'Sam Example',
        back: 'Matron',
        today: '2026-11-23',
        now: now,
      );
      cards = await db.select(db.learnCards).get();
      expect(cards, hasLength(2));
      expect(cards.firstWhere((c) => c.id == id).back, 'Matron');
      expect(cards.firstWhere((c) => c.id == id).due, today, reason: 'its schedule stays');
      final v = (await book.journeyView(pid))!;
      expect(packCards(v.of('joining').pack['people']), [(front: 'Sam Example', back: 'Matron')]);
      await book.removePackCard(pid, 'people', 'Sam Example', now: now);
      expect(packCards((await book.journeyView(pid))!.of('joining').pack['people']), isEmpty);
    });

    test('day-one list and training tracker', () async {
      await book.setDayOne(pid, dayOneStarter.first, true, now: now);
      await book.setDayOne(pid, 'Find the staff room', false, add: true, now: now);
      await book.setTraining(pid, [(name: 'Fire safety', due: '2027-01-31', done: '')], now: now);
      final p = (await book.journeyView(pid))!.of('joining').pack;
      expect(p['dayOneTicked'], [dayOneStarter.first]);
      expect((p['dayOne'] as List).last, 'Find the staff room');
      expect(trainingRows(p['training']), [(name: 'Fire safety', due: '2027-01-31', done: '')]);
    });

    test('a logged win goes to the story bank once', () async {
      await book.addWin(
        pid,
        'Cleared the referral backlog in two weeks. Manager thanked the team.',
        now: now,
      );
      final w = wins((await book.journeyView(pid))!.of('first-90-days').pack['wins']).single;
      final story = await book.winToStory(pid, w.id, today: today, now: now);
      expect(story, isNotNull);
      expect(await book.winToStory(pid, w.id, today: today, now: now), story);
      final bank = await book.storyBank();
      expect(bank.single.title, 'Cleared the referral backlog in two weeks');
      expect(bank.single.action, contains('Manager thanked the team'));
      expect(wins((await book.journeyView(pid))!.of('first-90-days').pack['wins']).single.story, story);
    });

    test('monthly check-ins fall a month after the start date, then after the last one', () async {
      expect(await book.checkInsDue(), isEmpty);
      await book.setOfferFacts(pid, const OfferFacts(startDate: '2027-01-04'), now: now);
      expect(await book.checkInsDue(), [(programId: pid, day: '2027-02-04')]);
      await book.doCheckIn(pid, {checkInPrompts.first: 'Settled in'}, day: '2027-02-06', now: now);
      expect(await book.checkInsDue(), [(programId: pid, day: '2027-03-06')]);
      final log = (await book.journeyView(pid))!.of('first-90-days').pack['checkIns'] as List;
      expect((log.single as Map)[checkInPrompts.first], 'Settled in');
    });

    test('the next role gets its own program and readiness against its criteria', () async {
      final next = await book.startNextRole(
        pid,
        title: 'Senior Example Officer',
        criteria: '- Leads a small team\n- Desirable: PRINCE2',
        today: today,
        now: now,
      );
      expect(next, isNotNull);
      final r = await book.readiness(next!, today: today);
      expect(r.rows.map((x) => (x.criterion.body, x.essential)), [
        ('Leads a small team', true),
        ('PRINCE2', false),
      ]);
      final program = await (db.select(db.learnPrograms)..where((p) => p.id.equals(next))).getSingle();
      expect((program.title, program.role), ('Next role: Senior Example Officer', 'Senior Example Officer'));
      expect((await book.journeyView(pid))!.of('grow').pack['nextProgram'], next);
      expect(await book.startNextRole(pid, title: 'X', criteria: '', today: today, now: now), isNull);
    });

    test('drafts go to Udyoga in their own row, newest first, one per template and job', () async {
      expect(await book.udyogaLinked(), isFalse);
      Future<void> send(String template, String body, String at) => book.sendDraftToUdyoga(
        template: template,
        title: emailTemplate(template)!.title,
        subject: 'Feedback on my interview for Example Officer',
        body: body,
        employer: 'Example Health Trust',
        role: 'Example Officer',
        now: at,
      );
      await send('feedback', 'First go', '2026-12-04T09:00:00Z');
      await send('chase', 'Chase', '2026-12-05T09:00:00Z');
      await send(
        'feedback',
        'Dear Hiring Manager,\n\nThank you for interviewing me.',
        '2026-12-06T09:00:00Z',
      );
      final drafts = await book.emailDrafts();
      expect(drafts.map((d) => (d.template, d.body.split('\n').first)), [
        ('feedback', 'Dear Hiring Manager,'),
        ('chase', 'Chase'),
      ]);
      final row = await (db.select(
        db.bridgeStudyProgress,
      )..where((p) => p.id.equals(emailDraftsId))).getSingle();
      expect(parseEmailDrafts(row.progress), hasLength(2));
      expect(parseEmailDrafts('not json'), isEmpty);
      // Udyoga's tests read this file.
      final fixture = File('test/fixtures/vidya-email-drafts.json');
      final json =
          '${const JsonEncoder.withIndent('  ').convert(jsonDecode(emailDraftsJson([for (final d in drafts) (id: 'fixture-${d.template}', template: d.template, title: d.title, subject: d.subject, body: d.body, employer: d.employer, role: d.role, at: d.at)])))}\n';
      if (!fixture.existsSync() || Platform.environment['UPDATE_FIXTURES'] == '1') {
        await fixture.writeAsString(json);
      }
      expect(await fixture.readAsString(), json);
    });

    test('Udyoga counts as linked once it has sent a plan', () async {
      await db
          .into(db.bridgeStudyPlans)
          .insert(
            BridgeStudyPlansCompanion.insert(id: 'udyoga.job.1', source: 'udyoga', plan: '{}', updated: now),
          );
      expect(await book.udyogaLinked(), isTrue);
    });
  });
}
