/// Plays a video take (J7): the picture, which has no sound of its own,
/// with the round's own recording of the answer, kept in step.
///
/// - Linux and Windows: media_kit (libmpv). The audio file is added as an
///   external track and `audio-delay` lines it up with the picture, so mpv
///   keeps the two together.
/// - Android: video_player shows the picture and audioplayers plays the
///   audio; play, pause and seek move both.
///
/// Only files on this device are opened; nothing streams.
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' show VideoTake;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart' as vp;

import 'mpv_loader.dart';

/// One take's player. [position] is the moment in the video.
abstract class TakePlayback {
  Future<void> open(VideoTake take);
  Future<void> play();
  Future<void> pause();

  /// Moves to [video] (a moment in the picture); the audio follows.
  Future<void> seek(Duration video);

  ValueListenable<Duration> get position;
  ValueListenable<bool> get playing;
  Duration get duration;

  /// The picture; null before [open] finished.
  Widget? view();
  Future<void> dispose();
}

/// Makes the player for this platform. Tests override it with a fake.
final takePlaybackProvider = Provider<TakePlayback Function()>(
  (ref) =>
      () => Platform.isAndroid || Platform.isIOS ? PhoneTakePlayback() : DesktopTakePlayback(),
);

/// media_kit on Linux and Windows. libmpv is loaded on first use
/// ([ensureMpvLoaded]), so a missing library is reported on this screen and
/// nowhere else; Vidya itself starts without it.
class DesktopTakePlayback implements TakePlayback {
  mk.Player? _player;
  mkv.VideoController? _controller;
  final _subs = <StreamSubscription<Object?>>[];
  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  @override
  final ValueNotifier<bool> playing = ValueNotifier(false);
  @override
  Duration duration = Duration.zero;

  @override
  Future<void> open(VideoTake take) async {
    ensureMpvLoaded();
    mk.MediaKit.ensureInitialized();
    final p = _player = mk.Player();
    _controller = mkv.VideoController(p);
    _subs
      ..add(p.stream.position.listen((d) => position.value = d))
      ..add(p.stream.playing.listen((b) => playing.value = b))
      ..add(p.stream.duration.listen((d) => duration = d));
    await p.open(mk.Media(take.videoPath), play: false);
    if (take.audioPath case final a?) {
      await p.setAudioTrack(mk.AudioTrack.uri(a, title: 'answer'));
      // Audio position = video position + lead: the audio runs that much
      // ahead, which mpv calls a negative audio delay.
      if (p.platform case final mk.NativePlayer n) {
        await n.setProperty('audio-delay', (-take.audioLead.inMilliseconds / 1000).toStringAsFixed(3));
      }
    }
  }

  @override
  Future<void> play() async => _player?.play();
  @override
  Future<void> pause() async => _player?.pause();
  @override
  Future<void> seek(Duration video) async => _player?.seek(video);

  @override
  Widget? view() => _controller == null
      ? null
      : mkv.Video(controller: _controller!, controls: mkv.NoVideoControls, fill: Colors.black);

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _player?.dispose();
    position.dispose();
    playing.dispose();
  }
}

/// video_player for the picture and audioplayers for the sound, on a phone.
class PhoneTakePlayback implements TakePlayback {
  vp.VideoPlayerController? _video;
  ap.AudioPlayer? _audio;
  Duration _lead = Duration.zero;
  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  @override
  final ValueNotifier<bool> playing = ValueNotifier(false);
  @override
  Duration duration = Duration.zero;

  void _onVideo() {
    final v = _video!.value;
    position.value = v.position;
    duration = v.duration;
    if (playing.value != v.isPlaying) {
      playing.value = v.isPlaying;
      if (!v.isPlaying) unawaited(_audio?.pause());
    }
  }

  @override
  Future<void> open(VideoTake take) async {
    final v = _video = vp.VideoPlayerController.file(File(take.videoPath));
    await v.initialize();
    v.addListener(_onVideo);
    _lead = take.audioLead;
    if (take.audioPath case final a?) {
      final p = _audio = ap.AudioPlayer();
      await p.setSource(ap.DeviceFileSource(a));
    }
  }

  @override
  Future<void> play() async {
    final at = _video?.value.position ?? Duration.zero;
    await _audio?.seek(at + _lead);
    await Future.wait([?_video?.play(), ?_audio?.resume()]);
  }

  @override
  Future<void> pause() async => Future.wait([?_video?.pause(), ?_audio?.pause()]);

  @override
  Future<void> seek(Duration video) async =>
      Future.wait([?_video?.seekTo(video), ?_audio?.seek(video + _lead)]);

  @override
  Widget? view() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return null;
    return AspectRatio(aspectRatio: v.value.aspectRatio, child: vp.VideoPlayer(v));
  }

  @override
  Future<void> dispose() async {
    _video?.removeListener(_onVideo);
    await _video?.dispose();
    await _audio?.dispose();
    position.dispose();
    playing.dispose();
  }
}
