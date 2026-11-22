import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart' show KitStatus, reducedMotion, showToast;
import 'package:url_launcher/url_launcher.dart';

/// "in 3 days", "today", "2 days ago".
String relativeDay(String date, String today) {
  final days = DateTime.parse('${date}T00:00Z').difference(DateTime.parse('${today}T00:00Z')).inDays;
  return switch (days) {
    0 => 'today',
    1 => 'tomorrow',
    -1 => 'yesterday',
    > 0 => 'in $days days',
    _ => '${-days} days ago',
  };
}

/// A short note at the bottom of the screen: the kit's toast, which slides
/// up, stays a few seconds and can be swiped away. Its text always contrasts
/// with its card. A long message keeps its first sentence as the title and
/// the rest underneath, so nothing is cut off.
void notify(BuildContext context, String message, {KitStatus status = KitStatus.info}) {
  final cut = message.length <= 90 ? -1 : message.indexOf(RegExp(r'[.:] '));
  if (cut < 0) {
    showToast(context, message, status: status);
  } else {
    showToast(
      context,
      message.substring(0, cut + 1),
      description: message.substring(cut + 2),
      status: status,
      stay: const Duration(seconds: 6),
    );
  }
}

/// A course's title that flies from its row to the course page's header as
/// the page opens (a Hero), so the row seems to grow into its page. Each
/// end gives its Text an explicit style. Under reduced motion it stays put.
class CourseTitleHero extends StatelessWidget {
  const CourseTitleHero(this.courseId, {super.key, required this.child});
  final String courseId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reducedMotion(context)) return child;
    return Hero(
      tag: 'course-title-$courseId',
      flightShuttleBuilder: _shuttle,
      // A Material, so the text has no debug underline in flight.
      child: Material(type: MaterialType.transparency, child: child),
    );
  }

  /// The page's title in flight, scaled down to fit the box as it grows.
  static Widget _shuttle(
    BuildContext flight,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext from,
    BuildContext to,
  ) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: (direction == HeroFlightDirection.push ? to : from).widget is Hero
        ? ((direction == HeroFlightDirection.push ? to : from).widget as Hero).child
        : const SizedBox.shrink(),
  );
}

String minutesText(int m) => m < 60 ? '$m min' : '${(m / 60).toStringAsFixed(m % 60 == 0 ? 0 : 1)} h';

Future<void> openLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return notify(context, 'Not a web address: $url');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) notify(context, 'Nothing on this device can open $uri.');
}

/// A plain text field with a label.
class Field extends StatelessWidget {
  const Field(
    this.controller,
    this.label, {
    super.key,
    this.number = false,
    this.lines = 1,
    this.hint,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String label;
  final bool number;
  final int lines;
  final String? hint;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 8,
      keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : null,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}

num? numberIn(TextEditingController c) => num.tryParse(c.text.replaceAll(RegExp(r'[,%\s]'), ''));

/// A form in a dialog with Cancel and a save button; returns whether saved.
/// [onSave] returns an error message to show, or null when done.
Future<bool> showFormDialog(
  BuildContext context, {
  required String title,
  required List<Widget> Function(StateSetter setState) fields,
  required Future<String?> Function() onSave,
  String action = 'Save',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      String? error;
      var busy = false;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...fields(setState),
                if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      String? e;
                      try {
                        e = await onSave();
                      } catch (x) {
                        e = describeError(x);
                      }
                      if (!context.mounted) return;
                      if (e == null) {
                        Navigator.pop(context, true);
                      } else {
                        setState(() {
                          error = e;
                          busy = false;
                        });
                      }
                    },
              child: Text(action),
            ),
          ],
        ),
      );
    },
  );
  return ok ?? false;
}

/// A labelled dropdown for small fixed choices.
class Choice<T> extends StatelessWidget {
  const Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<T>(
      initialValue: options.containsKey(value) ? value : options.keys.first,
      decoration: InputDecoration(labelText: label),
      isExpanded: true,
      items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}

Future<bool> askSure(BuildContext context, String title, String message, {String action = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ??
    false;

/// A date field that opens the date picker.
class DatePick extends StatelessWidget {
  const DatePick({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        final now = DateTime.parse('${today()}T00:00:00');
        final d = await showDatePicker(
          context: context,
          initialDate: value == null ? now : DateTime.parse('${value}T00:00:00'),
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 10),
        );
        if (d != null) onChanged(isoDate(d));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value == null
              ? const Icon(Icons.event)
              : IconButton(icon: const Icon(Icons.clear), onPressed: () => onChanged(null)),
        ),
        child: Text(value == null ? 'Not set' : niceDate(value!)),
      ),
    ),
  );
}

/// The import message's note on cards a re-sent plan no longer has.
String retiredNote(int n) => n == 0
    ? ''
    : ' ${n == 1 ? '1 card is' : '$n cards are'} no longer in the plan: '
          'set aside with ${n == 1 ? 'its' : 'their'} reviews, not shown for review.';

/// The import message's note on study items a re-sent plan no longer has.
String retiredItemsNote(int n) => n == 0
    ? ''
    : ' ${n == 1 ? '1 study item is' : '$n study items are'} no longer in the plan: '
          'set aside on ${n == 1 ? 'its' : 'their'} topic page, not counted. Items you had done stay as they are.';
