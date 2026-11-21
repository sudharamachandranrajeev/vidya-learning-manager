import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/resources.dart';
import 'package:vidya/domain/study_items.dart';
import 'package:vidya/domain/templates.dart';

import 'support.dart';

/// Free resource search (plan V4), all offline: every service answer comes
/// from a made-up fixture with the live shape (checked 2026-11-21).
String fixture(String name) => File('test/fixtures/resources/$name').readAsStringSync();

/// A clock the test moves by hand.
class FakeClock {
  DateTime t = DateTime.utc(2026, 11, 21, 9);
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
}

/// A mock web client that counts its requests and answers with [answer].
({MockClient client, List<Uri> asked}) mock(http.Response Function(http.Request r) answer) {
  final asked = <Uri>[];
  return (
    client: MockClient((r) async {
      asked.add(r.url);
      return answer(r);
    }),
    asked: asked,
  );
}

http.Response ok(String body, {String type = 'application/json'}) =>
    http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': '$type; charset=utf-8'});

class FakeCatalogue implements ResourceCatalogue {
  FakeCatalogue(this.id, this.results, {this.fail});
  @override
  final String id;
  final List<Resource> results;
  final String? fail;
  @override
  String get name => id;
  @override
  Future<List<Resource>> search(String query) async {
    if (fail != null) throw ResourceError(fail!);
    return results;
  }
}

Resource res(String title, {Access access = Access.unknown, String url = '', String catalogue = 'x'}) =>
    Resource(
      catalogue: catalogue,
      title: title,
      url: url.isEmpty ? 'https://example.org/${title.replaceAll(' ', '-')}' : url,
      source: 'Example',
      type: 'course',
      access: access,
    );

