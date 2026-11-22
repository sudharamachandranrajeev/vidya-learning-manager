import 'dart:io' show Platform;

import 'package:brahma_core/brahma_core.dart' show isoDate, revisionProvider;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/reminders.dart';
import '../domain/stage_packs_book.dart';
import 'providers.dart';

/// The learner's reminder choices, made once in Settings. Device-only. Off
/// until switched on; at most [perWeek] reminders a week, at [hour] o'clock.
class ReminderSettings {
  const ReminderSettings({this.enabled = false, this.hour = 18, this.perWeek = 3});
  final bool enabled;
  final int hour, perWeek;

  ReminderSettings copyWith({bool? enabled, int? hour, int? perWeek}) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    hour: hour ?? this.hour,
    perWeek: perWeek ?? this.perWeek,
  );
}

/// Shows reminders on the device itself. Nothing is sent from a server.
abstract class ReminderScheduler {
  /// Whether this platform can schedule reminders.
  bool get supported;

  /// Asks the system for permission to notify; whether it was given.
  Future<bool> requestPermission();

  /// Replaces every pending reminder with [reminders]: when, and cards due.
  /// A due of 0 is the monthly job check-in from the journey's first 90 days.
  Future<void> replaceAll(List<(DateTime when, int due)> reminders);
}

/// Scheduled local notifications, on Android. The other platforms have no
/// way to schedule them, so reminders are not offered there.
class LocalReminderScheduler implements ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _ready = false;

  @override
  bool get supported => Platform.isAndroid;

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    _ready = true;
  }

  @override
  Future<bool> requestPermission() async {
    await _init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> replaceAll(List<(DateTime when, int due)> reminders) async {
    await _init();
    await _plugin.cancelAllPendingNotifications();
    for (var i = 0; i < reminders.length; i++) {
      final (at, due) = reminders[i];
      await _plugin.zonedSchedule(
        id: i,
        title: 'Vidya',
        body: switch (due) {
          0 => 'Time for your monthly job check-in: open the journey\'s first 90 days.',
          1 => '1 card is ready to review.',
          _ => '$due cards are ready to review.',
        },
        // The instant is what matters, so UTC is as good as the local zone.
        scheduledDate: tz.TZDateTime.from(at, tz.UTC),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'reviews',
            'Review reminders',
            channelDescription: 'Cards that are due, at the time and as often as you chose.',
          ),
        ),
        // Inexact: no exact-alarm permission needed for a daily nudge.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) => LocalReminderScheduler());

class Reminders extends AsyncNotifier<ReminderSettings> {
  static const _on = 'reminders.on', _hour = 'reminders.hour', _perWeek = 'reminders.perWeek';

  @override
  Future<ReminderSettings> build() async {
    final db = ref.watch(sessionProvider).db;
    const d = ReminderSettings();
    return ReminderSettings(
      enabled: await db.localSetting(_on) == 'on',
      hour: int.tryParse(await db.localSetting(_hour) ?? '')?.clamp(0, 23) ?? d.hour,
      perWeek: int.tryParse(await db.localSetting(_perWeek) ?? '')?.clamp(1, 7) ?? d.perWeek,
    );
  }

  Future<void> _save(ReminderSettings s) async {
    state = AsyncData(s);
    final db = ref.read(sessionProvider).db;
    await db.setLocalSetting(_on, s.enabled ? 'on' : 'off');
    await db.setLocalSetting(_hour, '${s.hour}');
    await db.setLocalSetting(_perWeek, '${s.perWeek}');
  }

  ReminderSettings get _now => state.value ?? const ReminderSettings();

  /// Switches reminders on or off. Turning them on asks the system for
  /// permission first; false means it was refused and they stay off.
  Future<bool> setEnabled(bool on) async {
    if (on && !await ref.read(reminderSchedulerProvider).requestPermission()) return false;
    await _save(_now.copyWith(enabled: on));
    return true;
  }

  Future<void> setHour(int hour) => _save(_now.copyWith(hour: hour));
  Future<void> setPerWeek(int n) => _save(_now.copyWith(perWeek: n));
}

final remindersProvider = AsyncNotifierProvider<Reminders, ReminderSettings>(Reminders.new);

/// Keeps the device's pending reminders in step with the settings, the
/// cards due and any monthly job check-in due. Watched from the home screen
/// so it runs whenever they change.
final reminderSyncProvider = FutureProvider<void>((ref) async {
  final scheduler = ref.watch(reminderSchedulerProvider);
  if (!scheduler.supported) return;
  final settings = await ref.watch(remindersProvider.future);
  final stats = await ref.watch(statsProvider.future);
  ref.watch(revisionProvider);
  final now = DateTime.now();
  DateTime at(int day) => DateTime(now.year, now.month, now.day + day, settings.hour);
  final plan = settings.enabled
      ? planReminders(stats.forecast(), perWeek: settings.perWeek, todayOpen: at(0).isAfter(now))
      : const <Reminder>[];
  final checkIns = settings.enabled
      ? checkInReminderDays(
          [for (final c in await ref.watch(sessionProvider).book.checkInsDue()) c.day],
          isoDate(now),
          todayOpen: at(0).isAfter(now),
        )
      : const <int>[];
  await scheduler.replaceAll([
    for (final r in plan) (at(r.day), r.due),
    for (final d in checkIns) (at(d), 0),
  ]);
});
