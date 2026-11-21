import 'dart:convert';
import 'dart:typed_data';

import 'package:brahma_core/brahma_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/export.dart';
import '../domain/review.dart';
import '../ui/common.dart';
import '../ui/dialogs.dart';
import '../domain/udyoga_link.dart';
import 'providers.dart';
import 'reminders.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const PageScaffold(
    title: 'Settings',
    children: [
      _StreaksCard(),
      _WeekTargetCard(),
      _PaceCard(),
      _RemindersCard(),
      _CareerFileCard(),
      _HistoryCard(),
      AppLockCard(),
      HintsCard(),
      SyncCard(),
      SecurityCard(
        network:
            'Vidya makes no network requests of its own. It talks to your sync server only if you sign in.',
      ),
      AboutCard(
        description:
            'Learning and knowledge management: programs, courses, skills, portfolio, notes and progress.',
      ),
    ],
  );
}

/// Streaks are opt-in: off, no day count is shown anywhere. Achievements
/// are not affected.
class _StreaksCard extends ConsumerWidget {
  const _StreaksCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Streaks',
    padding: const EdgeInsets.only(bottom: 8),
    child: SwitchListTile(
      title: const Text('Show day streaks'),
      subtitle: const Text(
        'Count days in a row on Home and Progress. Off by default; achievements stay either way.',
      ),
      value: ref.watch(showStreaksProvider).value ?? false,
      onChanged: (v) => ref.read(showStreaksProvider.notifier).set(v),
    ),
  );
}

/// Review pace: three named presets over the flashcard schedule, so nobody
/// has to tune ease factors or intervals.
class _PaceCard extends ConsumerWidget {
  const _PaceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pace = ref.watch(reviewPaceProvider).value ?? ReviewPace.standard;
    return SectionCard(
      title: 'Review pace',
      padding: const EdgeInsets.only(bottom: 8),
      child: RadioGroup<ReviewPace>(
        groupValue: pace,
        onChanged: (p) {
          if (p != null) ref.read(reviewPaceProvider.notifier).set(p);
        },
        child: Column(
          children: [
            for (final p in ReviewPace.values)
              RadioListTile<ReviewPace>(value: p, title: Text(p.label), subtitle: Text(p.about)),
          ],
        ),
      ),
    );
  }
}

/// Review reminders: on this device only, at a time and a weekly limit the
/// learner sets once. Each is tied to cards that are due.
class _RemindersCard extends ConsumerWidget {
  const _RemindersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(reminderSchedulerProvider).supported;
    final s = ref.watch(remindersProvider).value ?? const ReminderSettings();
    final notifier = ref.read(remindersProvider.notifier);
    return SectionCard(
      title: 'Reminders',
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Remind me to review'),
            subtitle: Text(
              supported
                  ? 'A notification from this device when cards are due. Nothing is sent from a server.'
                  : 'Available on Android.',
            ),
            value: supported && s.enabled,
            onChanged: supported
                ? (v) async {
                    final ok = await notifier.setEnabled(v);
                    if (!ok && context.mounted) {
                      showMessage(context, 'Allow notifications for Vidya in the device settings.');
                    }
                  }
                : null,
          ),
          if (supported && s.enabled) ...[
            ListTile(
              title: const Text('Time of day'),
              trailing: DropdownButton<int>(
                value: s.hour,
                onChanged: (h) => h == null ? null : notifier.setHour(h),
                items: [
                  for (var h = 0; h < 24; h++)
                    DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
                ],
              ),
            ),
            ListTile(
              title: const Text('At most per week'),
              subtitle: const Text('Reminders stop at this limit, even if cards stay due.'),
              trailing: DropdownButton<int>(
                value: s.perWeek,
                onChanged: (n) => n == null ? null : notifier.setPerWeek(n),
                items: [for (var n = 1; n <= 7; n++) DropdownMenuItem(value: n, child: Text('$n'))],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final _autoAddProvider = FutureProvider<bool>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.autoAddCareerFile();
});

/// Plans from the career file (Udyoga sends them through sync): offered on
/// Home with one tap, or added by themselves when this is on. Device-only.
class _CareerFileCard extends ConsumerWidget {
  const _CareerFileCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Plans from your career file',
    padding: const EdgeInsets.only(bottom: 8),
    child: SwitchListTile(
      title: const Text('Add them automatically'),
      subtitle: const Text(
        'When Udyoga syncs a study plan from your career file, add it (or update it) without asking. '
        'Off: it waits on Home for a tap. Plans Udyoga makes itself always wait.',
      ),
      value: ref.watch(_autoAddProvider).value ?? false,
      onChanged: (v) => ref.mutate((s) => s.book.setAutoAddCareerFile(v), report: false),
    ),
  );
}

/// The weekly time target: progress on Home, never a penalty. Synced, so
/// every device shows the same target.
class _WeekTargetCard extends ConsumerWidget {
  const _WeekTargetCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(weekTargetProvider).value ?? 0;
    return SectionCard(
      title: 'Weekly time target',
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(target == 0 ? 'No target' : '${minutesText(target)} a week'),
        subtitle: const Text(
          'Home shows how far you are since Monday. No streaks, nothing lost for a quiet week.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => weekTargetDialog(context, ref, target),
      ),
    );
  }
}

/// Saves the learner's own history (programs, courses, topics, items done,
/// quiz scores, time and notes) as Markdown or JSON, to keep or move.
class _HistoryCard extends ConsumerWidget {
  const _HistoryCard();

  Future<void> _save(BuildContext context, WidgetRef ref, {required bool json}) async {
    final day = today();
    final h = await ref.read(sessionProvider).book.history(day);
    final text = json ? historyJson(h) : historyMarkdown(h);
    final saved = await FilePicker.saveFile(
      dialogTitle: 'Export my history',
      fileName: 'vidya-history-$day.${json ? 'json' : 'md'}',
      bytes: Uint8List.fromList(utf8.encode(text)),
      mimeType: json ? 'application/json' : 'text/markdown',
    );
    if (saved != null && context.mounted) showMessage(context, 'History saved.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionCard(
    title: 'Your history',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Everything you studied: programs, courses and topics with their status, items done with your '
          'takeaways, quiz scores, time and your own notes. Plan text is left out.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.description_outlined),
              label: const Text('Markdown'),
              onPressed: () => _save(context, ref, json: false),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.data_object),
              label: const Text('JSON'),
              onPressed: () => _save(context, ref, json: true),
            ),
          ],
        ),
      ],
    ),
  );
}
