// Fix from J10: a camera clip left in the system temporary folder by a crash
// is deleted when Vidya next starts (the retention provider's sweep).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart';
import 'package:vidya/app/interview_providers.dart';

class _Days extends VideoKeepDays {
  @override
  Future<int> build() async => 14;
}

void main() {
  test('start-up sweeps a stale camera clip and a half-moved take', () async {
    final tmp = await Directory.systemTemp.createTemp('vidya-sweep-');
    addTearDown(() => tmp.delete(recursive: true));
    final stale = File('${Directory.systemTemp.path}/camera_desktop_97_${pid}9.mp4')..writeAsBytesSync([1]);
    addTearDown(() async {
      if (await stale.exists()) await stale.delete();
    });
    stale.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    final store = VideoTakeStore(Directory('${tmp.path}/video-takes'));
    final part = File('${store.root.path}/r1/.q1-t1-p0-5.mp4.part')..createSync(recursive: true);

    final c = ProviderContainer(
      overrides: [
        videoTakeStoreProvider.overrideWith((ref) async => store),
        videoKeepDaysProvider.overrideWith(_Days.new),
      ],
    );
    addTearDown(c.dispose);
    await c.read(videoRetentionProvider.future);

    expect(stale.existsSync(), isFalse);
    expect(part.existsSync(), isFalse);
    expect(
      await recorderTempDirs(),
      contains(predicate<Directory>((d) => d.path == Directory.systemTemp.path)),
    );
  });
}
