/// The spoken interviewer's device pieces: the speech models, the speech
/// engines, the camera for the setup check, the AI for scoring and this
/// device's interview settings. Tests override the engines, the camera and
/// the brain with fakes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/spoken_interview.dart';
import 'providers.dart';

/// The speech models: on a desktop in the folder shared with Udyoga (one
/// copy for both apps), on a phone in Vidya's own folder.
final modelManagerProvider = FutureProvider<ModelManager>((ref) async {
  final base = await getApplicationSupportDirectory();
  final own = Directory('${base.path}/models');
  final shared = sharedModelFolder();
  if (shared != null) {
    try {
      await adoptModels(from: own, to: shared);
    } on FileSystemException {
      // Left where they are; the download is offered again.
    }
  }
  final mm = ModelManager(
    shared ?? own,
    client: ref.watch(httpClientProvider),
    voiceCache: Directory('${base.path}/voice-cache'),
  );
  if (shared != null) {
    try {
      // So Udyoga's screens can say the models are shared with Vidya.
      await mm.registerUser('vidya');
    } on FileSystemException {
      // Only a note for the other app.
    }
  }
  return mm;
});

/// Whether the models are shared with Udyoga, in one sentence.
final modelSharingProvider = FutureProvider<String>((ref) async {
  final mm = await ref.watch(modelManagerProvider.future);
  final shared = sharedModelFolder() != null;
  return modelSharingNote(app: 'vidya', shared: shared, users: shared ? await mm.users() : const []);
});

/// The device's speech engines: Kokoro's voice, the speech detector and
/// Moonshine's transcripts. Recordings go in a folder deleted with the
/// round screen.
final spokenEnginesProvider = FutureProvider<SpokenEngines>((ref) async {
  final mm = await ref.watch(modelManagerProvider.future);
  final base = await getApplicationSupportDirectory();
  return NativeSpokenEngines(
    mm,
    Directory('${base.path}/interview-takes'),
    voiceCache: Directory('${base.path}/voice-cache'),
  );
});

/// Opt-in video takes (J7) live here: the app's own private folder, never
/// synced, and excluded from Android backup and device-to-device transfer
/// (android/app/src/main/res/xml/data_extraction_rules.xml).
const videoTakesFolder = 'video-takes';

final videoTakeStoreProvider = FutureProvider<VideoTakeStore>((ref) async {
  final base = await getApplicationSupportDirectory();
  return VideoTakeStore(Directory('${base.path}/$videoTakesFolder'));
});

/// How many days video takes are kept on this device (a local setting,
/// never synced). [VideoTakeStore.defaultKeepDays] unless changed.
final videoKeepDaysProvider = AsyncNotifierProvider<VideoKeepDays, int>(VideoKeepDays.new);

class VideoKeepDays extends AsyncNotifier<int> {
  static const key = 'interview.videoKeepDays';

  @override
  Future<int> build() async {
    final raw = await ref.watch(sessionProvider).db.localSetting(key);
    final n = int.tryParse(raw ?? '');
    return n == null
        ? VideoTakeStore.defaultKeepDays
        : n.clamp(VideoTakeStore.minKeepDays, VideoTakeStore.maxKeepDays);
  }

  Future<void> set(int days) async {
    final n = days.clamp(VideoTakeStore.minKeepDays, VideoTakeStore.maxKeepDays);
    state = AsyncData(n);
    await ref.read(sessionProvider).db.setLocalSetting(key, '$n');
    // A shorter limit applies at once.
    try {
      await (await ref.read(videoTakeStoreProvider.future)).purge(keepDays: n);
    } on Object {
      // The daily run tries again.
    }
    ref.invalidate(videoTakesProvider);
  }
}

/// Where the camera plugins leave a recording before it is moved into the
/// store: the system temporary folder on Linux and Windows, the app's cache
/// on Android.
Future<List<Directory>> recorderTempDirs() async {
  final dirs = [Directory.systemTemp];
  try {
    final t = await getTemporaryDirectory();
    if (t.path != Directory.systemTemp.path) dirs.add(t);
  } on Object {
    // No platform folder (tests): the system one is enough.
  }
  return dirs;
}

/// When the app starts: sweeps what a crash or failed save left (half-moved
/// clips, stale camera temporary files), then deletes video takes past the
/// limit, and again daily.
final videoRetentionProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(videoTakeStoreProvider.future);
  final retention = VideoRetention(
    store,
    () => ref.read(videoKeepDaysProvider.future),
    recorderTemps: await recorderTempDirs(),
  );
  ref.onDispose(retention.stop);
  final gone = await retention.start();
  if (gone > 0) ref.invalidate(videoTakesProvider);
  return gone;
});

/// The video takes kept for a round (all rounds when null), oldest first.
/// Empty where there is no store (tests, a failed folder).
final videoTakesProvider = FutureProvider.family<List<VideoTake>, String?>((ref, roundId) async {
  try {
    final store = await ref.watch(videoTakeStoreProvider.future);
    return await store.list(roundId: roundId);
  } on Object {
    return const [];
  }
});

/// The camera for the opt-in setup check.
final coachCameraProvider = FutureProvider<CoachCamera>(
  (ref) async => NativeCoachCamera(await ref.watch(modelManagerProvider.future)),
);

/// Builds the interview brain over the Ask AI setting, or null when no AI
/// may score ([interviewAiUsable]).
final interviewBrainProvider = Provider<Future<InterviewBrain?> Function({required bool offline})>((ref) {
  return ({required bool offline}) async {
    final setup = await ref.read(helpAiProvider.future);
    if (!interviewAiUsable(setup, offline: offline)) return null;
    final asker = await ref.read(helpAskerProvider)(setup);
    return VidyaInterviewBrain((system, text) => asker.ask(system, [(user: true, text: text)]));
  };
});

/// This device's interview settings (offline practice, captions). Kept in
/// a local setting: never synced.
final interviewDeviceProvider = AsyncNotifierProvider<InterviewDeviceSettings, InterviewDevice>(
  InterviewDeviceSettings.new,
);

class InterviewDeviceSettings extends AsyncNotifier<InterviewDevice> {
  static const key = 'interview.device';

  @override
  Future<InterviewDevice> build() async =>
      InterviewDevice.fromJson(await readLocalJson(ref.watch(sessionProvider).db, key));

  Future<void> save(InterviewDevice d) async {
    state = AsyncData(d);
    await ref.read(sessionProvider).db.setLocalSetting(key, jsonEncode(d.toJson()));
  }
}

/// A local setting holding JSON, or an empty map.
Future<Map<String, Object?>> readLocalJson(SyncedDatabase db, String key) async {
  final raw = await db.localSetting(key);
  if (raw == null || raw.isEmpty) return const {};
  try {
    final j = jsonDecode(raw);
    return j is Map ? j.cast<String, Object?>() : const {};
  } on FormatException {
    return const {};
  }
}

/// Local setting keys: the last round settings, framework and camera
/// switches on this device.
const roundSettingsKey = 'interview.round';
const coachPrefsKey = 'interview.coach';
