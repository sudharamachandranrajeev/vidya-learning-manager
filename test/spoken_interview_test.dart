// The spoken interviewer's rules in Vidya (J3): the AI adapter over Ask AI,
// rounds kept as text, results fed to drills, readiness, the story bank and
// spaced review, and the version 9 to 10 upgrade. Made-up plan and answers.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:interview_engine/testing.dart' show ScriptedBrain;
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/spoken_interview.dart';

import 'interview_test.dart' show plan;
import 'support.dart';

const today = '2026-11-22';

const answer =
    'Last spring I trained twelve new starters on the booking system. I wrote a one-page guide and ran short '
    'practice sessions, and every starter booked a test appointment on their own by the end of the week.';

/// Scores whatever criteria the request lists at [code], quoting [quote].
Map<String, Object?> scoreAll(ie.BrainRequest r, String code, String quote) {
  final ids = [for (final m in RegExp(r'<criterion id="([^"]+)"').allMatches(r.texts.first)) m[1]!];
  return {
    'answers': [
      {
        'question': 1,
        'scores': [
          for (final id in ids) {'criterion': id, 'level': code, 'quote': quote},
        ],
        'strength': 'You said what you did yourself.',
        'fix': 'Say how you checked it worked.',
      },
    ],
  };
}

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  Future<({String programId, List<StudyItem> drills, List<Criterion> criteria})> seed() async {
    final pid = (await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today)).programId;
    final (:topics, :drills) = await book.programDrills(pid);
    return (programId: pid, drills: drills, criteria: await book.programCriteria(pid));
  }

  Future<SavedRound> roundOf(String pid, List<StudyItem> drills, List<Criterion> criteria) async {
    final topics = {for (final t in await db.select(db.learnTopics).get()) t.id: t};
    final id = await book.startRound(
      programId: pid,
      title: 'Example Trainer',
      framework: 'nhs_values',
      settings: const ie.RoundSettings(),
      questions: [for (final d in drills) drillQuestionFor(d, topics[d.topicId], criteria)],
      criteria: criteria,
      today: today,
    );
    return (await book.savedRound(id))!;
  }

  group('the AI over Ask AI', () {
    test('the schema goes in the prompt and the JSON is read back from a chatty reply', () async {
      final sent = <(String, String)>[];
      final brain = VidyaInterviewBrain((system, text) async {
        sent.add((system, text));
        return 'Here you go:\n```json\n{"criteria": [], "framework": "private"}\n```\nHope that helps.';
      });
      final j = await brain.readCriteria(advert: 'An example advert.');
      expect(j['framework'], 'private');
      expect(sent.single.$1, contains('Reply with one JSON object only'));
      expect(sent.single.$1, contains('"type"'), reason: 'the schema itself is included');
      expect(sent.single.$2, contains('An example advert.'));
    });

    test('a reply with no JSON is refused in plain words, never guessed at', () {
      expect(() => parseBrainReply('I think the answer was good.'), throwsA(isA<FormatException>()));
      expect(() => parseBrainReply('{not json}'), throwsA(isA<FormatException>()));
      expect(parseBrainReply('{"a": 1}'), {'a': 1});
    });

    test('offline, only a local server on this computer may score', () {
      const cloud = HelpAiSetup(via: HelpAi.anthropic);
      const local = HelpAiSetup(via: HelpAi.local, base: 'http://localhost:11434/v1');
      const lan = HelpAiSetup(via: HelpAi.local, base: 'http://192.168.1.20:11434/v1');
      expect(interviewAiUsable(cloud, offline: false), isTrue);
      expect(interviewAiUsable(cloud, offline: true), isFalse);
      expect(interviewAiUsable(local, offline: true), isTrue);
      expect(interviewAiUsable(lan, offline: true), isFalse);
      expect(interviewAiUsable(const HelpAiSetup(), offline: false), isFalse, reason: 'a chat website');
      expect(interviewAiNote(const HelpAiSetup(), offline: false), contains('work on this device'));
    });
  });

  group('a round', () {
    test('kept as text; scored twice; each drill gets one attempt on its own scale', () async {
      final s = await seed();
      final q1 = s.drills.firstWhere((d) => d.ref == 'q1');
      var r = await roundOf(s.programId, [q1], s.criteria);
      expect(r.questions.single.j['item'], q1.id);
      expect(r.profile.criteria.map((c) => c.text), contains('Explain a system to beginners'));
      await book.saveRoundAnswer(r.id, 0, answer);
      await book.finishRound(r.id, now: '${today}T10:00:00Z');
      r = (await book.savedRound(r.id))!;
      expect(r.answers, {0: answer});
      expect(r.row.finished, isNotNull);

      final brain = ScriptedBrain(
        (req) => scoreAll(req, '3', 'I wrote a one-page guide and ran short practice sessions'),
      );
      final runs = await ie.scoreTwice(
        brain: VidyaInterviewBrain((system, text) async {
          // The adapter's text goes through a real engine request.
          final j = await brain.ask(ie.BrainRequest(system: system, texts: [text], schema: const {}));
          return jsonEncode(j);
        }),
        role: r.row.title,
        framework: r.framework,
        round: r.debriefRound,
        random: math.Random(2),
      );
      expect(runs, hasLength(2));
      await book.saveRoundScoring(r.id, runs);
      r = (await book.savedRound(r.id))!;
      expect(r.scored, isTrue);
      final line = r.debrief.scoreLines().single;
      expect(line.level.code, '3');
      expect(line.criterion.text, 'Explain a system to beginners');

      expect(await book.recordRoundResults(r, today: today), 1);
      expect(await book.recordRoundResults(r, today: today), 1, reason: 'saving again replaces');
      final attempts = await book.drillAttempts(q1.id);
      expect(attempts, hasLength(1));
      final a = DrillAttempt.parse(attempts.single.detail)!;
      expect(a.aiScored, isTrue);
      expect(a.levels.values.single, '3');
      expect(a.score, 6, reason: 'level 3 of 0-4 is 6 of 8');
      final e = (await book.drillEvidence([q1.id]))[q1.id]!;
      expect(e.own, 6);
      expect(e.ownNote, contains('interviewer: 3'));
      final rows = (await book.readiness(s.programId, today: today)).rows;
      final ev = rows
          .expand((row) => row.evidence)
          .where((x) => x.kind == EvidenceKind.drill && x.id == q1.id);
      expect(ev.first.detail, contains('interviewer: 3'));
    });

    test('without an AI: coverage from the words, and the self-rating is saved on the drill', () async {
      final s = await seed();
      final q1 = s.drills.firstWhere((d) => d.ref == 'q1');
      final r0 = await roundOf(s.programId, [q1], s.criteria);
      await book.saveRoundAnswer(r0.id, 0, answer);
      final r = (await book.savedRound(r0.id))!;
      expect(r.scored, isFalse);
      expect(r.debrief.aiScored, isFalse);
      expect(r.debrief.coverage.single.status, isNot(ie.Coverage.missing));
      expect(r.debrief.notes.single.strength, isNotEmpty);
      expect(await book.recordRoundResults(r, today: today), 0, reason: 'nothing to save without a rating');
      expect(
        await book.recordRoundResults(
          r,
          selfChecks: {
            0: [2, 2, 1, 1],
          },
          today: today,
        ),
        1,
      );
      final a = DrillAttempt.parse((await book.drillAttempts(q1.id)).single.detail)!;
      expect((a.aiScored, a.score, a.round), (false, 6, r.id));
    });

    test('a fix goes to spaced review and an answer to the story bank', () async {
      final s = await seed();
      final q1 = s.drills.firstWhere((d) => d.ref == 'q1');
      final r0 = await roundOf(s.programId, [q1], s.criteria);
      await book.saveRoundAnswer(r0.id, 0, answer);
      final r = (await book.savedRound(r0.id))!;
      await book.addFixToReview(
        question: q1.title,
        fix: 'Say how you checked it worked.',
        nextLevel: 'More',
        today: today,
      );
      final card = (await db.select(db.learnCards).get()).single;
      expect(card.deck, interviewDeck);
      expect(card.back, contains('Next level: More'));
      await book.saveAnswerAsStory(r, 0, today: today);
      final story = (await book.storyBank()).single;
      expect(story.drills, [q1.id]);
      expect(story.criteria, isNotEmpty);
      expect('${story.situation} ${story.action} ${story.result}', contains('booking system'));
    });

    test('an untagged drill is scored against its own words', () async {
      final s = await seed();
      final tid = (await db.select(db.learnTopics).get()).first.id;
      final own = await book.addDrill(tid, 'Why do you want this job?', criterion: 'Motivation for the role');
      final drill = (await (db.select(db.learnItems)..where((i) => i.id.equals(own))).getSingle());
      final r = await roundOf(s.programId, [drill], const []);
      expect(ie.criteriaOf(r.questions.single), ['$drillCriterionPrefix$own']);
      expect(r.profile.criteria.single.text, 'Motivation for the role');
    });

    test('rounds list newest first and can be deleted', () async {
      final s = await seed();
      final r = await roundOf(s.programId, s.drills.take(1).toList(), s.criteria);
      expect((await book.savedRounds(programId: s.programId)).single.id, r.id);
      await book.deleteRound(r.id);
      expect(await book.savedRounds(), isEmpty);
    });
  });

  test('a version 9 database gains the rounds table and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v9.db');
    var db9 = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db9));
    await b.importCurriculum(parseCurriculum(jsonEncode(plan())), today: today);
    final d = (await (db9.select(db9.learnItems)..where((i) => i.ref.equals('q1'))).get()).single;
    await b.recordDrill(d, const DrillAttempt(checks: [2, 1, 1, 1]), today: today);
    await b.saveStory(title: 'Story', action: 'Did it.', today: today);
    final tests = (await db9.select(db9.learnAssessments).get())
        .map((a) => (a.id, a.score, a.detail))
        .toList();
    final items = (await db9.select(db9.learnItems).get()).map((i) => (i.id, i.content)).toList();
    // Back to version 9: no rounds table.
    await db9.customStatement('DROP INDEX IF EXISTS learn_rounds_program');
    await db9.customStatement('DROP TABLE learn_rounds');
    await db9.customStatement('PRAGMA user_version = 9');
    await db9.close();

    db9 = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db9));
    expect(
      (await db9.select(db9.learnAssessments).get()).map((a) => (a.id, a.score, a.detail)).toList(),
      tests,
    );
    expect((await db9.select(db9.learnItems).get()).map((i) => (i.id, i.content)).toList(), items);
    expect((await b.storyBank()).single.title, 'Story');
    // The new table works, and an old attempt still reads.
    final id = await b.startRound(
      title: 'Example',
      framework: 'private',
      settings: const ie.RoundSettings(),
      questions: [drillQuestionFor(d, null, const [])],
      criteria: const [],
      today: today,
    );
    expect((await b.savedRound(id))!.questions, hasLength(1));
    expect((await b.drillEvidence([d.id]))[d.id]!.own, 5);
    final indexes = await db9.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get();
    expect(indexes.map((r) => r.read<String>('name')), contains('learn_rounds_program'));
    await db9.close();
    await dir.delete(recursive: true);
  });
}
