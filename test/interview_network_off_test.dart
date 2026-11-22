// Network-off test: a whole interview round in Vidya, run with the engine
// and offline practice on, must never open a connection to another
// machine; nor may the job dossier's paste flow and quote check. Every HTTP client and socket made in the zone is trapped and
// recorded; connections to this machine (a local AI server) are allowed.
// Same approach as the engine's own network-off test. Made-up plan and
// answers.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:interview_engine/testing.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/dossier.dart';
import 'package:vidya/domain/dossier_book.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/readiness.dart';
import 'package:vidya/domain/spoken_interview.dart';

import 'interview_test.dart' show plan;
import 'spoken_interview_test.dart' show answer, scoreAll;
import 'support.dart';

bool _loopback(String host) {
  final h = host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = InternetAddress.tryParse(h);
  return ip != null && ip.isLoopback;
}

String _hostOf(Object? host) => host is InternetAddress ? host.address : '$host';

class _Trap {
  final attempts = <String>[];
  SocketException refuse(String host) {
    attempts.add(host);
    return SocketException('network-off test: $host was not contacted');
  }
}

class _TrapHttp extends HttpOverrides {
  _TrapHttp(this.trap);
  final _Trap trap;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)..findProxy = ((_) => 'DIRECT');
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (!_loopback(uri.host)) return Future.error(trap.refuse(uri.host));
      return Socket.startConnect(uri.host, uri.port);
    };
    return client;
  }
}

final class _TrapIo extends IOOverrides {
  _TrapIo(this.trap);
  final _Trap trap;

