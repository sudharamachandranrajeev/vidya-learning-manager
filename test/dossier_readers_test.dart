// The dossier's readers on recorded fixtures (no live network): NHS ODS
// (shapes recorded from the live API on 2026-11-22), CQC and Companies
// House (shapes from their API documentation; not checked live, no key),
// the polite gate, and the keys being off by default. Organisations,
// people and figures are made up.
import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/dossier.dart';
import 'package:vidya/domain/dossier_book.dart';
import 'package:vidya/domain/dossier_readers.dart';

import 'support.dart';

const now = '2026-11-22T10:00:00.000Z';
const today = '2026-11-22';

String fixture(String name) => File('test/fixtures/research/$name').readAsStringSync();

void main() {
  group('saving a record', () {
    late LearningBook book;
    late String pid;
    setUp(() async {
      book = LearningBook(await Store.open(memoryDatabase()));
      pid = await book.addProgram('Prepare: Example Officer at Example Health Trust', '', today: today);
    });
    tearDown(() => book.db.close());

    test('a reader run again replaces its source instead of keeping two', () async {
      final r = OdsReader.odsRecord(
        jsonDecode(fixture('ods-org.json')),
        jsonDecode(fixture('ods-sites.json')),
      );
      await book.saveReaderRecord(pid, r, now: now);
      await book.saveReaderRecord(pid, r, now: now);
      expect(await book.factSources(pid), hasLength(1));
      final cards = await book.factCards(pid);
      expect(cards.every((c) => c.status == 'verified' && c.origin == 'reader'), isTrue);
      expect(cards.length, r.facts.length);
    });
  });

  group('readers on recorded fixtures', () {
    late List<Uri> asked;
    late List<Map<String, String>> headers;
    late Map<String, String> cache;
    late List<Duration> slept;

    PoliteGate gate(http.Response Function(Uri u) answer) {
      asked = [];
      headers = [];
      slept = [];
      return PoliteGate(
        MockClient((r) async {
          asked.add(r.url);
          headers.add(r.headers);
          return answer(r.url);
        }),
        cacheRead: (k) async => cache[k],
        cacheWrite: (k, v) async => cache[k] = v,
        clock: () => DateTime.utc(2026, 11, 22, 10),
        sleep: (d) async => slept.add(d),
      );
    }

    setUp(() => cache = {});

    http.Response json(String name) =>
        http.Response.bytes(utf8.encode(fixture(name)), 200, headers: {'content-type': 'application/json'});

    test('NHS ODS: search, record with sites and successor, every fact verified; a second look asks nothing', () async {
      final g = gate((u) {
        if (u.queryParameters.containsKey('Name')) return json('ods-search.json');
        if (u.queryParameters['RelTypeId'] == 'RE6') return json('ods-sites.json');
        return json('ods-org.json');
      });
      final ods = OdsReader(g);
      final hits = await ods.search('example health');
      expect(hits.map((h) => (h.code, h.status)), [('ZZX', 'Active'), ('ZZW', 'Inactive')]);
      expect(asked.single.queryParameters, {'Name': 'example health', 'Limit': '20'});
      expect(headers.single['user-agent'], startsWith('Vidya/'));

      final r = await ods.record('ZZW');
      expect(asked.map((u) => u.path).skip(1), ['/ORD/2-0-0/organisations/ZZW', '/ORD/2-0-0/organisations']);
      expect(slept, isNotEmpty, reason: 'a gap between requests to one site');
      expect(r.url, 'https://directory.spineservices.nhs.uk/ORD/2-0-0/organisations/ZZW');
      expect(r.sourceDate, '2024-04-02');
      expect(r.body, contains('Successor organisation: ODS code ZZX, from 2024-04-01.'));
      expect(r.body, contains('Site: EXAMPLETON COMMUNITY CLINIC, EX1 3CC.'));
      expect(r.facts.map((f) => f.claim), [
        'The official name is EXAMPLE HEALTH TRUST (ODS code ZZW).',
        'The NHS ODS register lists it as inactive.',
        'It has a successor organisation, ODS code ZZX, from 2024-04-01.',
        'The register lists 2 active sites, including EXAMPLE GENERAL HOSPITAL, EXAMPLETON COMMUNITY CLINIC.',
      ]);
      expect(checkProposals(r.facts, r.body).unmatched, isEmpty);

      final before = asked.length;
      await ods.record('ZZW');
      expect(asked.length, before, reason: 'kept for a week');
      expect(() => ods.search('ex'), throwsA(isA<ResearchException>()));
    });

    test(
      'CQC: the own key goes in its header; ratings become verified cqc facts dated by the report',
      () async {
        final g = gate((_) => json('cqc-provider.json'));
        final r = await CqcReader(g, 'made-up-key').record('ZZX');
        expect(asked.single.toString(), 'https://api.service.cqc.org.uk/public/v1/providers/ZZX');
        expect(headers.single['Ocp-Apim-Subscription-Key'], 'made-up-key');
        expect(r.sourceDate, '2025-05-20');
        expect(r.url, 'https://www.cqc.org.uk/provider/ZZX');
        expect(r.facts.map((f) => (f.claim, f.kind)), [
          ('CQC rates it Requires improvement overall (report of 2025-05-20).', 'cqc'),
          ('CQC rates it Requires improvement for Safe.', 'cqc'),
          ('CQC rates it Good for Caring.', 'cqc'),
        ]);
        expect(checkProposals(r.facts, r.body).unmatched, isEmpty);
        expect(staleAfterFor('cqc', sourceDate: r.sourceDate), '2027-05-20');
      },
    );

    test('Companies House: basic auth with the own key; current officers only', () async {
      final g = gate((u) {
        if (u.path.startsWith('/search')) return json('ch-search.json');
        if (u.path.endsWith('/officers')) return json('ch-officers.json');
        return json('ch-profile.json');
      });
      final ch = CompaniesHouseReader(g, 'made-up-key');
      expect((await ch.search('example care')).single.number, '00000001');
      expect(headers.single['authorization'], 'Basic ${base64Encode(utf8.encode('made-up-key:'))}');
      final r = await ch.record('00000001', today: today);
      expect(r.sourceDate, today);
      expect(r.body, isNot(contains('FORMER')));
      expect(r.facts.map((f) => f.claim), [
        'EXAMPLE CARE LIMITED (company 00000001) is active on the register.',
        'Its latest filed accounts are made up to 2025-03-31.',
        'EXAMPLE, Alex is a current director.',
        'SAMPLE, Sam is a current secretary.',
      ]);
      expect(checkProposals(r.facts, r.body).unmatched, isEmpty);
    });

    test('failures are said in plain words', () async {
      final refused = gate((_) => http.Response('{}', 401));
      await expectLater(
        CqcReader(refused, 'wrong').record('ZZX'),
        throwsA(isA<ResearchException>().having((e) => e.message, 'message', contains('key was refused'))),
      );
      final missing = gate((_) => http.Response('{}', 404));
      await expectLater(OdsReader(missing).record('NOPE'), throwsA(isA<ResearchException>()));
      final garbled = gate((_) => http.Response('<html>', 200));
      await expectLater(
        OdsReader(garbled).search('example'),
        throwsA(isA<ResearchException>().having((e) => e.message, 'message', contains('could not be read'))),
      );
    });

    test('keys are off by default: no key, no reader, no request', () async {
      final store = MemorySecretStore();
      final g = gate((_) => throw StateError('no request may be made'));
      var r = await keyedReaders(store, g);
      expect((r.cqc, r.companiesHouse), (null, null));
      expect(await keyedReaders(null, g), isA<Object>());
      await ResearchSecrets.save(store, ResearchSecrets.cqc, ' made-up-key ');
      r = await keyedReaders(store, g);
      expect((r.cqc?.key, r.companiesHouse), ('made-up-key', null));
      await ResearchSecrets.save(store, ResearchSecrets.cqc, '');
      expect((await keyedReaders(store, g)).cqc, isNull);
      expect(asked, isEmpty);
      expect(g.sent, 0);
    });

    test('links only for the sources Vidya never reads', () {
      final links = linkOnlySources('Example Health Trust');
      expect(links.map((l) => l.label), contains('Glassdoor'));
      expect(links.firstWhere((l) => l.label == 'LinkedIn').note, contains('never opens or reads LinkedIn'));
      expect(links.firstWhere((l) => l.label == 'Glassdoor').note, contains('Anecdotal'));
    });
  });
}
