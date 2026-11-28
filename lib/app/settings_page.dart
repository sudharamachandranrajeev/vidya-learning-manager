import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:brahma_core/brahma_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:interview_engine/interview_engine.dart' as ie show VideoTake, VideoTakeStore, formatBytes;

import '../domain/dossier_readers.dart';
import '../domain/export.dart';
import '../domain/resources.dart';
import '../domain/review.dart';
import '../ui/common.dart';
import '../ui/dialogs.dart';
import '../ui/video_review_page.dart' show videoTakePrivacy;
import '../domain/udyoga_link.dart';
import 'interview_providers.dart';
import 'providers.dart';
import 'research_providers.dart';
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
      _SchedulerCard(),
      _RemindersCard(),
      _CareerFileCard(),
      _VideoTakesCard(),
      _HistoryCard(),
      _DataSourcesCard(),
      _ResearchKeysCard(),
      AppLockCard(),
      HintsCard(),
      SyncCard(),
      SecurityCard(
        network:
            'Vidya goes online only when you search for free resources, read a pasted link\'s title or look '
            'an employer up for a job dossier, and talks to your sync server only if you sign in.',
      ),
      AboutCard(
        description:
            'Learning and knowledge management: programs, courses, skills, portfolio, notes and progress.',
      ),
    ],
  );
}

/// The catalogues the free resource search asks, each with its licence or
/// terms, and the optional YouTube key (this device's keychain only).
class _DataSourcesCard extends ConsumerWidget {
  const _DataSourcesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasKey = (ref.watch(youtubeKeyProvider).value ?? '').isNotEmpty;
    return SectionCard(
      title: 'Data sources',
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Find free resources asks these catalogues, only when you search. Vidya keeps each link and its '
            'facts (title, length, level, licence), never the lesson text.',
          ),
          for (final d in dataSources)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(d.name),
              subtitle: Text('${d.what}\nLicence or terms: ${d.terms}'),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Open the ${d.name} terms',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => openLink(context, d.url),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key_outlined),
            title: const Text('Your YouTube key'),
            subtitle: Text(
              hasKey
                  ? 'Added. YouTube search is on. Kept in this device\'s keychain, never synced.'
                  : 'Not added, so YouTube search is off. Pasted YouTube links still work.',
            ),
            trailing: TextButton(
              onPressed: () => _youtubeKeyDialog(context, ref, hasKey),
              child: Text(hasKey ? 'Change' : 'Add'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _youtubeKeyDialog(BuildContext context, WidgetRef ref, bool hasKey) async {
  final key = TextEditingController();
  final store = ref.read(sessionProvider).keys.store;
  await showFormDialog(
    context,
    title: 'Your YouTube key',
    fields: (_) => [
      const Text(
        'Optional. A YouTube Data API v3 key of your own, from the Google Cloud console. The free quota '
        'allows about 100 searches a day. The key stays in this device\'s keychain: it is never synced '
        'or shared. Leave it empty and save to remove it.',
      ),
      const SizedBox(height: 12),
      TextField(
        controller: key,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'YouTube API key'),
      ),
    ],
    onSave: () async {
      await ResourceSecrets.saveYoutubeKey(store, key.text);
      ref.invalidate(youtubeKeyProvider);
      return null;
    },
  );
}

/// The job dossier's optional readers: CQC and Companies House with the
/// learner's own keys. Off by default; each key stays in this device's
/// keychain and is never synced.
class _ResearchKeysCard extends ConsumerWidget {
  const _ResearchKeysCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readers = ref.watch(keyedReadersProvider).value;
    Widget tile(String name, String what, String keyName, bool on, String help) => ListTile(
      key: Key('research-key-$keyName'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.key_outlined),
      title: Text(name),
      subtitle: Text(
        on
            ? 'On: $what. Kept in this device\'s keychain, never synced.'
            : 'Off. Without a key the dossier only links to $name\'s site.',
      ),
      trailing: TextButton(
        onPressed: () => _researchKeyDialog(context, ref, name: name, keyName: keyName, help: help),
        child: Text(on ? 'Change' : 'Add'),
      ),
    );
    return SectionCard(
      title: 'Job research keys',
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Optional. A job\'s dossier reads NHS ODS without a key. These two need keys of your own; Vidya reads '
            'them only when you ask, and keeps each answer for a week.',
          ),
          tile(
            'CQC',
            'ratings and report dates are read',
            ResearchSecrets.cqc,
            readers?.cqc != null,
            'A subscription key from CQC\'s API portal (api-portal.service.cqc.org.uk).',
          ),
          tile(
            'Companies House',
            'officers and filings are read',
            ResearchSecrets.companiesHouse,
            readers?.companiesHouse != null,
            'A free REST API key from the Companies House developer hub (developer.company-information.service.gov.uk).',
          ),
        ],
      ),
    );
  }
}

