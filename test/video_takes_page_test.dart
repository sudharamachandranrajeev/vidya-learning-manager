// Video takes in Vidya (J7) with a fake camera, microphone, player and AI:
// the switch is off every time and needs the camera; the red indicator
// shows while recording; clips are kept with the round; the debrief's
// "Watch this answer" and a tapped quote open the review at the right
// moment; Settings shows the space used, changes the days kept and deletes
// them all. Made-up plan and answers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:interview_engine/testing.dart';
import 'package:vidya/app/interview_providers.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/ui/interview_debrief_page.dart';
import 'package:vidya/ui/mpv_loader.dart';
import 'package:vidya/ui/video_playback.dart';
import 'package:vidya/ui/video_review_page.dart';

import 'app_harness.dart';

const said =
    'Last spring I trained twelve new starters on the booking system. I wrote a one-page guide and ran short '
    'practice sessions, and every starter booked an appointment on their own by Friday.';
const quote = 'I wrote a one-page guide and ran short practice sessions';

Future<void> _seed(LearningBook b) async {
  await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 2,
        'program': {'title': 'Approach: Example Trainer'},
        'role': 'Example Trainer',
        'criteria': [
          {'id': 'e1', 'text': 'Explain a new system to beginners', 'essential': true},
        ],
        'courses': [
          {
            'title': 'Teaching basics',
            'topics': [
              {
                'title': 'Explaining clearly',
                'criteria': ['e1'],
                'drills': [
                  {'question': 'Tell me about a time you taught a new system.', 'criterion': 'e1'},
                ],
              },
            ],
          },
        ],
      }),
    ),
    today: '2026-11-22',
  );
  await b.db.setLocalSetting(
    roundSettingsKey,
    jsonEncode({
      'round': const ie.RoundSettings(level: 1, aiPlan: false).toJson(),
      'framework': 'nhs_values',
    }),
  );
  await b.db.setLocalSetting('ai.help', jsonEncode({'via': 'anthropic'}));
}

Map<String, Object?> _judge(ie.BrainRequest r) => {
  'answers': [
    {
      'question': 1,
      'scores': [
        for (final m in RegExp(r'<criterion id="([^"]+)"').allMatches(r.texts.first))
          {'criterion': m[1], 'level': '3', 'quote': quote},
      ],
      'strength': 'You said what you did yourself.',
      'fix': 'Say how you checked it worked.',
    },
  ],
};

/// A player with no screen: records what it was asked to do.
class FakePlayback implements TakePlayback {
  static final opened = <ie.VideoTake>[];
  static final seeks = <Duration>[];
  static var plays = 0;

  /// Thrown by [open] when set, e.g. a missing libmpv.
  static Object? openError;

  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  @override
  final ValueNotifier<bool> playing = ValueNotifier(false);
  @override
  Duration duration = const Duration(seconds: 4);

  @override
  Future<void> open(ie.VideoTake take) async {
    if (openError case final e?) throw e;
    opened.add(take);
  }
  @override
  Future<void> play() async {
    plays++;
    playing.value = true;
  }

  @override
  Future<void> pause() async => playing.value = false;
  @override
  Future<void> seek(Duration video) async {
    seeks.add(video);
    position.value = video;
  }

  @override
  Widget? view() => const SizedBox(key: Key('fake-video'), width: 10, height: 10);
  @override
  Future<void> dispose() async {}
}

Future<void> _openInterviewer(AppHarness app) async {
  await app.go('Learn');
  await app.tapText('Approach: Example Trainer');
  await app.tapText('Teaching basics');
  await app.tapText('Explaining clearly');
  await app.tap(find.textContaining('Tell me about a time you taught'));
  await app.tap(find.widgetWithText(FilledButton, 'Practise with the interviewer'));
}

SwitchListTile _videoSwitch(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.byKey(const Key('record-video')));

