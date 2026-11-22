import 'package:brahma_core/brahma_core.dart' show daysBetween, isValidIsoDate;

/// A reminder to send: [day] days from today, with [due] cards waiting then.
typedef Reminder = ({int day, int due});

/// Which of the coming days get a reminder, at most [perWeek] of them.
///
/// [forecast] is Stats.forecast: cards due on each day from today, today
/// (with anything overdue) first. A card stays due until reviewed, so each
/// day's count includes everything earlier. Days with nothing due get no
/// reminder, and neither does today once [todayOpen] is false (the reminder
/// time has passed).
List<Reminder> planReminders(List<int> forecast, {required int perWeek, required bool todayOpen}) {
  final plan = <Reminder>[];
  var due = 0;
  for (var day = 0; day < forecast.length && plan.length < perWeek; day++) {
    due += forecast[day];
    if (due > 0 && (day > 0 || todayOpen)) plan.add((day: day, due: due));
  }
  return plan;
}

/// Which days from [today] get a monthly job check-in reminder, from the
/// check-in [days] due (stage packs). One a day; a missed check-in is
/// reminded today, or tomorrow once [todayOpen] is false. Only the next
/// [within] days, as the plan is redone whenever the app opens.
List<int> checkInReminderDays(List<String> days, String today, {required bool todayOpen, int within = 60}) {
  final out = <int>{};
  for (final d in days) {
    if (!isValidIsoDate(d)) continue;
    var n = d.compareTo(today) <= 0 ? 0 : daysBetween(d, today);
    if (n == 0 && !todayOpen) n = 1;
    if (n <= within) out.add(n);
  }
  return out.toList()..sort();
}
