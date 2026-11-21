import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vidya/app/providers.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/resources.dart';
import 'package:vidya/ui/resource_search.dart';

import 'app_harness.dart';

/// Catalogues that answer at once from made-up results, or fail.
class _Fake implements ResourceCatalogue {
  _Fake(this.name, this.results, {this.fail});
  @override
  final String name;
  final List<Resource> results;
  final String? fail;
  @override
  String get id => name;
  @override
  Future<List<Resource>> search(String query) async {
    if (fail != null) throw ResourceError(fail!);
    return results;
  }
}

const _paid = Resource(
  catalogue: 'fake',
  title: 'Centering masterclass with a famous potter',
  url: 'https://example.org/masterclass',
  source: 'Example Academy',
  type: 'course',
  minutes: 600,
  access: Access.paid,
  licence: 'Provider terms',
);

const _free = Resource(
  catalogue: 'fake',
  title: 'Centering clay on the wheel: a very long free course title that has to wrap on a phone screen',
  url: 'https://example.org/centering',
  source: 'Example Open School',
  type: 'course',
  kind: 'Free course',
  minutes: 45,
  level: 'Beginner',
  access: Access.free,
  licence: 'CC BY-NC-SA 4.0',
  summary: 'Made-up summary shown in the results only.',
);

/// The search sheet on a phone (390×844): one query across every
/// catalogue, a failing one shown on its own line, free first, one tap to
/// add, the badge corrected later, and a pasted YouTube link's title read
/// through oEmbed. Made-up plan and results.
void main() {
  testWidgets('find free resources on a phone: search, add, correct the badge, paste a link', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) => b.importCurriculum(
        parseCurriculum(
          jsonEncode({
            'format': 'vidya-curriculum',
            'version': 2,
            'program': {'title': 'Pottery teacher'},
            'courses': [
              {
                'title': 'Wheel basics',
                'topics': [
                  {'title': 'Centering', 'details': 'Brace your arms.'},
                ],
              },
            ],
          }),
        ),
        today: '2026-11-21',
      ),
    );
    final asked = <Uri>[];
    final oembed = File('test/fixtures/resources/youtube_oembed.json').readAsStringSync();
    await app.run(
      overrides: [
        freeCataloguesProvider.overrideWithValue([
          _Fake('Fake Learn', [_paid, _free]),
          _Fake('Broken', const [], fail: 'could not connect (are you offline?)'),
        ]),
        httpClientProvider.overrideWithValue(
          MockClient((r) async {
            asked.add(r.url);
            return http.Response.bytes(
              utf8.encode(oembed),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ],
    );
    await app.go('Learn');
    await app.tapText('Pottery teacher');
    await app.tapText('Wheel basics');
    await app.tapText('Centering');

    await app.tap(find.byTooltip('Find free resources'));
    expect(find.byType(ResourceSearchSheet), findsOneWidget);
    expect(
      find.text('Type a topic or a role, then search. Vidya goes online only when you do.'),
      findsOneWidget,
    );
    await app.tap(find.byTooltip('Search'));

    expect(find.text('Fake Learn: 2 found'), findsOneWidget);
    expect(find.text('Broken: could not connect (are you offline?)'), findsOneWidget);
    // Free first, whatever order the catalogue gave.
    final freeY = tester.getTopLeft(find.textContaining('Centering clay on the wheel')).dy;
    final paidY = tester.getTopLeft(find.text('Centering masterclass with a famous potter')).dy;
    expect(freeY, lessThan(paidY));
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('CC BY-NC-SA 4.0'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await app.tap(find.widgetWithText(FilledButton, 'Add').first);
    expect(find.widgetWithText(FilledButton, 'Added'), findsOneWidget);
    Navigator.of(tester.element(find.byType(ResourceSearchSheet))).pop();
    await app.settle();

    final tile = find.ancestor(
      of: find.textContaining('Centering clay on the wheel'),
      matching: find.byType(ListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
        of: tile,
        matching: find.text('Course · 45 min · Free · Example Open School · CC BY-NC-SA 4.0'),
      ),
      findsOneWidget,
    );

    // "Free" changes: the learner sets it to paid on the item.
    await app.tap(find.descendant(of: tile, matching: find.byTooltip('Item actions')));
    await app.tapText('Edit');
    await app.tap(find.text('Free').last);
    await app.tapText('Paid');
    await app.tapText('Save');
    expect(find.descendant(of: tile, matching: find.textContaining('45 min · Paid ·')), findsOneWidget);

    // A pasted YouTube link: the title comes from oEmbed.
    await app.tap(find.byTooltip('Add item'));
    await app.enter('Link', 'https://youtu.be/abc123XYZ00');
    await app.tap(find.byTooltip('Read the title from the link'));
    expect(asked.single.path, '/oembed');
    expect(find.text('Lecture 1: An example lecture'), findsOneWidget);
    expect(find.text('Example University'), findsOneWidget);
    await app.tapText('Save');
    expect(find.text('Lecture 1: An example lecture'), findsOneWidget);
    expect(find.textContaining('Video · Free · Example University'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
