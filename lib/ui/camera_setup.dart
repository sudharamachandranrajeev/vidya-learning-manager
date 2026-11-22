/// The camera setup coach (opt-in): before a spoken round it checks your
/// face is in the picture, head and shoulders fit, the light is in front,
/// the camera is near eye height and the picture is steady. Delivery cues
/// only: nothing is scored, saved, sent or synced, and no video is kept.
library;

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart';

import '../app/interview_providers.dart';
import 'common.dart';
import 'zen.dart';

const cameraPrivacy =
    'Off unless you turn it on, every time. The picture is looked at on this device and dropped: never sent '
    'or synced, and saved only if you turn on video for a round. It checks your setup only. Nothing about '
    'your face, expression or eyes is read, and nothing is scored.';

/// The red "Camera on" pill. Tapping it turns the camera off.
class CameraOnPill extends StatelessWidget {
  const CameraOnPill(this.coach, {super.key});
  final CameraCoach coach;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Camera on. Turn the camera off',
    excludeSemantics: true,
    child: Material(
      color: KitStatus.critical.color,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: coach.turnOff,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text(
                'Camera on',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              SizedBox(width: 6),
              Icon(Icons.close, size: 16, color: Colors.white),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SetupRow extends StatelessWidget {
  const _SetupRow(this.r);
  final SetupResult r;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (r.ok) {
      true => (Icons.check_circle, KitStatus.good.color),
      false => (Icons.lightbulb_outline, KitStatus.warning.color),
      null => (Icons.more_horiz, KitStatus.info.color),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color, semanticLabel: r.ok == true ? 'Fine' : null),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.item.label, style: Theme.of(context).textTheme.labelLarge),
                Text(r.tip),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SelfView extends StatelessWidget {
  const _SelfView(this.coach, {this.height = 220});
  final CameraCoach coach;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = coach.feed?.preview();
    if (!coach.selfView || p == null) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: Center(
        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: p),
      ),
    );
  }
}

/// The setup check before a round: off until turned on.
class CameraSetupCard extends ConsumerStatefulWidget {
  const CameraSetupCard(this.coach, {super.key, required this.offline});
  final CameraCoach coach;

  /// Offline practice: the face model is not downloaded.
  final bool offline;

  @override
  ConsumerState<CameraSetupCard> createState() => _CameraSetupCardState();
}

class _CameraSetupCardState extends ConsumerState<CameraSetupCard> {
  double? _progress;

  Future<void> _turnOn() async {
    final cam = await ref.read(coachCameraProvider.future);
    if (!await cam.modelReady()) {
      final m = cam.model;
      if (!mounted) return;
      if (widget.offline) return notify(context, offlineDownloadMessage);
      final ok = await askSure(
        context,
        'Download ${m.label}?',
        'The setup check finds where your face is in the picture with this model: ${formatBytes(m.bytes)} '
            'from ${Uri.parse(m.url).host} (${m.source}). Licence: ${m.licence}. It is checked against its '
            'published SHA-256 and kept on this device only.',
        action: 'Download ${formatBytes(m.bytes)}',
      );
      if (!ok || !mounted) return;
      setState(() => _progress = 0);
      try {
        await cam.downloadModel(progress: (s) => mounted ? setState(() => _progress = s) : null);
      } on Object catch (e) {
        if (mounted) notify(context, describeError(e), status: KitStatus.warning);
        return;
      } finally {
        if (mounted) setState(() => _progress = null);
      }
    }
    await widget.coach.turnOn(cam);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.coach,
    builder: (context, _) {
      final c = widget.coach;
      final muted = Theme.of(context).textTheme.bodySmall;
      return SectionCard(
        title: 'Camera setup check (optional)',
        trailing: c.on ? CameraOnPill(c) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'For a video interview: checks your face is in the picture, head and shoulders fit, the light is '
              'in front of you, the camera is near eye height and the picture is steady.',
            ),
            const SizedBox(height: 4),
            Text(cameraPrivacy, style: muted),
            const SizedBox(height: 8),
            if (!c.on) ...[
              if (_progress != null)
                LinearProgressIndicator(value: _progress)
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: c.opening ? null : _turnOn,
                    icon: const Icon(Icons.videocam_outlined),
                    label: Text(c.opening ? 'Opening the camera…' : 'Turn the camera on'),
                  ),
                ),
              if (c.error case final e?) ...[
                const SizedBox(height: 8),
                Text(e, style: TextStyle(color: KitStatus.warning.color)),
              ],
            ] else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: c.turnOff,
                  icon: const Icon(Icons.videocam_off_outlined),
                  label: const Text('Turn the camera off'),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show my picture'),
                subtitle: const Text(
                  'Some people find seeing themselves distracting. The checks work either way.',
                ),
                value: c.selfView,
                onChanged: (v) => c.set(selfView: v),
              ),
              _SelfView(c),
              const SizedBox(height: 8),
              for (final r in c.results) _SetupRow(r),
              if (c.checker.allGood)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'All set for a video interview.',
                    style: TextStyle(color: KitStatus.good.color),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tell me if I leave the picture during the round'),
                subtitle: const Text('A quiet note after 3 seconds out of view.'),
                value: c.roundHints,
                onChanged: (v) => c.set(roundHints: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('"Looking at the lens" hint'),
                subtitle: const Text(
                  'From where your face sits in the picture only, not your eyes. Looking at the lens is optional: '
                  'customs differ, and it is never scored.',
                ),
                value: c.lensHint,
                onChanged: (v) => c.set(lensHint: v),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// During a round: the pill, the optional small self-view and the one
/// hint, if any. Nothing when the camera is off.
class CameraRoundBar extends StatelessWidget {
  const CameraRoundBar(this.coach, {super.key});
  final CameraCoach coach;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: coach,
    builder: (context, _) {
      if (!coach.on) return const SizedBox.shrink();
      final hint = coach.hint;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CameraOnPill(coach),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Setup hints only. Not part of any score.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (coach.selfView) ...[const SizedBox(height: 8), _SelfView(coach, height: 120)],
            if (hint != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: KitStatus.info.color),
                    const SizedBox(width: 6),
                    Expanded(child: Text(hint)),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
