import 'dart:async';

import 'package:brahma_core/brahma_core.dart' show today;
import 'package:flutter/material.dart' show ButtonStyleButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' show InterviewerVoice, SpeechModel;
import 'package:vidya/app/interview_providers.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/audio_rehearsal.dart';
import 'package:vidya/domain/review.dart';

import 'app_harness.dart';

const _day = '2026-11-02';

Flashcard _card(String id, String front, String back) => Flashcard(
  id: id,
  hlc: '',
  deleted: false,
  front: front,
  back: back,
  deck: 'Lanterns',
  image: '',
  audio: '',
  due: _day,
  interval: 0,
  ease: 2.5,
  reps: 0,
  lapses: 0,
  created: _day,
  ref: '',
  plan: '',
  retired: '',
);

/// Records what it is asked to say; each line finishes when the test says
/// (or at once with [instant]).
class FakeVoice implements InterviewerVoice {
  FakeVoice({this.instant = true});
  final bool instant;
  final said = <String>[];
  var stops = 0, closed = false;
  Completer<void>? _line;

  @override
  void prepare(String text) {}

  @override
  Future<void> say(String text) {
    said.add(text);
    if (instant) return Future.value();
    return (_line = Completer<void>()).future;
  }

  void finishLine() => _line?.complete();

  @override
  Future<void> stop() async {
    stops++;
    final l = _line;
    if (l != null && !l.isCompleted) l.complete();
  }

  @override
  Future<void> close() async => closed = true;
}

/// A pause timer the test ends by hand, recording each length asked for.
class FakeWait {
  final asked = <Duration>[];
  final _open = <Completer<void>>[];

  Future<void> call(Duration d) {
    asked.add(d);
    final c = Completer<void>();
    _open.add(c);
    return c.future;
  }

