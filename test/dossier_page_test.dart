// The dossier on the Journey page's Research stage, on a phone: Udyoga's
// facts shown as inference, a verified card with its sentence and source,
// the why-here points and questions linking their cards, the paste flow
// with the quote check, "not found in your sources", CQC off without a
// key, the NHS ODS reader on recorded fixtures (no live network), and the
// Settings keys. Employer, figures and text are made up.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vidya/app/providers.dart';
import 'package:vidya/app/research_providers.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/dossier.dart';
import 'package:vidya/domain/dossier_book.dart';
import 'package:vidya/domain/dossier_readers.dart';
import 'package:vidya/domain/journey_book.dart';
import 'package:vidya/ui/dossier_view.dart';

import 'app_harness.dart';

late String _pid;
String _now() => DateTime.now().toUtc().toIso8601String();

const _strategy =
    'Our five-year strategy puts digital care at the centre. The trust will open a new day surgery unit in 2027.';

Future<void> _seed(LearningBook b) async {
  final r = await b.importCurriculum(
    parseCurriculum(
      jsonEncode({
        'format': 'vidya-curriculum',
        'version': 3,
        'program': {'title': 'Prepare: Example Officer at Example Health Trust'},
        'role': 'Example Officer',
        'journey': {
          'employer': 'Example Health Trust',
          'role': 'Example Officer',
          'sector': 'nhs',
          'advertUrl': 'https://example.org/jobs/123',
          'advertText':
              'Example Officer, Band 4. You will support the digital team with the new record system.',
          'facts': [
            {'claim': 'Staff survey engagement rose in 2025.', 'url': 'https://example.org/survey'},
          ],
        },
      }),
    ),
    today: today(),
  );
  _pid = r.programId;
  await b.setJourneyStage(_pid, 'research', now: _now());
  final src = await b.addFactSource(
    _pid,
    employer: 'Example Health Trust',
    kind: 'strategy',
    url: 'https://example.org/strategy',
    title: 'Strategy 2026 to 2031',
    sourceDate: '2026-04-01',
    body: _strategy,
    now: _now(),
  );
  await b.addProposals(
    src,
    [
      const FactProposal(
        claim: 'A new day surgery unit opens in 2027.',
        quote: 'The trust will open a new day surgery unit in 2027.',
        kind: 'strategy',
      ),
    ],
    origin: 'ai',
    now: _now(),
  );
}

String fixture(String name) => File('test/fixtures/research/$name').readAsStringSync();

