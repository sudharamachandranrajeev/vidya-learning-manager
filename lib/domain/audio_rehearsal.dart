/// Hands-free audio rehearsal (C4): the device voice reads a card's
/// question, pauses, reads the answer, then waits for a grade or moves on.
///
/// The rules, in plain words:
///
/// * Only a tap grades. A grade goes through the normal review path (the
///   [AudioRehearsal.grade] callback), so the schedule and the ready-by cap
///   apply as in a typed review.
/// * Auto-advance never grades. A card it moves past keeps its schedule and
///   stays due; the summary counts it as "not graded".
/// * Markdown, cloze markers and links are turned into plain words before
///   anything is spoken ([speakable]).
/// * Nothing here touches the network: the voice is the on-device one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:interview_engine/interview_engine.dart' show InterviewerVoice;

import '../db/database.dart';
import 'cloze.dart';
import 'review.dart';

/// The pause between question and answer unless changed.
const defaultRehearsalPause = Duration(seconds: 5);

/// The wait after the answer before auto-advance moves on.
const defaultAdvanceAfter = Duration(seconds: 5);

/// The pause lengths offered, in seconds.
const rehearsalPauseMin = 2, rehearsalPauseMax = 30;

final _fence = RegExp(r'```[^\n]*\n?([\s\S]*?)```');
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _autoLink = RegExp(r'<(https?://[^>]+)>');
final _bareUrl = RegExp(r'https?://\S+');
final _tag = RegExp(r'<[^>]+>');
final _heading = RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true);
final _quote = RegExp(r'^\s*>\s?', multiLine: true);
final _bullet = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+', multiLine: true);
final _rule = RegExp(r'^\s*(?:[-*_]\s*){3,}$', multiLine: true);
final _tableDivider = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)*\|?\s*$', multiLine: true);
final _emphasis = RegExp(
  r'(\*\*|\*|~~)(?=\S)(.+?)(?<=\S)\1|(?<![A-Za-z0-9])(__|_)(?=\S)(.+?)(?<=\S)\3(?![A-Za-z0-9])',
);
final _code = RegExp(r'`([^`]*)`');

/// [text] as plain words to speak: markdown marks, links' addresses, images,
/// code fences and HTML tags gone (their words kept), each list item and
/// line its own sentence. [hideCloze] says how cloze spans read: hidden as
/// "blank" (or the hint) for a question, revealed for an answer, or left
/// alone (null) for text that is not a card front.
String speakable(String text, {bool? hideCloze}) {
  var s = text.replaceAll('\r\n', '\n');
  if (hideCloze != null && isCloze(s)) {
    s = hideCloze
        ? clozeQuestion(s)
              .replaceAllMapped(RegExp(r'\[([^\]]*)\](?!\()'), (m) => m[1] == '…' ? 'blank' : m[1]!)
        : clozeAnswer(s);
  }
  s = s
      .replaceAllMapped(_fence, (m) => m[1]!)
      .replaceAllMapped(_image, (m) => m[1]!)
      .replaceAllMapped(_link, (m) => m[1]!)
      .replaceAll(_autoLink, '')
      .replaceAll(_bareUrl, '')
      .replaceAll(_tag, ' ')
      .replaceAll(_tableDivider, '')
      .replaceAll(_rule, '')
      .replaceAll(_heading, '')
      .replaceAll(_quote, '')
      .replaceAll(_bullet, '')
      .replaceAllMapped(_code, (m) => m[1]!);
  // Nested emphasis (bold inside italic) needs more than one pass.
  for (var i = 0; i < 3; i++) {
    final next = s.replaceAllMapped(_emphasis, (m) => m[2] ?? m[4]!);
    if (next == s) break;
    s = next;
  }
  s = s.replaceAll(RegExp(r'[ \t]*\|[ \t]*'), ', ').replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');
  // Each line its own sentence, so the voice pauses between list items.
  final lines = [
    for (final l in s.split('\n'))
      if (l.trim().replaceAll(RegExp(r'^[,\s]+|[,\s]+$'), '').isNotEmpty)
        l.trim().replaceAll(RegExp(r'^[,\s]+|[,\s]+$'), '').replaceAll(RegExp(r'\s+'), ' '),
  ];
  return [for (final l in lines) RegExp(r'[.!?:;]$').hasMatch(l) ? l : '$l.'].join(' ');
}

/// What a card's question reads as.
String spokenQuestion(Flashcard c) => speakable(c.front, hideCloze: true);

/// What a card's answer reads as: the revealed front for a cloze card
/// (plus its back when it has extra detail), else the back.
String spokenAnswer(Flashcard c) {
  if (isCloze(c.front)) {
    final full = speakable(c.front, hideCloze: false);
    return c.back.trim().isEmpty ? full : '$full ${speakable(c.back)}';
  }
  return speakable(c.back);
}

/// Where a rehearsal stands.
enum RehearsalPhase {
  ready('Ready to start'),
  question('Reading the question'),
  pause('Pause: think of the answer'),
  answer('Reading the answer'),
  waiting('Grade it, or wait'),
  paused('Paused'),
  done('Finished');