void main() {
  testWidgets('video takes: opt-in per round, indicator, kept clip, seek from a quote, settings', (
    tester,
  ) async {
    final tmp = (await tester.runAsync(() => Directory.systemTemp.createTemp('vidya-video-ui-')))!;
    addTearDown(() => tmp.delete(recursive: true));
    final store = ie.VideoTakeStore(Directory('${tmp.path}/video-takes'));
    final recorder = FakeVideoRecorder(Directory('${tmp.path}/camera'));
    final engines = FakeSpokenEngines(answers: [spokenAnswer(said)]);
    final brain = ScriptedBrain(_judge);
    FakePlayback.opened.clear();
    FakePlayback.seeks.clear();
    final app = AppHarness(tester)..desktop();
    await app.open(seed: _seed);
    await app.run(
      overrides: [
        spokenEnginesProvider.overrideWith((ref) async => engines),
        modelSharingProvider.overrideWith((ref) async => ''),
        coachCameraProvider.overrideWith((ref) async => FakeCamera(recorder: recorder)),
        interviewBrainProvider.overrideWithValue(({required bool offline}) async => brain),
        videoTakeStoreProvider.overrideWith((ref) async => store),
        takePlaybackProvider.overrideWithValue(FakePlayback.new),
      ],
    );
    await _openInterviewer(app);

    // Off, and unusable until the camera is on.
    expect(_videoSwitch(tester).value, isFalse);
    expect(_videoSwitch(tester).onChanged, isNull);
    expect(find.textContaining('Turn the camera on above first'), findsOneWidget);
    expect(
      find.textContaining('deleted after 14 days. Never synced, backed up or sent to an AI'),
      findsWidgets,
    );
    await app.tapText('Turn the camera on');
    expect(_videoSwitch(tester).value, isFalse, reason: 'the camera alone does not record');
    await app.tap(find.byKey(const Key('record-video')));
    expect(_videoSwitch(tester).value, isTrue);

    await app.tapText('Start speaking');
    expect(find.text('Video on for this round'), findsOneWidget);
    await app.tapText('Ask me');
    expect(find.text('Recording video'), findsOneWidget, reason: 'the indicator shows while recording');
    expect(recorder.recording, isTrue);
    for (var i = 0; i < 6 && find.text('Finish').evaluate().isEmpty; i++) {
      if (find.text('Done').evaluate().isNotEmpty) await app.tapText('Done');
      await app.settle();
    }
    expect(find.text('Recording video'), findsNothing);
    final clips = (await tester.runAsync(() => store.list()))!;
    expect(clips, isNotEmpty);
    expect(clips.first.question, 0);
    expect(clips.first.part, 0);
    expect(clips.first.audioPath, isNotNull, reason: 'the answer\'s audio is kept with the picture');
    await app.tapText('Finish');
    expect(find.textContaining('kept with this round'), findsOneWidget);
    await app.tapText('See the debrief');
    expect(find.byType(InterviewDebriefPage), findsOneWidget);
    expect(engines.store.kept, isEmpty, reason: 'audio-only takes still go with the round screen');
    expect((await tester.runAsync(() => store.list()))!, hasLength(clips.length), reason: 'video stays');

    // Score, then tap the quoted line: the review opens where it was said.
    await app.tap(find.textContaining('Score on the scale with'));
    final mainClip = clips.firstWhere((c) => c.part == 0);
    final expected = ie.seekToQuote(clips, quote)!;
    expect(expected.take.id, mainClip.id);
    expect(
      find.byIcon(Icons.play_circle_outline),
      findsWidgets,
      reason: 'quoted lines with video can be played',
    );
    await app.tap(find.byIcon(Icons.play_circle_outline).first);
    expect(find.byType(VideoReviewPage), findsOneWidget);
    expect(FakePlayback.opened.last.id, mainClip.id);
    expect(FakePlayback.seeks, contains(expected.video));
    expect(find.byKey(const Key('fake-video')), findsOneWidget);
    expect(find.text('Explain a new system to beginners'), findsWidgets, reason: 'criteria beside the video');

    // A transcript line seeks to its own start.
    await app.tap(find.byKey(const Key('video-line-0')));
    expect(FakePlayback.seeks.last, mainClip.videoAt(mainClip.segments.first.start));
    expect(FakePlayback.plays, greaterThan(0));
    await tester.pageBack();
    await app.settle();

    // "Watch this answer" opens the same screen.
    await app.tap(find.byKey(const Key('watch-0')));
    expect(find.byType(VideoReviewPage), findsOneWidget);
    await tester.pageBack();
    await app.settle();

    // Without libmpv only this screen says so, with how to install it.
    FakePlayback.openError = const MpvMissing();
    addTearDown(() => FakePlayback.openError = null);
    await app.tap(find.byKey(const Key('watch-0')));
    expect(find.textContaining('Install mpv (libmpv) to play takes'), findsOneWidget);
    expect(find.byKey(const Key('fake-video')), findsNothing);
    FakePlayback.openError = null;
    await tester.pageBack();
    await app.settle();
    await tester.pageBack();
    await app.settle();
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('Settings: space used, days kept and delete all; the switch is off again next time', (
    tester,
  ) async {
    final tmp = (await tester.runAsync(() => Directory.systemTemp.createTemp('vidya-video-settings-')))!;
    addTearDown(() => tmp.delete(recursive: true));
    final store = ie.VideoTakeStore(Directory('${tmp.path}/video-takes'));
    await tester.runAsync(() async {
      final cam = File('${tmp.path}/cam.mp4')..writeAsBytesSync(List.filled(4096, 1));
      await store.save(
        roundId: 'r1',
        question: 0,
        take: 1,
        recorded: cam.path,
        segments: [ie.SpokenSegment(Duration.zero, const Duration(seconds: 2), 'Hello.')],
      );
    });
    final app = AppHarness(tester)..desktop();
    await app.open(seed: _seed);
    await app.run(
      overrides: [
        spokenEnginesProvider.overrideWith((ref) async => FakeSpokenEngines()),
        modelSharingProvider.overrideWith((ref) async => ''),
        coachCameraProvider.overrideWith(
          (ref) async => FakeCamera(recorder: FakeVideoRecorder(Directory('${tmp.path}/camera'))),
        ),
        interviewBrainProvider.overrideWithValue(({required bool offline}) async => null),
        videoTakeStoreProvider.overrideWith((ref) async => store),
        takePlaybackProvider.overrideWithValue(FakePlayback.new),
      ],
    );
    await app.go('Settings');
    await tester.ensureVisible(find.byKey(const Key('video-storage')));
    await app.settle();
    // The folder is read with real file I/O.
    await app.settle();
    await app.settle();
    expect(find.textContaining('1 video take · 4'), findsOneWidget);

    await app.tap(find.byKey(const Key('video-keep-days')));
    await app.tap(find.text('3 days').last);
    expect(await tester.runAsync(() => app.book.db.localSetting(VideoKeepDays.key)), '3');
    expect(find.textContaining('deleted after 3 days'), findsOneWidget);

    await app.tap(find.byKey(const Key('video-delete-all')));
    expect(find.text('Delete all video takes?'), findsOneWidget);
    await app.tapText('Delete all');
    expect((await tester.runAsync(() => store.list()))!, isEmpty);
    expect(find.text('No video takes on this device.'), findsOneWidget);

    // The opt-in is never remembered: off again on the next visit.
    await _openInterviewer(app);
    await app.tapText('Turn the camera on');
    expect(_videoSwitch(tester).value, isFalse);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
