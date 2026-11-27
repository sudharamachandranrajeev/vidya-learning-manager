import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/ui/markdown.dart';

/// A fictional plan note with every block the renderer is asked to show.
const _note = '''
# Exams, scoring and rules

Pass mark is **80%** and the exam is *timed*.

- Read the brief
- Fill the table

1. First step
2. Second step

| Column one | Column two | Column three | Column four | Column five |
|---|---|---|---|---|
| A long cell that keeps going for a while | B | C | D | E |

Use `rota_check` before handing in.

```
step one
step two
```

See [the guide](https://example.org/guide) for more.

![a diagram of the rota](https://example.org/rota.png)
''';

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets('headings, lists, emphasis, tables, code and links render', (tester) async {
    await tester.pumpWidget(_host(const MarkdownText(_note)));
    expect(find.byKey(const Key('markdown')), findsOneWidget);
    expect(find.byKey(const Key('markdown-raw')), findsNothing);
    expect(find.text('Exams, scoring and rules'), findsOneWidget);
    expect(find.textContaining('Pass mark is 80%'), findsOneWidget);
    expect(find.text('Read the brief'), findsOneWidget);
    expect(find.text('Second step'), findsOneWidget);
    expect(find.text('Column five'), findsOneWidget);
    expect(find.textContaining('rota_check'), findsOneWidget);
    expect(find.textContaining('step one'), findsOneWidget);
    expect(find.textContaining('the guide'), findsOneWidget);
    // The image is not fetched: its alt text shows in its place.
    expect(find.byType(Image), findsNothing);
    expect(find.text('[a diagram of the rota]'), findsOneWidget);
    // No raw Markdown marks left in the text.
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('| Column'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide table scrolls sideways in its own scroller', (tester) async {
    await tester.pumpWidget(_host(const MarkdownText(_note)));
    final tableScroller = find.ancestor(of: find.byType(Table), matching: find.byType(SingleChildScrollView));
    expect(tableScroller, findsWidgets);
    final horizontal = tester
        .widgetList<SingleChildScrollView>(tableScroller)
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(horizontal, isNotEmpty);
    // The table is wider than the phone, and the page does not overflow.
    expect(tester.getSize(find.byType(Table)).width, greaterThan(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('text scale 2.0 lays out with no overflow and readable semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(const MarkdownText(_note), scale: 2));
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel(RegExp('Exams, scoring and rules')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Read the brief')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a link asks first and shows its address; Cancel opens nothing', (tester) async {
    await tester.pumpWidget(_host(const MarkdownText('Read [the guide](https://example.org/guide).')));
    await tester.tapOnText(find.textRange.ofSubstring('the guide'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('https://example.org/guide'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsNothing);
  });

  testWidgets('a link that is not web or email never offers to open', (tester) async {
    await tester.pumpWidget(_host(const MarkdownText('[run](javascript:alert(1))')));
    await tester.tapOnText(find.textRange.ofSubstring('run'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('text too long to render is shown as written', (tester) async {
    final long = '**${'x' * maxMarkdownLength}**';
    await tester.pumpWidget(_host(MarkdownText(long)));
    expect(find.byKey(const Key('markdown-raw')), findsOneWidget);
    expect(find.byKey(const Key('markdown')), findsNothing);
  });

  testWidgets('plain text with stray marks still renders and keeps its words', (tester) async {
    const odd = 'Half **bold and a [broken link( and <b>html</b> and | a | b';
    await tester.pumpWidget(_host(const MarkdownText(odd)));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('broken link'), findsOneWidget);
  });
}
