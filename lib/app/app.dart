import 'dart:async';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/common.dart';
import '../ui/zen.dart';
import 'interview_providers.dart';
import 'modules.dart';
import 'providers.dart';
import 'reminders.dart';

class VidyaApp extends StatelessWidget {
  const VidyaApp({super.key, this.home = const _Root()});
  final Widget home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vidya',
    debugShowCheckedModeBanner: false,
    theme: vidyaTheme(Brightness.light),
    darkTheme: vidyaTheme(Brightness.dark),
    builder: (context, child) => AppLockGate(
      child: Backdrop(
        child: KitShadBridge(fontFamily: bodyFont, child: child ?? const SizedBox.shrink()),
      ),
    ),
    home: home,
  );
}

/// The app, opening the links the platform hands over (a scanned pairing
/// code).
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) => const LinkHandler(child: VidyaHome());
}

/// Vidya's screens. There is no onboarding: Home says what to do first.
/// Each achievement a write earns is announced once, quietly. [onHome]
/// leads back to the Brahma suite's home screen when the suite hosts Vidya.
/// Opening the app, or coming back to it, sends progress to Udyoga (at most
/// once per ten minutes).
class VidyaHome extends ConsumerStatefulWidget {
  const VidyaHome({super.key, this.onHome});
  final VoidCallback? onHome;

  @override
  ConsumerState<VidyaHome> createState() => _VidyaHomeState();
}

class _VidyaHomeState extends ConsumerState<VidyaHome> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    final reporter = ref.read(progressReporterProvider);
    _life = AppLifecycleListener(onResume: () => unawaited(reporter.request()));
    unawaited(reporter.request());
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(reminderSyncProvider);
    // Video takes past their limit go at start and then daily.
    ref.watch(videoRetentionProvider);
    ref.watch(guideSplitProvider);
    ref.watch(reviewPullProvider);
    ref.listen(careerFileAutoAddProvider, (_, next) {
      final titles = next.value ?? const <String>[];
      if (titles.isEmpty) return;
      notify(context, 'Added from your career file: ${titles.join(', ')}', status: KitStatus.good);
    });
    ref.listen(celebrationsProvider, (_, list) {
      if (list.isEmpty) return;
      final text = list.length == 1
          ? 'Achievement earned: ${list.first.title}'
          : 'Achievements earned: ${list.map((a) => a.title).join(', ')}';
      ref.read(celebrationsProvider.notifier).clear();
      notify(context, '🏅 $text', status: KitStatus.good);
    });
    return AppShell(destinations: allDestinations, floating: true, onHome: widget.onHome);
  }
}
