/// Plan text shown as Markdown: notes, topic details, stress-test briefs
/// and rubrics, drill rubrics and task instructions. Headings, lists, bold
/// and italic, links, tables and code render; a table scrolls sideways in
/// its own scroller so a wide one never squeezes the page. Images are
/// never fetched (their alt text shows instead), and a link opens only
/// after the learner has seen its address and said yes. Text that the
/// renderer cannot lay out is shown as it was written.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'common.dart';

/// The most text rendered as Markdown; longer text is shown raw.
const maxMarkdownLength = 60000;

/// The link schemes a confirmed link may open.
const _openable = {'http', 'https', 'mailto'};

/// Whether [text] can be rendered: it parses and the builder lays it out
/// without throwing. Checked once per text.
final _checked = <String, bool>{};

bool markdownRenders(String text, BuildContext context) {
  if (text.length > maxMarkdownLength) return false;
  final known = _checked[text];
  if (known != null) return known;
  var ok = true;
  final probe = _Probe(context);
  try {
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseLines(text.split(RegExp(r'\r?\n')));
    MarkdownBuilder(
      delegate: probe,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      imageDirectory: null,
      imageBuilder: (_, _, _) => const SizedBox.shrink(),
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: const {},
      paddingBuilders: const {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    ).build(nodes);
  } catch (_) {
    ok = false;
  } finally {
    probe.dispose();
  }
  if (_checked.length > 200) _checked.clear();
  return _checked[text] = ok;
}

class _Probe implements MarkdownBuilderDelegate {
  _Probe(this.context);
  @override
  final BuildContext context;
  final _made = <GestureRecognizer>[];

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final r = TapGestureRecognizer();
    _made.add(r);
    return r;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
      TextSpan(style: styleSheet.code, text: code);

  void dispose() {
    for (final r in _made) {
      r.dispose();
    }
  }
}

/// Asks before opening [url], showing the address in full. Only web and
/// email links open.
Future<void> confirmOpenLink(BuildContext context, String? url) async {
  final href = (url ?? '').trim();
  final uri = Uri.tryParse(href);
  if (href.isEmpty || uri == null || !_openable.contains(uri.scheme.toLowerCase())) {
    return notify(
      context,
      href.isEmpty ? 'This link has no address.' : 'Only web and email links open: $href',
    );
  }
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open this link?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('It opens outside Vidya, at this address:'),
          const SizedBox(height: 8),
          SelectableText(href, key: const Key('link-address')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open')),
      ],
    ),
  );
  if (yes == true && context.mounted) await openLink(context, href);
}

/// [data] rendered as Markdown in [style] (the body text when null).
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.data, {super.key, this.style});
  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = style ?? theme.textTheme.bodyMedium;
    if (!markdownRenders(data, context)) {
      return SelectableText(data, key: const Key('markdown-raw'), style: base);
    }
    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: base,
      tableBody: base,
      listBullet: base,
      // A wide table keeps its columns and scrolls sideways on its own.
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableScrollbarThumbVisibility: true,
      a: base?.copyWith(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: theme.colorScheme.primary,
      ),
      code: base?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
      ),
      tableBorder: TableBorder.all(color: theme.colorScheme.outlineVariant),
    );
    return MarkdownBody(
      key: const Key('markdown'),
      data: data,
      styleSheet: sheet,
      onTapLink: (_, href, _) => confirmOpenLink(context, href),
      // Images are never fetched: the plan's words for one show instead.
      imageBuilder: (uri, title, alt) => Text(
        '[${(alt ?? '').trim().isNotEmpty ? alt!.trim() : 'image'}]',
        style: base?.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  }
}