  @override
  Future<Socket> socketConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) {
    final h = _hostOf(host);
    if (!_loopback(h)) return Future.error(trap.refuse(h));
    return super.socketConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    final h = _hostOf(host);
    if (!_loopback(h)) return Future.error(trap.refuse(h));
    return super.socketStartConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

Future<T> _offline<T>(_Trap trap, Future<T> Function() body) => HttpOverrides.runZoned(
  () => IOOverrides.runZoned(
    body,
    socketConnect: _TrapIo(trap).socketConnect,
    socketStartConnect: _TrapIo(trap).socketStartConnect,
  ),
  createHttpClient: _TrapHttp(trap).createHttpClient,
);

void main() {
  test('the trap works: another machine is refused and recorded', () async {
    final trap = _Trap();
    await _offline(trap, () async {
      final client = HttpClient();
      await expectLater(client.getUrl(Uri.parse('http://192.0.2.10/')), throwsA(isA<SocketException>()));
      client.close(force: true);
    });
    expect(trap.attempts, ['192.0.2.10']);
  });

  test('a Vidya round with offline practice: plan, spoken round, scoring, results, review, story', () async {
    final trap = _Trap();
    final db = memoryDatabase();
    final tmp = await Directory.systemTemp.createTemp('vidya-network-off-');
    addTearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });
    await _offline(trap, () async {
      await ie.OfflineGuard.instance.run(() async {
        final book = LearningBook(await Store.open(db));
        const day = '2026-11-22';
        final pid = (await book.importCurriculum(parseCurriculum(jsonEncode(plan())), today: day)).programId;
        final drills = (await book.programDrills(pid)).drills;
        final criteria = await book.programCriteria(pid);
        final topics = {for (final t in await db.select(db.learnTopics).get()) t.id: t};
        final drill = drills.firstWhere((d) => d.ref == 'q1');
        final questions = [drillQuestionFor(drill, topics[drill.topicId], criteria)];
        final id = await book.startRound(
          programId: pid,
          title: 'Example Trainer',
          framework: 'nhs_values',
          settings: const ie.RoundSettings(level: 3, aiPlan: false),
          questions: questions,
          criteria: criteria,
          today: day,
        );

        // Built-in follow-ups only, and a spoken round with test doubles.
        var r = (await book.savedRound(id))!;
        final plans = ie.withCriteria(questions, [for (final q in questions) ie.templatePlan(q)], r.profile);
        final persona = ie.Persona.of(ie.PersonaKind.neutral);
        final level = ie.Ladder.of(3);
        final round = ie.SpokenRound(
          questions: [for (final q in questions) ie.RoundQuestion(q.question, tests: q.why)],
          voice: FakeVoice(),
          listener: FakeListener([spokenAnswer(answer)]),
          takes: MemoryTakes(),
          sink: _BookSink(book, id),
          interviewer: ie.Interviewer(
            persona: persona,
            level: level,
            plans: plans,
            budgets: [for (final q in questions) ie.answerBudget(q, level)],
          ),
          pause: (_) async {},
        )..start();
        await round.ask();
        await round.done();
        for (var i = 0; i < 4 && round.phase != ie.RoundPhase.review; i++) {
          await round.done();
        }
        await round.close();
        await book.finishRound(id, now: '${day}T10:00:00Z');
        r = (await book.savedRound(id))!;
        expect(r.answers[0], contains('one-page guide'));

        // Without an AI: coverage on this device, then the learner's ratings.
        expect(r.debrief.aiScored, isFalse);
        expect(r.debrief.coverage, isNotEmpty);

        // Offline, a cloud AI may not score; a local server on this computer may.
        expect(interviewAiUsable(const HelpAiSetup(via: HelpAi.anthropic), offline: true), isFalse);
        expect(
          interviewAiUsable(
            const HelpAiSetup(via: HelpAi.local, base: 'http://localhost:11434/v1'),
            offline: true,
          ),
          isTrue,
        );
        final local = ScriptedBrain(
          (req) => scoreAll(req, '3', 'I wrote a one-page guide and ran short practice sessions'),
        );
        final runs = await ie.scoreTwice(
          brain: VidyaInterviewBrain(
            (system, text) async =>
                jsonEncode(await local.ask(ie.BrainRequest(system: system, texts: [text], schema: const {}))),
          ),
          role: r.row.title,
          framework: r.framework,
          round: r.debriefRound,
          random: math.Random(1),
        );
        await book.saveRoundScoring(id, runs);
        r = (await book.savedRound(id))!;
        expect(await book.recordRoundResults(r, today: day), 1);
        final evidence = (await book.drillEvidence([drill.id]))[drill.id]!;
        expect(evidence.practised, isTrue);
        final readiness = await book.readiness(pid, today: day);
        expect(readiness.rows, isNotEmpty);

        await book.addFixToReview(
          question: questions.single.question,
          fix: 'Say how you checked it.',
          today: day,
        );
        await book.saveAnswerAsStory(r, 0, today: day);
        expect(await book.storyBank(), isNotEmpty);

        // Speech models: nothing installed, and a download is refused.
        final mm = ie.ModelManager(Directory('${tmp.path}/models'));
        expect(await mm.installed(ie.speechModel(ie.vadModelId)), isFalse);
        await expectLater(mm.download(ie.speechModel(ie.vadModelId)), throwsA(anything));
      });
    });
    expect(trap.attempts, isEmpty, reason: 'nothing tried to reach another machine');
  });

  test(
    'the job dossier offline: Udyoga\'s facts, a pasted source, the quote check and the artefacts',
    () async {
      final trap = _Trap();
      final db = memoryDatabase();
      addTearDown(db.close);
      await _offline(trap, () async {
        final book = LearningBook(await Store.open(db));
        const day = '2026-11-22', now = '2026-11-22T10:00:00Z';
        final pid = (await book.importCurriculum(
          parseCurriculum(
            jsonEncode({
              'format': 'vidya-curriculum',
              'version': 3,
              'program': {'title': 'Prepare: Example Officer'},
              'journey': {
                'employer': 'Example Health Trust',
                'sector': 'nhs',
                'facts': [
                  {'claim': 'A new day surgery unit opens in 2027.', 'url': 'https://example.org/strategy'},
                ],
              },
            }),
          ),
          today: day,
        )).programId;
        await book.addFactSource(
          pid,
          kind: 'strategy',
          url: 'https://example.org/strategy',
          sourceDate: '2026-04-01',
          body: 'The trust will open a new day surgery unit in 2027.',
          now: now,
        );
        final cards = await book.factCards(pid);
        expect(cards.single.status, 'verified');
        final facts = [
          for (final c in cards)
            (
              id: c.id,
              claim: c.claim,
              kind: c.kind,
              status: c.status,
              sourceTitle: c.sourceTitle,
              sourceDate: c.sourceDate,
              staleAfter: c.staleAfter,
            ),
        ];
        expect(whyHerePoints(facts, today: day), hasLength(1));
        expect(questionsToAsk(facts, today: day), hasLength(1));
      });
      expect(trap.attempts, isEmpty, reason: 'the dossier reads nothing by itself');
    },
  );

  test(
    'a round with opt-in video, offline: clips kept here, no path in synced tables or brain requests',
    () async {
      final trap = _Trap();
      final db = memoryDatabase();
      final tmp = await Directory.systemTemp.createTemp('vidya-video-off-');
      addTearDown(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
      await _offline(trap, () async {
        await ie.OfflineGuard.instance.run(() async {
          final book = LearningBook(await Store.open(db));
          const day = '2026-11-22';
          final pid = (await book.importCurriculum(
            parseCurriculum(jsonEncode(plan())),
            today: day,
          )).programId;
          final drills = (await book.programDrills(pid)).drills;
          final criteria = await book.programCriteria(pid);
          final topics = {for (final t in await db.select(db.learnTopics).get()) t.id: t};
          final drill = drills.firstWhere((d) => d.ref == 'q1');
          final questions = [drillQuestionFor(drill, topics[drill.topicId], criteria)];
          final id = await book.startRound(
            programId: pid,
            title: 'Example Trainer',
            framework: 'nhs_values',
            settings: const ie.RoundSettings(level: 1, aiPlan: false),
            questions: questions,
            criteria: criteria,
            today: day,
          );
          final store = ie.VideoTakeStore(Directory('${tmp.path}/video-takes'));
          final video = ie.RoundVideo(
            roundId: id,
            recorder: FakeVideoRecorder(Directory('${tmp.path}/camera')),
            store: store,
          );
          final round = ie.SpokenRound(
            questions: [for (final q in questions) ie.RoundQuestion(q.question, tests: q.why)],
            voice: FakeVoice(),
            listener: FakeListener([spokenAnswer(answer)]),
            takes: MemoryTakes(),
            sink: _BookSink(book, id),
            video: video,
            pause: (_) async {},
          )..start();
          await round.ask();
          await round.done();
          await round.close();
          await book.finishRound(id, now: '${day}T10:00:00Z');
          final clips = await store.list(roundId: id);
          expect(clips, hasLength(1));
          expect(ie.seekToQuote(clips, 'I wrote a one-page guide'), isNotNull);

          var r = (await book.savedRound(id))!;
          final local = ScriptedBrain(
            (req) => scoreAll(req, '3', 'I wrote a one-page guide and ran short practice sessions'),
          );
          await book.saveRoundScoring(
            id,
            await ie.scoreTwice(
              brain: VidyaInterviewBrain(
                (system, text) async => jsonEncode(
                  await local.ask(ie.BrainRequest(system: system, texts: [text], schema: const {})),
                ),
              ),
              role: r.row.title,
              framework: r.framework,
              round: r.debriefRound,
              random: math.Random(1),
            ),
          );
          r = (await book.savedRound(id))!;
          await book.recordRoundResults(r, today: day);

          // Every row of every table (the synced ones and the device-only
          // settings) and every brain request: no video path, file or folder.
          final rows = <String>[];
          for (final t in db.allTables) {
            for (final row in await db.select(t).get()) {
              rows.add('$row');
            }
          }
          final sent = [
            for (final q in local.requests) ...[q.system, ...q.texts],
          ].join('\n');
          final dump = rows.join('\n');
          expect(dump, contains('one-page guide'), reason: 'sanity: the transcript is saved');
          for (final leak in [
            clips.single.videoPath,
            clips.single.id,
            tmp.path,
            'video-takes',
            '.mp4',
            '.wav',
          ]) {
            expect(dump, isNot(contains(leak)), reason: 'a table holds $leak');
            expect(sent, isNot(contains(leak)), reason: 'a brain request holds $leak');
          }
          await store.deleteAll();
          expect(await store.list(), isEmpty);
        });
      });
      expect(trap.attempts, isEmpty, reason: 'nothing tried to reach another machine');
    },
  );
}

class _BookSink implements ie.AnswerSink {
  _BookSink(this.book, this.id);
  final LearningBook book;
  final String id;
  @override
  Future<void> saveTranscript(int question, String text) => book.saveRoundAnswer(id, question, text);
}