  void finishAll() {
    for (final c in _open) {
      if (!c.isCompleted) c.complete();
    }
    _open.clear();
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('speakable', () {
    test('markdown is read as plain words', () {
      expect(
        speakable(
          '## Knots\n\n**Bowline** holds a _lantern_ hook.\n\n- Use `rope`\n- See [the guide](https://x.example/g)',
        ),
        'Knots. Bowline holds a lantern hook. Use rope. See the guide.',
      );
      expect(speakable('> A ***strong*** knot ~~maybe~~'), 'A strong knot maybe.');
      expect(speakable('```\ntie(a, b)\n```'), 'tie(a, b).');
      expect(speakable('Line<br>two ![a rope](r.png) <https://x.example>'), 'Line two a rope.');
      expect(speakable('| Knot | Use |\n|---|---|\n| Bowline | Hook |'), 'Knot, Use. Bowline, Hook.');
      expect(speakable('snake_case_name stays'), 'snake_case_name stays.');
    });

    test('a cloze reads as a blank for the question and in full for the answer', () {
      final c = _card('c', 'The {{c1::bowline}} holds a {{c2::hook::thing}}', '');
      expect(spokenQuestion(c), 'The blank holds a thing.');
      expect(spokenAnswer(c), 'The bowline holds a hook.');
      expect(
        spokenAnswer(_card('d', '{{c1::Rope}} *frays*', 'Seal the **end**')),
        'Rope frays. Seal the end.',
      );
    });
  });

  group('AudioRehearsal', () {
    test('reads the question, pauses, reads the answer, then a tap grades through the review path', () async {
      final voice = FakeVoice(), wait = FakeWait();
      final graded = <(String, Grade)>[];
      final r = AudioRehearsal(
        voice: voice,
        cards: [_card('a', 'Which **knot**?', 'A bowline'), _card('b', 'Which rope?', 'Hemp')],
        grade: (c, g) async {
          graded.add((c.id, g));
          return null;
        },
        wait: wait.call,
      );
      final phases = <RehearsalPhase>[];
      r.addListener(() => phases.add(r.phase));
      final done = r.start();
      await _flush();
      expect(voice.said, ['Which knot?']);
      expect(r.phase, RehearsalPhase.pause);
      expect(wait.asked, [defaultRehearsalPause]);
      expect(defaultRehearsalPause, const Duration(seconds: 5));
      wait.finishAll();
      await _flush();
      expect(voice.said, ['Which knot?', 'A bowline.']);
      expect(r.phase, RehearsalPhase.waiting);
      // Without auto-advance it waits for a grade however long it takes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.phase, RehearsalPhase.waiting);
      r.gradeCurrent(Grade.good);
      await _flush();
      await _flush();
      expect(graded, [('a', Grade.good)]);
      expect(r.current?.id, 'b');
      expect(phases.take(4), [
        RehearsalPhase.question,
        RehearsalPhase.pause,
        RehearsalPhase.answer,
        RehearsalPhase.waiting,
      ]);
      wait.finishAll();
      await _flush();
      r.gradeCurrent(Grade.again);
      await done;
      expect(graded, [('a', Grade.good), ('b', Grade.again)]);
      expect(r.graded, 2);
      expect(r.notGraded, isEmpty);
      expect(r.phase, RehearsalPhase.done);
    });

    test('the pause length is the one chosen', () async {
      final wait = FakeWait();
      final r = AudioRehearsal(
        voice: FakeVoice(),
        cards: [_card('a', 'Q', 'A')],
        grade: (_, _) async => null,
        pause: const Duration(seconds: 12),
        wait: wait.call,
      );
      unawaited(r.start());
      await _flush();
      expect(wait.asked, [const Duration(seconds: 12)]);
      await r.stop();
    });

    test('auto-advance moves on without grading: the card stays due', () async {
      final wait = FakeWait();
      var grades = 0;
      final r = AudioRehearsal(
        voice: FakeVoice(),
        cards: [_card('a', 'Q1', 'A1'), _card('b', 'Q2', 'A2')],
        grade: (_, _) async {
          grades++;
          return null;
        },
        autoAdvance: true,
        wait: wait.call,
      );
      final done = r.start();
      for (var i = 0; i < 4; i++) {
        await _flush();
        wait.finishAll();
      }
      await done;
      expect(grades, 0, reason: 'auto-advance never fakes a grade');
      expect(r.graded, 0);
      expect([for (final c in r.notGraded) c.id], ['a', 'b']);
      expect(wait.asked, [
        defaultRehearsalPause,
        defaultAdvanceAfter,
        defaultRehearsalPause,
        defaultAdvanceAfter,
      ]);
    });

    test('a card graded Again comes round once more', () async {
      final wait = FakeWait();
      final ids = <String>[];
      final again = _card('a', 'Q', 'A');
      var first = true;
      final r = AudioRehearsal(
        voice: FakeVoice(),
        cards: [again],
        grade: (c, g) async {
          ids.add(c.id);
          final back = first ? again : null;
          first = false;
          return back;
        },
        wait: wait.call,
      );
      final done = r.start();
      await _flush();
      r.gradeCurrent(Grade.again);
      await _flush();
      await _flush();
      expect(r.current?.id, 'a');
      r.gradeCurrent(Grade.good);
      await done;
      expect(ids, ['a', 'a']);
    });

    test('pause stops the voice and holds; resume reads the card again', () async {
      final voice = FakeVoice(instant: false), wait = FakeWait();
      var grades = 0;
      final r = AudioRehearsal(
        voice: voice,
        cards: [_card('a', 'Q1', 'A1')],
        grade: (_, _) async {
          grades++;
          return null;
        },
        wait: wait.call,
      );
      unawaited(r.start());
      await _flush();
      expect(voice.said, ['Q1.']);
      r.pauseNow();
      await _flush();
      expect(r.phase, RehearsalPhase.paused);
      expect(r.isPaused, isTrue);
      expect(voice.stops, greaterThan(0));
      expect(r.canGrade, isFalse);
      r.gradeCurrent(Grade.good);
      await _flush();
      expect(grades, 0);
      expect(voice.said, ['Q1.'], reason: 'nothing more is read while paused');
      r.resume();
      await _flush();
      expect(voice.said, ['Q1.', 'Q1.']);
      expect(r.phase, RehearsalPhase.question);
      await r.stop();
    });

    test('stop ends at once, grades nothing and leaves the rest due', () async {
      final voice = FakeVoice(instant: false), wait = FakeWait();
      var grades = 0;
      final r = AudioRehearsal(
        voice: voice,
        cards: [_card('a', 'Q1', 'A1'), _card('b', 'Q2', 'A2')],
        grade: (_, _) async {
          grades++;
          return null;
        },
        wait: wait.call,
      );
      final done = r.start();
      await _flush();
      await r.stop();
      await done;
      expect(r.phase, RehearsalPhase.done);
      expect(grades, 0);
      expect(voice.said, ['Q1.']);
      expect(voice.stops, greaterThan(0));
      r.gradeCurrent(Grade.good);
      await _flush();
      expect(grades, 0);
    });
  });

  testWidgets('Review offers hands-free review; a tap grade is saved', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open(
      seed: (book) async {
        await book.saveCard('Which knot holds a **lantern** hook?', 'A bowline', today: today());
        await book.saveCard('Which rope frays least?', 'Hemp', today: today());
      },
    );
    final voice = FakeVoice();
    await app.run(overrides: [rehearsalVoiceProvider.overrideWith((ref) async => _FakeSource(voice))]);
    await app.go('Review');
    await app.tapText('Listen hands-free');
    expect(find.text('2 cards due'), findsOneWidget);
    expect(find.text('Pause before the answer: 5 seconds'), findsOneWidget);
    await app.tapText('Start listening');
    expect(voice.said.first, anyOf('Which knot holds a lantern hook?', 'Which rope frays least?'));
    await tester.pump(const Duration(seconds: 6));
    await app.settle();
    expect(find.text('Grade it, or wait'), findsOneWidget);
    await app.tapText('Good');
    await tester.pump(const Duration(seconds: 6));
    await app.settle();
    await app.tapText('Stop');
    expect(find.textContaining('1 graded.'), findsOneWidget);
    final reviews = await tester.runAsync(() => app.book.db.select(app.book.db.learnReviews).get());
    expect(reviews, hasLength(1));
    expect(tester.takeException(), isNull);
    await app.tapText('Done');
    await app.close();
  });