void main() {
  testWidgets('the dossier: statuses, artefacts with their cards, paste flow, asking, readers', (
    tester,
  ) async {
    final app = AppHarness(tester)..phone();
    await app.open(seed: _seed);
    final asked = <Uri>[];
    final client = MockClient((r) async {
      asked.add(r.url);
      final name = r.url.queryParameters.containsKey('Name')
          ? 'ods-search.json'
          : r.url.queryParameters['RelTypeId'] == 'RE6'
          ? 'ods-sites.json'
          : 'ods-org.json';
      return http.Response.bytes(utf8.encode(fixture(name)), 200);
    });
    await app.run(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        researchGateProvider.overrideWith(
          (ref) => PoliteGate(
            client,
            cacheRead: (_) async => null,
            cacheWrite: (_, _) async {},
            sleep: (_) async {},
          ),
        ),
      ],
    );
    await app.go('Learn');
    await app.tapText('Prepare: Example Officer at Example Health Trust');
    await app.tap(find.byKey(const Key('journey-tile')));
    expect(find.byType(DossierSection), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Statuses: the verified card and Udyoga's unverified proposal.
    expect(find.text('1 verified'), findsOneWidget);
    expect(find.text('1 inference'), findsOneWidget);
    expect(find.text('Inference: not checked'), findsOneWidget);
    expect(find.textContaining('proposed by Udyoga'), findsOneWidget);
    expect(find.text('“The trust will open a new day surgery unit in 2027.”'), findsOneWidget);
    expect(find.textContaining('Source: Strategy 2026 to 2031 · dated 1 Apr 2026'), findsOneWidget);

    // The why-here point and the question rest on the verified card only.
    expect(find.byKey(const Key('why-0')), findsOneWidget);
    expect(find.byKey(const Key('why-1')), findsNothing);
    expect(find.textContaining('I read that a new day surgery unit opens in 2027'), findsOneWidget);
    await app.tap(find.byKey(const Key('why-0-card')));
    expect(find.text('The fact it rests on'), findsOneWidget);
    await app.tapText('Close');

    // Paste a staff survey page; a fact with a sentence not in it is kept
    // as inference, one with the sentence word for word is verified.
    await app.tap(find.byKey(const Key('dossier-paste')));
    await app.enter('Title', 'Staff survey 2025');
    await app.enter('Web address', 'https://example.org/survey');
    await app.enter(
      'The text',
      'In 2025, 71% of staff said they would recommend the trust as a place to work.',
    );
    await app.tapText('Save');
    expect(find.byType(SourcePage), findsOneWidget);
    await app.tap(find.byKey(const Key('source-add-fact')));
    await app.enter('The fact, in your words', '71% would recommend it.');
    await app.enter('The sentence that supports it', '81% of staff said they would recommend the trust');
    await app.tapText('Save');
    expect(find.textContaining('Saved as inference'), findsOneWidget);
    await app.tap(find.byKey(const Key('source-add-fact')));
    await app.enter('The fact, in your words', '71% of staff would recommend it as a place to work.');
    await app.enter(
      'The sentence that supports it',
      '71% of staff said they would recommend the trust as a place to work',
    );
    await app.tapText('Save');
    expect(find.textContaining('Verified: the sentence is in the text'), findsOneWidget);
    final cards = await tester.runAsync(() => app.book.factCards(_pid));
    expect(cards!.map((c) => c.status), containsAll(['verified', 'inference']));
    expect(cards.where((c) => c.claim.startsWith('71% of staff') && c.status == 'verified'), hasLength(1));
    await tester.pageBack();
    await app.settle();

    // Asking about something no source holds: "not found", never a guess.
    await app.tap(find.byKey(const Key('dossier-ask')));
    await tester.enterText(find.byKey(const Key('dossier-question')), 'What is the parking like?');
    await app.tap(find.byKey(const Key('dossier-ask-go')));
    expect(find.byKey(const Key('dossier-not-found')), findsOneWidget);
    await app.tapText('Close');

    // CQC with no key: off, links only, and nothing is fetched.
    await app.tap(find.byKey(const Key('dossier-cqc')));
    expect(find.textContaining('Off. CQC'), findsOneWidget);
    await app.tapText('Cancel');
    expect(asked, isEmpty);

    // NHS ODS on recorded fixtures: search, pick, keep.
    await app.tap(find.byKey(const Key('dossier-ods')));
    await app.tap(find.byKey(const Key('ods-search')));
    expect(find.byKey(const Key('ods-ZZW')), findsOneWidget);
    await app.tap(find.byKey(const Key('ods-ZZW')));
    await app.tapText('Keep this record');
    expect(find.byType(SourcePage), findsOneWidget);
    // The record is read and kept with real I/O: wait for the page to fill.
    final kept = find.text('Facts from this source (4)');
    for (var i = 0; i < 20 && kept.evaluate().isEmpty; i++) {
      await app.settle();
    }
    expect(kept, findsOneWidget);
    final facts = await tester.runAsync(() => app.book.factCards(_pid));
    expect(
      facts!.where((c) => c.origin == 'reader' && c.status == 'verified').map((c) => c.claim),
      contains('It has a successor organisation, ODS code ZZX, from 2024-04-01.'),
    );
    expect(asked.map((u) => u.host).toSet(), {'directory.spineservices.nhs.uk'});
    final sources = await tester.runAsync(() => app.book.factSources(_pid));
    expect(sources!.map((s) => s.kind), contains('ods'));
    expect(tester.takeException(), isNull);
    await app.close();
  });

  testWidgets('Settings: the research keys are off until added, and kept off the database', (tester) async {
    final app = AppHarness(tester)..desktop();
    await app.open();
    await app.run();
    await app.go('Settings');
    final cqc = find.byKey(const Key('research-key-${ResearchSecrets.cqc}'));
    await tester.scrollUntilVisible(cqc, 300, scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: cqc, matching: find.textContaining('Off.')), findsOneWidget);
    await app.tap(find.descendant(of: cqc, matching: find.text('Add')));
    await tester.enterText(find.byKey(const Key('research-key-field')), 'made-up-key');
    await app.tapText('Save');
    expect(find.descendant(of: cqc, matching: find.textContaining('On:')), findsOneWidget);
    expect(await tester.runAsync(() => app.session.keys.store.read(ResearchSecrets.cqc)), 'made-up-key');
    final settings = await tester.runAsync(() => app.session.db.select(app.session.db.localSettings).get());
    expect(settings!.any((s) => s.value.contains('made-up-key')), isFalse);
    await app.close();
  });
}
