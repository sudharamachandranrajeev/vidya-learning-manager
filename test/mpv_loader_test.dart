import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/ui/mpv_loader.dart';

void main() {
  test('a missing libmpv is a clear message, not a crash', () {
    expect(
      () => ensureMpvLoaded(names: ['libmpv-not-installed.so.9'], linux: true),
      throwsA(isA<MpvMissing>()),
    );
    expect(MpvMissing.message, contains('Install mpv (libmpv) to play takes'));
    expect(MpvMissing.message, contains('Vidya works without it'));
  });

  test('a library that is present loads; other platforms skip it', () {
    // libc is always there: stands in for libmpv to prove the dlopen path.
    expect(() => ensureMpvLoaded(names: ['libc.so.6'], linux: true), returnsNormally);
    expect(() => ensureMpvLoaded(names: ['libmpv-not-installed.so.9'], linux: false), returnsNormally);
  });
}
