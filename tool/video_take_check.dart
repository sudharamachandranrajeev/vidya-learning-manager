// J7 device check: records one real video take with the camera while the
// microphone records the answer's WAV, the way a round does, then plays it
// back with the app's player. Prints what it found as JSON. Not part of
// the app.
//
//   flutter build linux --release -t tool/video_take_check.dart
//   build/linux/x64/release/bundle/vidya [--seconds 6] [--keep] [--out result.json]
//
//   (Android, phone connected: flutter run --release -t tool/video_take_check.dart)
//
// Say a sentence while it records. It checks that:
// - the camera recorded a file with a picture track and NO sound track
//   (the WAV from `record` is the only audio; one microphone capture);
// - set-up frames kept arriving while recording (Linux and Windows always;
//   on Android this shows whether the camera streams and records at once,
//   else the cues pause), and how many arrived;
// - the clip, its WAV and its timestamps landed in the app's own folder
//   (video-takes-check under the app support folder) and nowhere else;
// - the player opened it, played, and the position moved;
// - the take is deleted afterwards (unless --keep).
//
// The BlazeFace model must already be on this device: turn the camera on
// once in Vidya's mock interview (or Udyoga's lab) first.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:interview_engine/interview_engine.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vidya/ui/video_playback.dart';

/// The track handler types in an MP4/MOV file ('vide', 'soun', …), read
/// from each `hdlr` box; Matroska files are checked by codec id instead.
List<String> trackKinds(Uint8List b) {
  final out = <String>[];
  final hdlr = ascii.encode('hdlr');
  for (var i = 0; i + 16 < b.length; i++) {
    if (b[i] == hdlr[0] && b[i + 1] == hdlr[1] && b[i + 2] == hdlr[2] && b[i + 3] == hdlr[3]) {
      // hdlr: size(4) 'hdlr' version+flags(4) pre_defined(4) handler_type(4)
      out.add(ascii.decode(b.sublist(i + 12, i + 16), allowInvalid: true));
    }
  }
  if (out.isEmpty) {
    final s = latin1.decode(b, allowInvalid: true);
    if (s.contains('V_MPEG4')) out.add('vide');
    if (s.contains('A_OPUS') || s.contains('A_AAC') || s.contains('A_MPEG')) out.add('soun');
  }
  return out;
}

Future<List<String>> filesUnder(Directory d) async => !await d.exists()
    ? const []
    : [
        await for (final e in d.list(recursive: true))
          if (e is File) e.path,
      ];

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final seconds = int.tryParse(arg('--seconds') ?? '') ?? 6;
  final keep = args.contains('--keep');
  final out = arg('--out');
  final result = <String, Object?>{'platform': Platform.operatingSystem, 'seconds': seconds};
  final view = ValueNotifier<Widget>(const Center(child: Text('Recording… say a sentence.')));
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Vidya video take check')),
        body: ValueListenableBuilder<Widget>(valueListenable: view, builder: (_, w, _) => w),
      ),
    ),
  );

  var ok = true;
  void fail(String why) {
    ok = false;
    ((result['problems'] ??= <String>[]) as List<String>).add(why);
  }

  final base = await getApplicationSupportDirectory();
  final root = Directory('${base.path}/video-takes-check');
  FaceCamera? cam;
  try {
    final shared = sharedModelFolder();
    final mm = ModelManager(shared ?? Directory('${base.path}/models'));
    final model = speechModel(faceModelId);
    if (!await mm.installed(model)) {
      throw StateError('The BlazeFace model is not on this device. Turn the camera on once in Vidya first.');
    }
    cam = await FaceCamera.open(mm.path(model));
    final store = VideoTakeStore(root);
    final recorder = _Recorder(cam);
    final video = RoundVideo(roundId: 'device-check', recorder: recorder, store: store);

    var framesWhileRecording = 0;
    void onFrame() {
      if (video.recording) framesWhileRecording++;
    }

    cam.measure.addListener(onFrame);
    final audio = RecordMic().record(Duration(seconds: seconds));
    await video.answerStarted();
    if (video.error case final e?) throw StateError(e);
    final pcm = await audio;
    final take = await video.answerKept(
      question: 0,
      take: 1,
      part: 0,
      answer: CapturedAnswer(pcm, [SpokenSegment(Duration.zero, pcm.length, 'device check')]),
    );
    cam.measure.removeListener(onFrame);
    if (take == null) throw StateError(video.error ?? 'no take was kept');

    final bytes = await File(take.videoPath).readAsBytes();
    final kinds = trackKinds(bytes);
    result.addAll({
      'video': take.videoPath,
      'videoBytes': bytes.length,
      'tracks': kinds,
      'audioWav': take.audioPath,
      'audioSeconds': pcm.length.inMilliseconds / 1000,
      'audioPeakDbfs': peakDbfs(pcm).toStringAsFixed(1),
      'audioLeadMs': take.audioLead.inMilliseconds,
      'framesWhileRecording': framesWhileRecording,
      'cuesPausedWhileRecording': recorder.pausedSeen,
    });
    if (bytes.length < 1000) fail('the video file is nearly empty');
    if (!kinds.contains('vide')) fail('no picture track found');
    if (kinds.contains('soun')) fail('the video has its own sound track: the microphone was opened twice');
    if (framesWhileRecording == 0 && !recorder.pausedSeen) fail('no set-up frames arrived while recording');
    if (peakDbfs(pcm) < -50) fail('the microphone heard almost nothing');

    final files = await filesUnder(root);
    result['filesInStore'] = files.length;
    if (files.any((f) => !f.startsWith(root.path))) fail('a file landed outside the store');

    // Playback with the app's own player.
    final player = Platform.isAndroid || Platform.isIOS ? PhoneTakePlayback() : DesktopTakePlayback();
    try {
      await player.open(take);
      view.value = Column(
        children: [
          Expanded(child: Center(child: player.view() ?? const Text('no picture'))),
          const Padding(padding: EdgeInsets.all(8), child: Text('Playing back: you should hear yourself.')),
        ],
      );
      await player.seek(Duration.zero);
      await player.play();
      await Future<void>.delayed(const Duration(seconds: 3));
      final pos = player.position.value;
      await player.seek(take.videoAt(const Duration(seconds: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      result['playback'] = {
        'positionAfter3sMs': pos.inMilliseconds,
        'durationMs': player.duration.inMilliseconds,
        'positionAfterSeekMs': player.position.value.inMilliseconds,
      };
      if (pos <= Duration.zero) fail('playback did not move');
      await player.pause();
    } on Object catch (e) {
      fail('playback failed: $e');
    } finally {
      await player.dispose();
    }
    if (!keep) {
      await store.deleteAll();
      result['deletedAfter'] = !await root.exists();
    }
  } on Object catch (e) {
    fail('$e');
  } finally {
    await cam?.close();
  }
  result['ok'] = ok;
  final json = const JsonEncoder.withIndent('  ').convert(result);
  stdout.writeln(json);
  if (out != null) await File(out).writeAsString(json);
  view.value = SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(json));
  if (!args.contains('--stay')) exit(ok ? 0 : 1);
}

class _Recorder implements VideoRecorder {
  _Recorder(this._cam);
  final FaceCamera _cam;
  bool pausedSeen = false;

  @override
  bool get pausesCues => _cam.cuesPaused;

  @override
  Future<void> start() async {
    await _cam.startRecording();
    pausedSeen = _cam.cuesPaused;
  }

  @override
  Future<String> stop() => _cam.stopRecording();

  @override
  Future<void> cancel() async {
    final f = await _cam.stopRecording();
    await File(f).delete();
  }
}