Future<void> _researchKeyDialog(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  required String keyName,
  required String help,
}) async {
  final key = TextEditingController();
  final store = ref.read(sessionProvider).keys.store;
  await showFormDialog(
    context,
    title: 'Your $name key',
    fields: (_) => [
      Text(
        '$help The key stays in this device\'s keychain: it is never synced or shared. Leave it empty and save '
        'to remove it (the reader is then off).',
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('research-key-field'),
        controller: key,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: '$name key'),
      ),
    ],
    onSave: () async {
      await ResearchSecrets.save(store, keyName, key.text);
      ref.invalidate(keyedReadersProvider);
      return null;
    },
  );
}

/// How much space the video takes use on this device.
final _videoBytesProvider = FutureProvider<int>((ref) async {
  ref.watch(videoTakesProvider(null));
  try {
    return await (await ref.watch(videoTakeStoreProvider.future)).bytesUsed();
  } on Object {
    return 0;
  }
});

/// Video takes from mock interviews (J7): how long they are kept, the space
/// they use, and delete all. This device only.
class _VideoTakesCard extends ConsumerWidget {
  const _VideoTakesCard();

  static const _choices = [1, 3, 7, 14, 30, 60, 90];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(videoKeepDaysProvider).value ?? ie.VideoTakeStore.defaultKeepDays;
    final takes = ref.watch(videoTakesProvider(null)).value ?? const <ie.VideoTake>[];
    final bytes = ref.watch(_videoBytesProvider).value ?? 0;
    final muted = Theme.of(context).textTheme.bodySmall;
    return SectionCard(
      title: 'Interview video takes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Only rounds where you turned on "Record video for this round" have any. ${videoTakePrivacy(days)}',
            style: muted,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(child: Text('Delete video takes after')),
              DropdownButton<int>(
                key: const Key('video-keep-days'),
                value: _choices.contains(days) ? days : null,
                hint: Text('$days days'),
                items: [
                  for (final d in _choices)
                    DropdownMenuItem(value: d, child: Text('$d ${d == 1 ? 'day' : 'days'}')),
                ],
                onChanged: (v) {
                  if (v != null) unawaited(ref.read(videoKeepDaysProvider.notifier).set(v));
                },
              ),
            ],
          ),
          Text(
            takes.isEmpty
                ? 'No video takes on this device.'
                : '${takes.length} video ${takes.length == 1 ? 'take' : 'takes'} · ${ie.formatBytes(bytes)} on this device',
            key: const Key('video-storage'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('video-delete-all'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete all video takes'),
              onPressed: takes.isEmpty
                  ? null
                  : () async {
                      final ok = await askSure(
                        context,
                        'Delete all video takes?',
                        'Every interview video on this device goes, with its audio. Transcripts and scores stay. '
                            'This cannot be undone.',
                        action: 'Delete all',
                      );
                      if (!ok) return;
                      await (await ref.read(videoTakeStoreProvider.future)).deleteAll();
                      ref.invalidate(videoTakesProvider);
                      if (context.mounted) notify(context, 'All video takes deleted.');
                    },
            ),
          ),
        ],
      ),
    );
  }
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

/// Which algorithm spaces reviews. Synced, so every device agrees.
/// Switching rewrites nothing: due days stay, and either way the other
/// algorithm's numbers are kept up to date.
class _SchedulerCard extends ConsumerWidget {
  const _SchedulerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final by = ref.watch(reviewSchedulerProvider).value ?? ReviewScheduler.fsrs;
    return SectionCard(
      title: 'Review scheduler',
      padding: const EdgeInsets.only(bottom: 8),
      child: RadioGroup<ReviewScheduler>(
        groupValue: by,
        onChanged: (s) {
          if (s != null && s != by) ref.mutate((x) => x.book.setReviewScheduler(s), report: false);
        },
        child: Column(
          children: [
            for (final s in ReviewScheduler.values)
              RadioListTile<ReviewScheduler>(value: s, title: Text(s.label), subtitle: Text(s.about)),
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
                      notify(context, 'Allow notifications for Vidya in the device settings.');
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
          'Home shows how far you are since Monday. No streaks, nothing lost for a quiet week. '
          'Ready-by dates count these hours (3.5 h a week when not set).',
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
    if (saved != null && context.mounted) notify(context, 'History saved.');
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
