/// Loads mpv's library (libmpv) on Linux only when a video take is played.
///
/// Vidya starts without libmpv: linux/CMakeLists.txt removes media_kit_video's
/// link to it, so its plugin's mpv_* calls are left to bind lazily. Before the
/// first take plays, [ensureMpvLoaded] opens libmpv with RTLD_GLOBAL, which
/// makes those calls (and media_kit's own) find it. When libmpv is missing,
/// [MpvMissing] is thrown and only the playback screen shows the message.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// libmpv is not installed, so takes cannot be played on this computer.
class MpvMissing implements Exception {
  const MpvMissing();

  static const message =
      'Install mpv (libmpv) to play takes. Arch: sudo pacman -S mpv. '
      'Debian or Ubuntu: sudo apt install libmpv2. Fedora: sudo dnf install mpv-libs. '
      'Vidya works without it; only video playback needs it.';

  @override
  String toString() => message;
}

/// The names libmpv goes by, newest first.
const mpvLibraryNames = ['libmpv.so.2', 'libmpv.so', 'libmpv.so.1'];

const _rtldNow = 0x2;
const _rtldGlobal = 0x100;

bool _loaded = false;

/// Opens libmpv into the global symbol scope once. Not Linux: nothing to do
/// (Windows bundles its own copy; Android uses video_player). [names] is for
/// tests.
void ensureMpvLoaded({List<String> names = mpvLibraryNames, bool? linux}) {
  if (!(linux ?? Platform.isLinux)) return;
  if (_loaded && identical(names, mpvLibraryNames)) return;
  final dlopen = DynamicLibrary.process()
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)
      >('dlopen');
  for (final name in names) {
    final c = name.toNativeUtf8(allocator: calloc);
    try {
      if (dlopen(c, _rtldNow | _rtldGlobal) != nullptr) {
        if (identical(names, mpvLibraryNames)) _loaded = true;
        return;
      }
    } finally {
      calloc.free(c);
    }
  }
  throw const MpvMissing();
}