  testWidgets('hands-free review on a phone at twice the text size, with reduced motion', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final app = AppHarness(tester)..phone();
    await app.open(seed: (book) => book.saveCard('Which knot?', 'A bowline', today: today()));
    final voice = FakeVoice();
    await app.run(overrides: [rehearsalVoiceProvider.overrideWith((ref) async => _FakeSource(voice))]);
    await app.go('Review');
    // The Review page itself overflows at twice the text size with a card due
    // (found before this change); only the hands-free page is checked here.
    tester.takeException();
    await app.tapText('Listen hands-free');
    await app.tapText('Start listening');
    await tester.pump(const Duration(seconds: 6));
    await app.settle();
    expect(find.text('Grade it, or wait'), findsOneWidget);
    for (final label in ['Again', 'Hard', 'Good', 'Easy', 'Pause', 'Stop']) {
      final size = tester.getSize(
        find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()),
      );
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }
    await app.tapText('Pause');
    expect(find.text('Resume'), findsOneWidget);
    await app.tapText('Stop');
    expect(find.textContaining('0 graded.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.tapText('Done');
    await app.close();
  });
}

class _FakeSource implements RehearsalVoiceSource {
  _FakeSource(this.voice);
  final FakeVoice voice;

  @override
  Future<SpeechModel?> missing() async => null;

  @override
  Future<void> download(SpeechModel m, {void Function(double share)? progress}) async {}

  @override
  Future<InterviewerVoice> open(List<String> texts) async => voice;
}