  const RehearsalPhase(this.label);
  final String label;
}

/// One hands-free rehearsal over [cards], in order. [grade] records a grade
/// through the normal review path and gives the card back when it is due
/// again today (it then comes round once more at the end), else null.
/// [wait] is the pause timer, replaced in tests.
class AudioRehearsal extends ChangeNotifier {
  AudioRehearsal({
    required this.voice,
    required List<Flashcard> cards,
    required this.grade,
    this.pause = defaultRehearsalPause,
    this.autoAdvance = false,
    this.advanceAfter = defaultAdvanceAfter,
    Future<void> Function(Duration)? wait,
  }) : _queue = [...cards],
       _wait = wait ?? ((d) => Future<void>.delayed(d));

  final InterviewerVoice voice;
  final Future<Flashcard?> Function(Flashcard card, Grade grade) grade;
  final Duration pause;
  final bool autoAdvance;
  final Duration advanceAfter;
  final Future<void> Function(Duration) _wait;
  final List<Flashcard> _queue;

  var _phase = RehearsalPhase.ready;
  var _graded = 0;
  final _notGraded = <Flashcard>[];
  var _stopped = false, _paused = false, _busy = false, _disposed = false;
  Completer<void> _interrupt = Completer<void>();
  Completer<void>? _resumed;
  Grade? _pending;
  Future<void>? _running;

  RehearsalPhase get phase => _phase;
  bool get isPaused => _paused;
  bool get isRunning => _running != null && _phase != RehearsalPhase.done;

  /// The card being read, null before the start and once finished.
  Flashcard? get current =>
      _phase == RehearsalPhase.ready || _phase == RehearsalPhase.done || _queue.isEmpty ? null : _queue.first;

  int get left => _queue.length;
  int get graded => _graded;

  /// Cards auto-advance moved past without a grade: still due.
  List<Flashcard> get notGraded => List.unmodifiable(_notGraded);

  /// Whether a tap may grade now: a card is being read and nothing else is
  /// being saved.
  bool get canGrade => current != null && !_paused && !_busy && !_stopped;

  /// Starts reading; the returned future ends when the rehearsal does.
  Future<void> start() => _running ??= _run();

  /// Grades the card being read and moves to the next.
  void gradeCurrent(Grade g) {
    if (!canGrade) return;
    _pending = g;
    _cut();
  }

  /// Stops the voice and holds on the current card.
  void pauseNow() {
    if (_paused || _stopped || current == null) return;
    _paused = true;
    _resumed = Completer<void>();
    _cut();
    _set(RehearsalPhase.paused);
  }

  /// Carries on from the start of the card that was paused.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _wake();
  }

  void _wake() {
    final r = _resumed;
    if (r != null && !r.isCompleted) r.complete();
  }

  /// Ends the rehearsal. Cards not graded keep their schedules.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _cut();
    _wake();
    await _running;
    if (_phase != RehearsalPhase.done) _set(RehearsalPhase.done);
  }

  void _cut() {
    if (!_interrupt.isCompleted) _interrupt.complete();
    unawaited(voice.stop().catchError((Object _) {}));
  }

  void _set(RehearsalPhase p) {
    _phase = p;
    if (!_disposed) notifyListeners();
  }

  /// Waits for [f] or an interruption; true when interrupted.
  Future<bool> _until(Future<void> f) async {
    await Future.any([f.catchError((Object _) {}), _interrupt.future]);
    return _interrupt.isCompleted;
  }

  Future<void> _run() async {
    try {
      while (!_stopped) {
        if (_paused) {
          await _resumed?.future;
          continue;
        }
        if (_queue.isEmpty) break;
        final c = _queue.first;
        _interrupt = Completer<void>();
        _pending = null;
        await _card(c);
        if (_stopped) break;
        if (_pending case final g?) {
          _busy = true;
          if (!_disposed) notifyListeners();
          Flashcard? again;
          try {
            again = await grade(c, g);
          } finally {
            _busy = false;
          }
          _queue.removeAt(0);
          if (again != null) _queue.add(again);
          _graded++;
          continue;
        }
        if (_paused) continue;
        // Auto-advance: no grade, the card stays due.
        _queue.removeAt(0);
        _notGraded.add(c);
      }
    } finally {
      _set(RehearsalPhase.done);
    }
  }

  Future<void> _card(Flashcard c) async {
    final q = spokenQuestion(c), a = spokenAnswer(c);
    voice.prepare(q);
    _set(RehearsalPhase.question);
    if (await _until(voice.say(q))) return;
    voice.prepare(a);
    _set(RehearsalPhase.pause);
    if (await _until(_wait(pause))) return;
    _set(RehearsalPhase.answer);
    if (await _until(voice.say(a))) return;
    _set(RehearsalPhase.waiting);
    if (_queue.length > 1) voice.prepare(spokenQuestion(_queue[1]));
    if (autoAdvance) {
      await _until(_wait(advanceAfter));
    } else {
      await _interrupt.future;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopped = true;
    _cut();
    _wake();
    super.dispose();
  }
}