void main() {
  group('Microsoft Learn', () {
    test('the catalogue is trimmed and searched on the device, best fit first', () async {
      final m = mock((_) => ok(fixture('ms_learn_catalog.json')));
      final ms = MicrosoftLearnCatalogue(m.client, MemoryResourceCache());
      final rota = await ms.search('rota report');
      expect(rota.map((r) => r.title), ['Introduction to rota reports']);
      final r = rota.single;
      expect(r.kind, 'Module');
      expect(r.minutes, 42);
      expect(r.level, 'Beginner');
      expect(r.access, Access.free);
      expect(r.licence, 'Microsoft Learn terms');
      expect(r.url, startsWith('https://learn.microsoft.com/en-us/training/modules/example-rota-basics/'));

      // Roles and summaries count too: "trainer" is a role and "clinical"
      // in the summary of the second module only.
      expect((await ms.search('clinical trainer')).single.title, 'Deliver system training to new staff');
      expect(
        (await ms.search('clinical trainer')).single.summary,
        'Plan a training session for new users of a clinical system.',
      );

      final reports = await ms.search('data report');
      expect(
        reports.map((r) => r.title),
        containsAll(['Build your first data report', 'Data reports with a trainer']),
      );
      final course = reports.firstWhere((r) => r.kind == 'Course with a trainer');
      expect(course.access, Access.paid);
      expect(course.minutes, 24 * 60);
      expect(m.asked.single, MicrosoftLearnCatalogue.endpoint);
      expect(m.asked.single.queryParameters['type'], 'modules,learningPaths,courses');
    });

    test('the copy is reused for 24 hours, then fetched again; an old copy covers a failure', () async {
      final clock = FakeClock();
      final cache = MemoryResourceCache();
      var fail = false;
      final m = mock((_) => fail ? http.Response('down', 503) : ok(fixture('ms_learn_catalog.json')));
      await MicrosoftLearnCatalogue(m.client, cache, now: clock.now).search('rota');
      expect(m.asked, hasLength(1));

      // A new run (new catalogue object) 23 hours later reads the device copy.
      clock.advance(const Duration(hours: 23));
      final later = MicrosoftLearnCatalogue(m.client, cache, now: clock.now);
      expect(await later.search('rota'), hasLength(1));
      await later.search('data');
      expect(m.asked, hasLength(1));

      // After a day it asks again.
      clock.advance(const Duration(hours: 2));
      await MicrosoftLearnCatalogue(m.client, cache, now: clock.now).search('rota');
      expect(m.asked, hasLength(2));

      // Two days on with the service down: the old copy still answers.
      clock.advance(const Duration(hours: 48));
      fail = true;
      expect(await MicrosoftLearnCatalogue(m.client, cache, now: clock.now).search('rota'), hasLength(1));
      expect(m.asked, hasLength(3));

      // No copy at all and the service down: a plain error.
      expect(
        () => MicrosoftLearnCatalogue(m.client, MemoryResourceCache(), now: clock.now).search('rota'),
        throwsA(isA<ResourceError>().having((e) => e.message, 'message', contains('503'))),
      );
    });

    test('the device copy is kept in local settings as text with its date', () async {
      final store = <String, String>{};
      final cache = KeyValueResourceCache((k) async => store[k], (k, v) async => store[k] = v);
      final at = DateTime.utc(2026, 11, 21, 9);
      await cache.write('mslearn', '[]', at);
      expect(store.keys.single, 'resources.cache.mslearn');
      final back = await cache.read('mslearn');
      expect(back?.body, '[]');
      expect(back?.at, at);
      store['resources.cache.mslearn'] = 'not json';
      expect(await cache.read('mslearn'), isNull);
    });
  });

  group('MIT Learn', () {
    test('reads videos, audit courses and paid programs', () {
      final list = parseMitLearn(fixture('mit_learn_search.json'));
      expect(list, hasLength(3));
      final video = list[0];
      expect(video.type, 'video');
      expect(video.minutes, 64);
      expect(video.access, Access.free);
      expect(video.licence, 'CC BY-NC-SA 4.0');
      expect(video.source, 'MIT OpenCourseWare');
      expect(video.summary, 'How worked examples help beginners.');
      final course = list[1];
      expect(course.type, 'course');
      expect(course.access, Access.audit);
      expect(course.level, 'Introductory');
      expect(course.length, '8 weeks, 10-12 hours per week');
      expect(course.licence, 'MITx terms');
      expect(list[2].access, Access.paid);
      expect(list[2].kind, 'Program');
      expect(() => parseMitLearn('{"oops": 1}'), throwsA(isA<ResourceError>()));
    });

    test('asks once per search, with the query and the resource types', () async {
      final m = mock((_) => ok(fixture('mit_learn_search.json')));
      final mit = MitLearnCatalogue(m.client);
      await mit.search('teaching');
      await mit.search('Teaching ');
      expect(m.asked, hasLength(1));
      final u = m.asked.single;
      expect(u.host, 'api.learn.mit.edu');
      expect(u.path, '/api/v1/learning_resources_search/');
      expect(u.queryParameters['q'], 'teaching');
      expect(u.queryParametersAll['resource_type'], containsAll(['course', 'video', 'program']));
    });
  });

  group('OpenLearn (link only)', () {
    test('a search opens OpenLearn\'s own search page; nothing is read from open.edu', () {
      final u = openLearnSearchUrl('  care work  ');
      expect(u.toString(), 'https://www.open.edu/openlearn/local/ocwglobalsearch/search.php?q=care+work');
      expect(u.queryParameters['q'], 'care work');
      final d = dataSources.firstWhere((d) => d.name.startsWith('OpenLearn'));
      expect(d.name, 'OpenLearn (link only)');
      expect(d.what, contains('Search OpenLearn'));
    });
  });

  group('Open Library', () {
    test('reads books: free to read, free to borrow, or to buy', () {
      final list = parseOpenLibrary(fixture('open_library_search.json'));
      expect(list.map((b) => b.access), [Access.paid, Access.free, Access.borrow]);
      final b = list.first;
      expect(b.type, 'book');
      expect(b.url, 'https://openlibrary.org/works/OL1000001W');
      expect(b.author, 'A. Example, B. Sample');
      expect(b.length, '331 pages');
      expect(b.kind, 'Book, 2014');
      expect(b.licence, 'Publisher copyright');
      expect(list[1].licence, 'Free e-book (check the edition)');
    });

    test('sends the app User-Agent with the project address, never a person', () async {
      final seen = <String, String>{};
      final client = MockClient((r) async {
        seen.addAll(r.headers);
        return ok(fixture('open_library_search.json'));
      });
      final clock = FakeClock();
      final ol = OpenLibraryCatalogue(
        client,
        limiter: PoliteLimiter(now: clock.now, sleep: (d) async => clock.advance(d)),
      );
      await ol.search('clinical teaching');
      expect(seen['User-Agent'], vidyaUserAgent);
      expect(vidyaUserAgent, contains('github.com/'));
      expect(vidyaUserAgent, isNot(contains('@')));
    });

    test('the limiter keeps to 3 requests a second without real waiting', () async {
      final clock = FakeClock();
      final slept = <Duration>[];
      final limiter = PoliteLimiter(
        now: clock.now,
        sleep: (d) async {
          slept.add(d);
          clock.advance(d);
        },
      );
      await Future.wait([limiter.wait(), limiter.wait(), limiter.wait()]);
      expect(slept, [const Duration(milliseconds: 334), const Duration(milliseconds: 334)]);
      // A second later there is nothing to wait for.
      clock.advance(const Duration(seconds: 1));
      await limiter.wait();
      expect(slept, hasLength(2));
      // A 429 holds everything back: by Retry-After, else 2, 4, 8 seconds.
      expect(limiter.backOff(0), const Duration(seconds: 2));
      expect(limiter.backOff(1), const Duration(seconds: 4));
      expect(limiter.backOff(0, retryAfter: const Duration(seconds: 9)), const Duration(seconds: 9));
      await limiter.wait();
      expect(slept.last, const Duration(seconds: 9));
      expect(retryAfterOf('5'), const Duration(seconds: 5));
      expect(retryAfterOf('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    });

    test('backs off on 429 and tries again; gives up after two more tries', () async {
      final clock = FakeClock();
      final slept = <Duration>[];
      PoliteLimiter limiter() => PoliteLimiter(
        now: clock.now,
        sleep: (d) async {
          slept.add(d);
          clock.advance(d);
        },
      );
      var busy = 1;
      final m = mock(
        (_) => busy-- > 0
            ? http.Response('slow down', 429, headers: {'retry-after': '5'})
            : ok(fixture('open_library_search.json')),
      );
      final ol = OpenLibraryCatalogue(m.client, limiter: limiter());
      expect(await ol.search('teaching'), hasLength(3));
      expect(m.asked, hasLength(2));
      expect(slept, [const Duration(seconds: 5)]);

      slept.clear();
      final always = mock((_) => http.Response('slow down', 429));
      await expectLater(
        OpenLibraryCatalogue(always.client, limiter: limiter()).search('teaching'),
        throwsA(isA<ResourceError>().having((e) => e.message, 'message', contains('busy'))),
      );
      expect(always.asked, hasLength(3));
      expect(slept, [const Duration(seconds: 2), const Duration(seconds: 4)]);
    });
  });

  group('YouTube', () {
    test('never asks without a key', () async {
      final m = mock((_) => ok(fixture('youtube_search.json')));
      await expectLater(YouTubeCatalogue(m.client, '').search('teaching'), throwsA(isA<ResourceError>()));
      await expectLater(YouTubeCatalogue(m.client, '   ').search('teaching'), throwsA(isA<ResourceError>()));
      expect(m.asked, isEmpty);
    });

    test('with a key: videos only, the key from the device keychain', () async {
      final m = mock((_) => ok(fixture('youtube_search.json')));
      final store = MemorySecretStore();
      expect(await ResourceSecrets.youtubeKey(store), '');
      await ResourceSecrets.saveYoutubeKey(store, ' made-up-key ');
      final key = await ResourceSecrets.youtubeKey(store);
      expect(key, 'made-up-key');
      final list = await YouTubeCatalogue(m.client, key).search('teaching');
      expect(list.single.title, 'Teaching a skill in 10 minutes & why it works');
      expect(list.single.url, 'https://www.youtube.com/watch?v=abc123XYZ00');
      expect(list.single.source, 'Example Channel');
      expect(m.asked.single.queryParameters['key'], 'made-up-key');
      await ResourceSecrets.saveYoutubeKey(store, '');
      expect(store.values, isEmpty);
    });
  });

  group('searching all at once', () {
    test('a failing catalogue still lets the others answer', () async {
      final changes = <List<String>>[];
      final statuses = await searchAll(
        [
          FakeCatalogue('Good', [res('Teaching basics', access: Access.free)]),
          FakeCatalogue('Broken', const [], fail: 'could not connect (are you offline?)'),
          FakeCatalogue('Empty', const []),
        ],
        'teaching',
        onChange: (s) => changes.add([for (final x in s) x.line]),
      );
      expect(statuses.map((s) => s.state), [SourceState.done, SourceState.failed, SourceState.done]);
      expect(statuses.map((s) => s.line), [
        'Good: 1 found',
        'Broken: could not connect (are you offline?)',
        'Empty: nothing found',
      ]);
      expect(changes.first, ['Good: searching…', 'Broken: searching…', 'Empty: searching…']);
      expect(rankResources('teaching', statuses).single.title, 'Teaching basics');
    });

    test('free first, then by fit; the same link only once', () {
      final s = SourceStatus(FakeCatalogue('a', const []))
        ..results = [
          res('Teaching on wards', access: Access.paid),
          res('A short history of everything', access: Access.free),
          res('Clinical teaching', access: Access.free),
          res('Clinical teaching', access: Access.free, url: 'https://EXAMPLE.org/Clinical-teaching'),
          res('Teaching skills', access: Access.audit),
        ];
      expect(rankResources('clinical teaching', [s]).map((r) => r.title), [
        'Clinical teaching',
        'A short history of everything',
        'Teaching skills',
        'Teaching on wards',
      ]);
      expect(fitScore('clinical teaching', 'Clinical Teaching'), 100);
      expect(
        fitScore('clinical teaching', 'Teaching'),
        lessThan(fitScore('clinical teaching', 'Clinical teaching in practice')),
      );
    });
  });

  group('adding a result as an item', () {
    test('maps the type, licence and badge, and keeps no description', () async {
      final store = await Store.open(memoryDatabase());
      addTearDown(store.db.close);
      final book = LearningBook(store);
      await book.importTemplate(programTemplates.first, today: '2026-11-21');
      final db = book.db;
      final topic = await db.select(db.learnTopics).get().then((t) => t.first);

      final video = parseMitLearn(fixture('mit_learn_search.json')).first;
      final f = resourceItemFields(video);
      expect(f.type, 'video');
      expect(f.licence, 'CC BY-NC-SA 4.0');
      expect(f.minutes, 64);
      expect(f.content, isNot(contains('worked examples')));
      await book.addItem(
        topic.id,
        f.type,
        f.title,
        url: f.url,
        source: f.source,
        licence: f.licence,
        minutes: f.minutes,
        content: f.content,
      );

      final book2 = parseOpenLibrary(fixture('open_library_search.json')).last;
      final g = resourceItemFields(book2);
      await book.addItem(
        topic.id,
        g.type,
        g.title,
        url: g.url,
        source: g.source,
        licence: g.licence,
        content: g.content,
      );

      final items = await (db.select(
        db.learnItems,
      )..where((i) => i.topicId.equals(topic.id) & i.ref.equals(''))).get();
      final v = items.firstWhere((i) => i.type == 'video');
      expect(v.title, 'Lecture 3: Teaching with examples');
      expect(v.licence, 'CC BY-NC-SA 4.0');
      expect(itemAccess(itemContent(v)), Access.free);
      final b = items.firstWhere((i) => i.type == 'book');
      expect(itemAccess(itemContent(b)), Access.borrow);
      expect(itemContent(b)['author'], 'C. Placeholder');
      expect(itemContent(b)['length'], '154 pages');

      // The learner corrects the badge later: "free" often changes.
      final fixed = withAccess(itemContent(b), Access.paid);
      expect(itemAccess(jsonDecode(fixed) as Map<String, Object?>), Access.paid);
      expect(withAccess(const {'access': 'free'}, Access.unknown), '');
    });
  });

  group('a pasted link', () {
    test('YouTube and Vimeo titles come from oEmbed', () async {
      final yt = parseOEmbed(fixture('youtube_oembed.json'), 'https://youtu.be/abc123XYZ00');
      expect(yt.title, 'Lecture 1: An example lecture');
      expect(yt.source, 'Example University');
      expect(yt.type, 'video');
      expect(yt.access, Access.free);
      final vimeo = parseOEmbed(fixture('vimeo_oembed.json'), 'https://vimeo.com/1');
      expect(vimeo.minutes, 2);

      final m = mock((_) => ok(fixture('youtube_oembed.json')));
      final info = await readLinkInfo(m.client, 'https://www.youtube.com/watch?v=abc123XYZ00');
      expect(info.title, 'Lecture 1: An example lecture');
      expect(m.asked.single.host, 'www.youtube.com');
      expect(m.asked.single.path, '/oembed');
      expect(m.asked.single.queryParameters['url'], 'https://www.youtube.com/watch?v=abc123XYZ00');
      expect(oEmbedFor('https://vimeo.com/1')?.path, '/api/oembed.json');
      expect(oEmbedFor('https://example.org/a'), isNull);
    });

    test('other pages: og:title, else the <title>; og:site_name as the source', () async {
      final page = parsePageMeta(fixture('page_meta.html'), 'https://www.example.org/safeguarding');
      expect(page.title, 'Safeguarding basics & you');
      expect(page.source, 'Example Learning Hub');
      expect(page.type, 'article');
      final bare = parsePageMeta(
        '<html><head><title>\n  Plain &amp; simple </title></head></html>',
        'https://www.example.org/a',
      );
      expect(bare.title, 'Plain & simple');
      expect(bare.source, 'example.org');

      final m = mock((_) => ok(fixture('page_meta.html'), type: 'text/html'));
      expect((await readLinkInfo(m.client, 'https://www.coursera.org/learn/example')).type, 'course');
      final missing = mock((_) => http.Response('gone', 404));
      await expectLater(readLinkInfo(missing.client, 'https://example.org/x'), throwsA(isA<ResourceError>()));
      await expectLater(readLinkInfo(missing.client, 'not a link'), throwsA(isA<ResourceError>()));
      expect(missing.asked, hasLength(1));
    });

    test('the type and badge are guessed from the address', () {
      expect(guessLinkType('https://youtu.be/x'), 'video');
      expect(guessLinkType('https://www.coursera.org/learn/x'), 'course');
      expect(guessLinkType('https://www.linkedin.com/learning/x'), 'course');
      expect(guessLinkType('https://www.e-lfh.org.uk/programmes/x'), 'course');
      expect(guessLinkType('https://openlibrary.org/works/OL1W'), 'book');
      expect(guessLinkType('https://example.org/post', ogType: 'video.other'), 'video');
      expect(guessLinkType('https://example.org/post'), 'article');
      expect(guessLinkAccess('https://www.coursera.org/learn/x'), Access.audit);
      expect(guessLinkAccess('https://www.udemy.com/course/x'), Access.paid);
      expect(guessLinkAccess('https://example.org/post'), Access.unknown);
    });
  });

  test('small readers: ISO durations and HTML text', () {
    expect(isoMinutes('PT1H3M30S'), 64);
    expect(isoMinutes('PT45S'), 1);
    expect(isoMinutes('nonsense'), 0);
    expect(plainText('<p>A &amp; B</p>\n<h4>C</h4>'), 'A & B C');
    expect(htmlUnescape('&#39;x&#x27; &quot;'), '\'x\' "');
  });
}
