/// Free resource search (role study plan V4): several free catalogues
/// searched at once, and the title of any pasted link read from the page.
///
/// Vidya keeps links and facts about a resource (title, address, source,
/// type, length, level, whether it is free, licence), never the lesson
/// text. OpenLearn and MIT OpenCourseWare are CC BY-NC-SA, so copying
/// their text into the app is not allowed anyway.
///
/// Nothing here goes online by itself: every request starts from the
/// learner tapping Search or "Read title".
///
/// The catalogues, checked against the live services on 2026-11-21:
///
/// * Microsoft Learn Catalog API, `GET https://learn.microsoft.com/api/catalog/?locale=en-us&type=modules,learningPaths,courses`.
///   No key. It returns the whole catalogue (about 7 MB), so Vidya keeps a
///   trimmed copy on the device for 24 hours and searches it locally.
/// * MIT Learn, `GET https://api.learn.mit.edu/api/v1/learning_resources_search/?q=…&limit=20&resource_type=…`.
///   No key. Answers are kept in memory, so a repeated search does not ask again.
/// * Open Library, `GET https://openlibrary.org/search.json?q=…&limit=10&fields=…`.
///   No key. At most 3 requests a second with an app User-Agent and a
///   contact address (the public repository, never a person), and it backs
///   off when told to slow down (HTTP 429).
/// * OpenLearn (The Open University) is link only: its RSS feeds answer
///   403 or a browser check to apps (checked again on 2026-11-21), and
///   Vidya skips sites that block automated clients. "Search OpenLearn"
///   opens OpenLearn's own search for the query in the browser instead
///   ([openLearnSearchUrl]); Vidya never fetches anything from open.edu.
/// * YouTube Data API v3 search, only with the learner's own key, which
///   stays in this device's keychain. Its free quota allows about 100
///   searches a day. Not checked live (no key on the build machine); the
///   reader follows Google's documented reply.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:brahma_core/brahma_core.dart' show SecretStore;
import 'package:http/http.dart' as http;

import 'study_items.dart';

/// The User-Agent sent with every request: the app and its public
/// repository as the contact, as Open Library asks. Never a person's name
/// or e-mail.
const vidyaUserAgent =
    'Vidya (open-source learning app; https://github.com/sudharamachandranrajeev/vidya-learning-manager)';

/// How free a resource is. The learner can correct it after adding, as
/// "free" often changes.
enum Access {
  free('free', 'Free'),
  audit('audit', 'Free to audit'),
  borrow('borrow', 'Free to borrow'),
  paid('paid', 'Paid'),
  unknown('', 'Not sure');

  const Access(this.key, this.label);

  /// What the item keeps in its extras ('' when not known).
  final String key;
  final String label;

  /// Free first, then free-with-limits, then not known, then paid.
  int get rank => switch (this) {
    free => 0,
    audit || borrow => 1,
    unknown => 2,
    paid => 3,
  };

  static Access of(String key) => values.where((a) => a.key == key).firstOrNull ?? unknown;
}

/// One search result: a link and the facts about it. No lesson text.
class Resource {
  const Resource({
    required this.catalogue,
    required this.title,
    required this.url,
    required this.source,
    required this.type,
    this.kind = '',
    this.minutes = 0,
    this.length = '',
    this.level = '',
    this.access = Access.unknown,
    this.licence = '',
    this.summary = '',
    this.author = '',
  });

  /// The id of the catalogue it came from ([ResourceCatalogue.id]).
  final String catalogue;
  final String title, url;

  /// The site, channel or publisher.
  final String source;

  /// The study item type it becomes: course, video, article or book.
  final String type;

  /// What the catalogue calls it ("Module", "Learning path", "Podcast episode").
  final String kind;

  /// Minutes when the catalogue gives them, else 0.
  final int minutes;

  /// Length in the catalogue's words when there are no minutes ("8 weeks", "331 pages").
  final String length;
  final String level;
  final Access access;
  final String licence;

  /// A line or two from the catalogue's description, shown in the results
  /// only; never stored with the item.
  final String summary;

  /// For books: the authors.
  final String author;
}

/// A catalogue failed: [message] is shown on its progress line.
class ResourceError implements Exception {
  const ResourceError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One free catalogue that can be searched.
abstract interface class ResourceCatalogue {
  /// A short stable id ("mslearn").
  String get id;

  /// The name shown to the learner.
  String get name;

  /// Up to about 20 resources for [query], best fit first.
  Future<List<Resource>> search(String query);
}

/// Where catalogue copies are kept between runs: this device's local
/// settings (not synced). [read] gives the text and when it was saved.
abstract interface class ResourceCache {
  Future<({String body, DateTime at})?> read(String key);
  Future<void> write(String key, String body, DateTime at);
}

/// A cache over any text store, such as the database's local settings.
class KeyValueResourceCache implements ResourceCache {
  KeyValueResourceCache(this._get, this._put);
  final Future<String?> Function(String key) _get;
  final Future<void> Function(String key, String value) _put;

  static String _key(String k) => 'resources.cache.$k';

  @override
  Future<({String body, DateTime at})?> read(String key) async {
    final raw = await _get(_key(key));
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      final at = DateTime.tryParse('${j['at']}');
      if (at == null || j['body'] is! String) return null;
      return (body: j['body'] as String, at: at);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String body, DateTime at) =>
      _put(_key(key), jsonEncode({'at': at.toUtc().toIso8601String(), 'body': body}));
}

/// A cache in memory, for tests.
class MemoryResourceCache implements ResourceCache {
  final values = <String, ({String body, DateTime at})>{};
  @override
  Future<({String body, DateTime at})?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String body, DateTime at) async => values[key] = (body: body, at: at);
}

// ---- small helpers ----

const _timeout = Duration(seconds: 20);

Map<String, String> get _headers => const {'User-Agent': vidyaUserAgent, 'Accept': 'application/json'};

/// GET [uri], or a [ResourceError] that says what went wrong in plain words.
Future<http.Response> _get(http.Client client, Uri uri, {Map<String, String>? headers}) async {
  final http.Response r;
  try {
    r = await client.get(uri, headers: headers ?? _headers).timeout(_timeout);
  } on TimeoutException {
    throw const ResourceError('took too long to answer');
  } on http.ClientException {
    throw const ResourceError('could not connect (are you offline?)');
  }
  if (r.statusCode == 429) throw const ResourceError('asked us to slow down; try again in a minute');
  if (r.statusCode != 200) throw ResourceError('answered with an error (${r.statusCode})');
  return r;
}

Object? _json(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    throw const ResourceError('sent something Vidya could not read');
  }
}

String _str(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v');

List<String> _strs(Object? v) => [
  if (v is List)
    for (final x in v)
      if (_str(x).isNotEmpty) _str(x),
];

/// Decodes the HTML entities that turn up in titles and descriptions.
String htmlUnescape(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
  final e = m[1]!;
  if (e.startsWith('#x') || e.startsWith('#X')) {
    final c = int.tryParse(e.substring(2), radix: 16);
    return c == null ? m[0]! : String.fromCharCode(c);
  }
  if (e.startsWith('#')) {
    final c = int.tryParse(e.substring(1));
    return c == null ? m[0]! : String.fromCharCode(c);
  }
  return switch (e.toLowerCase()) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' => "'",
    'nbsp' => ' ',
    'ndash' => '–',
    'mdash' => '—',
    'hellip' => '…',
    'rsquo' => '’',
    'lsquo' => '‘',
    _ => m[0]!,
  };
});

/// [html] as plain text on one line, cut to [max] characters.
String plainText(String html, {int max = 240}) {
  final t = htmlUnescape(html.replaceAll(RegExp(r'<[^>]*>'), ' '))
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r' ([.,;:!?])'), (m) => m[1]!)
      .trim();
  return t.length <= max ? t : '${t.substring(0, max - 1).trimRight()}…';
}

/// "beginner" → "Beginner"; "data-analyst" → "Data analyst".
String _nice(String s) {
  final t = s.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
}

/// Minutes in an ISO 8601 duration ("PT1H3M30S" → 64), 0 when unreadable.
int isoMinutes(String d) {
  final m = RegExp(r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$').firstMatch(d.trim());
  if (m == null) return 0;
  int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final seconds = n(1) * 86400 + n(2) * 3600 + n(3) * 60 + n(4);
  return (seconds / 60).ceil();
}

const _stopWords = {'a', 'an', 'and', 'the', 'of', 'for', 'to', 'in', 'on', 'with', 'how', 'what', 'is'};

/// The words of a query that count, lower case.
List<String> queryWords(String q) => [
  for (final w in q.toLowerCase().split(RegExp(r'[^a-z0-9+#]+')))
    if (w.isNotEmpty && !_stopWords.contains(w)) w,
];

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9+#]+'), ' ').trim();

bool _hasWord(String normText, String word) => ' $normText'.contains(' $word');

/// How well a resource fits [query], from 0 (no word found) to 100 (the
/// title is the query). Only fit counts: never popularity or provider.
/// The title weighs most; [other] (summary, roles, products) adds a little.
double fitScore(String query, String title, [String other = '']) {
  final words = queryWords(query);
  if (words.isEmpty) return 0;
  final t = _norm(title), q = _norm(query);
  if (t == q) return 100;
  final o = _norm(other);
  var inTitle = 0, inOther = 0;
  for (final w in words) {
    if (_hasWord(t, w)) {
      inTitle++;
    } else if (_hasWord(o, w)) {
      inOther++;
    }
  }
  final phrase = q.isNotEmpty && ' $t '.contains(' $q ') ? 20 : 0;
  return math.min(99, phrase + 55 * inTitle / words.length + 20 * inOther / words.length);
}

/// Whether every word of [query] is in [title] or [other].
bool matchesAll(String query, String title, String other) {
  final text = '${_norm(title)} ${_norm(other)}';
  return queryWords(query).every((w) => _hasWord(text, w));
}

/// An in-memory store of recent answers, so the same search does not ask
/// a service twice in one run.
class _Recent {
  _Recent(this.now);
  final DateTime Function() now;
  static const keep = Duration(hours: 24);
  final _map = <String, ({List<Resource> list, DateTime at})>{};

  List<Resource>? get(String q) {
    final hit = _map[q.trim().toLowerCase()];
    if (hit == null || now().difference(hit.at) > keep) return null;
    return hit.list;
  }

  void put(String q, List<Resource> list) {
    if (_map.length >= 30) _map.remove(_map.keys.first);
    _map[q.trim().toLowerCase()] = (list: list, at: now());
  }
}

// ---- Microsoft Learn ----

/// Microsoft Learn's free modules and learning paths, and its paid
/// instructor-led courses, from the Catalog API (no key). The whole
/// catalogue comes in one answer, so a trimmed copy is kept on the device
/// for a day and searched here.
class MicrosoftLearnCatalogue implements ResourceCatalogue {
  MicrosoftLearnCatalogue(this.client, this.cache, {DateTime Function()? now}) : now = now ?? DateTime.now;
  final http.Client client;
  final ResourceCache cache;
  final DateTime Function() now;

  static final endpoint = Uri.parse(
    'https://learn.microsoft.com/api/catalog/?locale=en-us&type=modules,learningPaths,courses',
  );
  static const keepFor = Duration(hours: 24);
  static const _cacheKey = 'mslearn';
  static const licence = 'Microsoft Learn terms';

  List<Map<String, Object?>>? _entries;
  DateTime? _loadedAt;

  @override
  String get id => 'mslearn';
  @override
  String get name => 'Microsoft Learn';

  /// The trimmed catalogue: fresh in memory, else the device copy if under
  /// a day old, else fetched again. A failed fetch falls back to an old copy.
  Future<List<Map<String, Object?>>> _catalogue() async {
    final t = now();
    if (_entries != null && _loadedAt != null && t.difference(_loadedAt!) < keepFor) return _entries!;
    final saved = await cache.read(_cacheKey);
    if (saved != null && t.difference(saved.at) < keepFor) {
      _entries = _decodeEntries(saved.body);
      _loadedAt = saved.at;
      return _entries!;
    }
    try {
      final r = await _get(client, endpoint);
      final body = r.body;
      // The full answer is large: trim it away from the screen's thread.
      final trimmed = body.length > 500000
          ? await Isolate.run(() => trimMsLearnCatalogue(body))
          : trimMsLearnCatalogue(body);
      await cache.write(_cacheKey, trimmed, t);
      _entries = _decodeEntries(trimmed);
      _loadedAt = t;
      return _entries!;
    } on ResourceError {
      if (saved != null) return _entries = _decodeEntries(saved.body);
      rethrow;
    }
  }

  static List<Map<String, Object?>> _decodeEntries(String body) => [
    for (final e in (jsonDecode(body) as List)) (e as Map).cast<String, Object?>(),
  ];

  @override
  Future<List<Resource>> search(String query) async {
    final entries = await _catalogue();
    final hits = <(double, Resource)>[];
    for (final e in entries) {
      final title = _str(e['t']);
      final other = [
        e['s'],
        ..._strs(e['r']),
        ..._strs(e['p']),
        ..._strs(e['j']),
        ..._strs(e['l']),
      ].join(' ');
      if (!matchesAll(query, title, other)) continue;
      hits.add((fitScore(query, title, other), msLearnResource(e)));
    }
    hits.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final h in hits.take(20)) h.$2];
  }
}

/// The Catalog API's answer cut down to what search and results need, as
/// a compact JSON list: title, address, short summary, kind, minutes,
/// levels, roles, products and subjects.
String trimMsLearnCatalogue(String body) {
  final j = _json(body);
  if (j is! Map) throw const ResourceError('sent something Vidya could not read');
  final out = <Map<String, Object?>>[];
  for (final (key, kind) in [
    ('modules', 'module'),
    ('learningPaths', 'learningPath'),
    ('courses', 'course'),
  ]) {
    for (final e in (j[key] as List?) ?? const []) {
      if (e is! Map) continue;
      final title = _str(e['title']), url = _str(e['url']);
      if (title.isEmpty || url.isEmpty) continue;
      final minutes = switch ((e['duration_in_minutes'], e['duration_in_hours'])) {
        (final num m, _) => m.round(),
        (_, final num h) => (h * 60).round(),
        _ => 0,
      };
      out.add({
        't': title,
        'u': url,
        's': plainText(_str(e['summary']), max: 300),
        'k': kind,
        'm': minutes,
        'l': _strs(e['levels']),
        'r': _strs(e['roles']),
        'p': _strs(e['products']),
        'j': _strs(e['subjects']),
      });
    }
  }
  return jsonEncode(out);
}

/// One trimmed catalogue entry as a result. Modules and learning paths are
/// free; instructor-led courses are paid.
Resource msLearnResource(Map<String, Object?> e) {
  final kind = _str(e['k']);
  return Resource(
    catalogue: 'mslearn',
    title: _str(e['t']),
    url: _str(e['u']),
    source: 'Microsoft Learn',
    type: 'course',
    kind: switch (kind) {
      'module' => 'Module',
      'learningPath' => 'Learning path',
      _ => 'Course with a trainer',
    },
    minutes: (e['m'] as num?)?.round() ?? 0,
    level: _strs(e['l']).map(_nice).join(', '),
    access: kind == 'course' ? Access.paid : Access.free,
    licence: MicrosoftLearnCatalogue.licence,
    summary: _str(e['s']),
  );
}

// ---- MIT Learn ----

/// MIT Learn's search (no key): MIT OpenCourseWare, MITx and MIT's other
/// courses, programs, videos and podcasts. Answers are kept in memory.
class MitLearnCatalogue implements ResourceCatalogue {
  MitLearnCatalogue(this.client, {DateTime Function()? now}) : _recent = _Recent(now ?? DateTime.now);
  final http.Client client;
  final _Recent _recent;

  static const types = ['course', 'program', 'learning_path', 'video', 'video_playlist', 'podcast_episode'];

  @override
  String get id => 'mit';
  @override
  String get name => 'MIT Learn';

  static Uri uriFor(String query) =>
      Uri.parse('https://api.learn.mit.edu/api/v1/learning_resources_search/')
          .replace(queryParameters: {'q': query.trim(), 'limit': '20', 'resource_type': types});

  @override
  Future<List<Resource>> search(String query) async {
    if (_recent.get(query) case final hit?) return hit;
    final r = await _get(client, uriFor(query));
    final list = parseMitLearn(r.body);
    _recent.put(query, list);
    return list;
  }
}

/// Reads an MIT Learn search answer. OpenCourseWare is CC BY-NC-SA 4.0;
/// free with a paid certificate is "free to audit"; not free is paid.
List<Resource> parseMitLearn(String body) {
  final j = _json(body);
  final results = j is Map ? j['results'] : null;
  if (results is! List) throw const ResourceError('sent something Vidya could not read');
  final out = <Resource>[];
  for (final r in results) {
    if (r is! Map) continue;
    final title = _str(r['title']);
    final url = _str(r['url']).isNotEmpty ? _str(r['url']) : _str(r['learn_url']);
    if (title.isEmpty || url.isEmpty) continue;
    final rt = _str(r['resource_type']);
    final offeredBy = r['offered_by'] is Map ? _str((r['offered_by'] as Map)['name']) : '';
    final ocw = r['platform'] is Map && _str((r['platform'] as Map)['code']) == 'ocw';
    final prices = [for (final p in _strs(r['prices'])) double.tryParse(p) ?? 0];
    final free = r['free'] == true;
    final access = !free
        ? Access.paid
        : prices.any((p) => p > 0)
        ? Access.audit
        : Access.free;
    final video = r['video'] is Map ? r['video'] as Map : const {};
    final levels = <String>{
      for (final run in (r['runs'] as List?) ?? const [])
        if (run is Map)
          for (final l in (run['level'] as List?) ?? const [])
            if (l is Map && _str(l['name']).isNotEmpty) _str(l['name']),
    };
    out.add(
      Resource(
        catalogue: 'mit',
        title: htmlUnescape(title),
        url: url,
        source: offeredBy.isEmpty ? 'MIT Learn' : offeredBy,
        type: switch (rt) {
          'video' || 'video_playlist' || 'podcast_episode' || 'podcast' => 'video',
          'document' => 'article',
          _ => 'course',
        },
        kind: _nice(rt),
        minutes: isoMinutes(_str(video['duration'])),
        length: [_str(r['duration']), _str(r['time_commitment'])].where((s) => s.isNotEmpty).join(', '),
        level: levels.join(', '),
        access: access,
        licence: ocw || r['license_cc'] == true
            ? 'CC BY-NC-SA 4.0'
            : '${offeredBy.isEmpty ? 'Provider' : offeredBy} terms',
        summary: plainText(_str(r['description'])),
      ),
    );
  }
  return out;
}

// ---- OpenLearn (link only) ----

/// OpenLearn's own search page for [query], opened in the browser by the
/// "Search OpenLearn" row. Vidya does not read OpenLearn over the network:
/// its feeds block apps, and the project skips sites that do.
Uri openLearnSearchUrl(String query) => Uri.https('www.open.edu', '/openlearn/local/ocwglobalsearch/search.php', {
  'q': query.trim(),
});

// ---- Open Library ----

/// Keeps requests to a service at or under a rate (Open Library: 3 a
/// second) and holds them back after a "slow down" (HTTP 429). The clock
/// and the wait are passed in, so tests run without real waiting.
class PoliteLimiter {
  PoliteLimiter({
    this.minGap = const Duration(milliseconds: 334),
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : now = now ?? DateTime.now,
       sleep = sleep ?? ((d) => Future<void>.delayed(d));
  final Duration minGap;
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;

  DateTime? _next;
  Future<void> _tail = Future.value();

  /// Waits until the next request may go, then books the slot after it.
  /// Calls made together go one after another.
  Future<void> wait() {
    final turn = _tail.then((_) async {
      final next = _next;
      if (next != null) {
        final gap = next.difference(now());
        if (gap > Duration.zero) await sleep(gap);
      }
      _next = now().add(minGap);
    });
    _tail = turn.catchError((_) {});
    return turn;
  }

  /// After a 429: hold every request back for [retryAfter] when the service
  /// said how long, else 2, 4, 8… seconds by [attempt] (at most a minute).
  /// Returns the pause.
  Duration backOff(int attempt, {Duration? retryAfter}) {
    final d = retryAfter ?? Duration(seconds: math.min(60, 2 << attempt));
    final until = now().add(d);
    if (_next == null || until.isAfter(_next!)) _next = until;
    return d;
  }
}

/// The seconds in a Retry-After header, or null.
Duration? retryAfterOf(String? header) {
  final s = int.tryParse(header?.trim() ?? '');
  return s == null || s < 0 ? null : Duration(seconds: math.min(s, 120));
}

/// Open Library's book search (no key), at most 3 requests a second.
class OpenLibraryCatalogue implements ResourceCatalogue {
  OpenLibraryCatalogue(this.client, {PoliteLimiter? limiter, DateTime Function()? now})
    : limiter = limiter ?? PoliteLimiter(),
      _recent = _Recent(now ?? DateTime.now);
  final http.Client client;
  final PoliteLimiter limiter;
  final _Recent _recent;

  /// How many times a 429 is waited out before giving up.
  static const retries = 2;

  @override
  String get id => 'openlibrary';
  @override
  String get name => 'Open Library';

  static Uri uriFor(String query) => Uri.parse('https://openlibrary.org/search.json').replace(
    queryParameters: {
      'q': query.trim(),
      'limit': '10',
      'fields': 'key,title,author_name,first_publish_year,number_of_pages_median,ebook_access',
    },
  );

  @override
  Future<List<Resource>> search(String query) async {
    if (_recent.get(query) case final hit?) return hit;
    for (var attempt = 0; ; attempt++) {
      await limiter.wait();
      final http.Response r;
      try {
        r = await client.get(uriFor(query), headers: _headers).timeout(_timeout);
      } on TimeoutException {
        throw const ResourceError('took too long to answer');
      } on http.ClientException {
        throw const ResourceError('could not connect (are you offline?)');
      }
      if (r.statusCode == 429) {
        limiter.backOff(attempt, retryAfter: retryAfterOf(r.headers['retry-after']));
        if (attempt >= retries) throw const ResourceError('is busy; try again in a minute');
        continue;
      }
      if (r.statusCode != 200) throw ResourceError('answered with an error (${r.statusCode})');
      final list = parseOpenLibrary(r.body);
      _recent.put(query, list);
      return list;
    }
  }
}

/// Reads an Open Library search answer. A public e-book is free to read, a
/// borrowable one free to borrow; other books are to buy or borrow from a
/// library (shown as paid).
List<Resource> parseOpenLibrary(String body) {
  final j = _json(body);
  final docs = j is Map ? j['docs'] : null;
  if (docs is! List) throw const ResourceError('sent something Vidya could not read');
  return [
    for (final d in docs)
      if (d is Map && _str(d['title']).isNotEmpty && _str(d['key']).startsWith('/'))
        Resource(
          catalogue: 'openlibrary',
          title: _str(d['title']),
          url: 'https://openlibrary.org${_str(d['key'])}',
          source: 'Open Library',
          type: 'book',
          kind: ['Book', if (d['first_publish_year'] is num) '${d['first_publish_year']}'].join(', '),
          length: d['number_of_pages_median'] is num ? '${d['number_of_pages_median']} pages' : '',
          author: _strs(d['author_name']).take(3).join(', '),
          access: switch (_str(d['ebook_access'])) {
            'public' => Access.free,
            'borrowable' || 'printdisabled' => Access.borrow,
            _ => Access.paid,
          },
          licence: _str(d['ebook_access']) == 'public'
              ? 'Free e-book (check the edition)'
              : 'Publisher copyright',
        ),
  ];
}

// ---- YouTube (own key only) ----

/// Where the learner's YouTube key lives: this device's keychain only.
/// Never synced, never in the repository or a test fixture.
abstract final class ResourceSecrets {
  static const youtube = 'vidya.youtube.key';

  /// The saved YouTube key, '' when none (YouTube search is then off).
  static Future<String> youtubeKey(SecretStore? store) async =>
      store == null ? '' : (await store.read(youtube) ?? '').trim();

  /// Saves the key; an empty one removes it (YouTube search off).
  static Future<void> saveYoutubeKey(SecretStore store, String key) =>
      key.trim().isEmpty ? store.delete(youtube) : store.write(youtube, key.trim());
}

/// YouTube video search with the learner's own Data API key. Without a key
/// it never makes a request. The free quota allows about 100 searches a
/// day, so answers are kept in memory.
class YouTubeCatalogue implements ResourceCatalogue {
  YouTubeCatalogue(this.client, this.key, {DateTime Function()? now})
    : _recent = _Recent(now ?? DateTime.now);
  final http.Client client;
  final String key;
  final _Recent _recent;

  @override
  String get id => 'youtube';
  @override
  String get name => 'YouTube';

  @override
  Future<List<Resource>> search(String query) async {
    if (key.trim().isEmpty) throw const ResourceError('needs your own key in Settings');
    if (_recent.get(query) case final hit?) return hit;
    final uri = Uri.parse('https://www.googleapis.com/youtube/v3/search').replace(
      queryParameters: {
        'part': 'snippet',
        'type': 'video',
        'maxResults': '10',
        'q': query.trim(),
        'key': key.trim(),
      },
    );
    final http.Response r;
    try {
      r = await client.get(uri, headers: _headers).timeout(_timeout);
    } on TimeoutException {
      throw const ResourceError('took too long to answer');
    } on http.ClientException {
      throw const ResourceError('could not connect (are you offline?)');
    }
    if (r.statusCode == 403) throw const ResourceError('refused the key, or today\'s quota is used up');
    if (r.statusCode != 200) throw ResourceError('answered with an error (${r.statusCode})');
    final list = parseYouTubeSearch(r.body);
    _recent.put(query, list);
    return list;
  }
}

/// Reads a YouTube Data API search answer: videos only.
List<Resource> parseYouTubeSearch(String body) {
  final j = _json(body);
  final items = j is Map ? j['items'] : null;
  if (items is! List) throw const ResourceError('sent something Vidya could not read');
  return [
    for (final i in items)
      if (i is Map && i['id'] is Map && _str((i['id'] as Map)['videoId']).isNotEmpty && i['snippet'] is Map)
        Resource(
          catalogue: 'youtube',
          title: htmlUnescape(_str((i['snippet'] as Map)['title'])),
          url: 'https://www.youtube.com/watch?v=${_str((i['id'] as Map)['videoId'])}',
          source: _str((i['snippet'] as Map)['channelTitle']).isEmpty
              ? 'YouTube'
              : _str((i['snippet'] as Map)['channelTitle']),
          type: 'video',
          kind: 'Video',
          access: Access.free,
          licence: 'YouTube terms',
          summary: plainText(_str((i['snippet'] as Map)['description'])),
        ),
  ];
}

// ---- searching all at once ----

enum SourceState { searching, done, failed }

/// One catalogue's part of a search: its state, results or error.
class SourceStatus {
  SourceStatus(this.catalogue);
  final ResourceCatalogue catalogue;
  SourceState state = SourceState.searching;
  List<Resource> results = const [];
  String error = '';

  /// The progress line: "Microsoft Learn: 12 found".
  String get line => switch (state) {
    SourceState.searching => '${catalogue.name}: searching…',
    SourceState.done => '${catalogue.name}: ${results.isEmpty ? 'nothing found' : '${results.length} found'}',
    SourceState.failed => '${catalogue.name}: $error',
  };
}

/// Searches every catalogue at once. Each finishes on its own: a slow or
/// failing one never holds up or hides the others. [onChange] runs each
/// time one finishes.
Future<List<SourceStatus>> searchAll(
  List<ResourceCatalogue> catalogues,
  String query, {
  void Function(List<SourceStatus>)? onChange,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final statuses = [for (final c in catalogues) SourceStatus(c)];
  onChange?.call(statuses);
  await Future.wait([
    for (final s in statuses)
      () async {
        try {
          s.results = await s.catalogue.search(query).timeout(timeout);
          s.state = SourceState.done;
        } on TimeoutException {
          s.state = SourceState.failed;
          s.error = 'took too long to answer';
        } on ResourceError catch (e) {
          s.state = SourceState.failed;
          s.error = e.message;
        } catch (_) {
          s.state = SourceState.failed;
          s.error = 'something went wrong';
        }
        onChange?.call(statuses);
      }(),
  ]);
  return statuses;
}

/// All results in one list: free first, then by fit to [query], with
/// repeats of the same link dropped.
List<Resource> rankResources(String query, Iterable<SourceStatus> statuses) {
  final seen = <String>{};
  final all = <(double, Resource)>[];
  for (final s in statuses) {
    for (final r in s.results) {
      if (!seen.add(r.url.trim().toLowerCase())) continue;
      all.add((fitScore(query, r.title, '${r.summary} ${r.kind} ${r.author}'), r));
    }
  }
  all.sort((a, b) {
    final byAccess = a.$2.access.rank.compareTo(b.$2.access.rank);
    if (byAccess != 0) return byAccess;
    final byFit = b.$1.compareTo(a.$1);
    return byFit != 0 ? byFit : a.$2.title.toLowerCase().compareTo(b.$2.title.toLowerCase());
  });
  return [for (final x in all) x.$2];
}

/// What a result becomes as a study item: its type, title, link, source,
/// licence, minutes, and the extras kept as JSON (free/paid badge, level,
/// length, author and catalogue). No description or lesson text.
({String type, String title, String url, String source, String licence, int minutes, String content})
resourceItemFields(Resource r) => (
  type: itemTypes.containsKey(r.type) ? r.type : 'article',
  title: r.title,
  url: r.url,
  source: r.source,
  licence: r.licence,
  minutes: r.minutes,
  content: jsonEncode({
    if (r.access != Access.unknown) 'access': r.access.key,
    if (r.level.isNotEmpty) 'level': r.level,
    if (r.length.isNotEmpty) 'length': r.length,
    if (r.author.isNotEmpty) 'author': r.author,
    'catalogue': r.catalogue,
  }),
);

/// An item's free/paid badge from its extras.
Access itemAccess(Map<String, Object?> content) => Access.of(_str(content['access']));

/// The item extras [content] with the badge set to [access] (removed when
/// not known), as JSON for the item ('' when nothing is left).
String withAccess(Map<String, Object?> content, Access access) {
  final m = {...content}..remove('access');
  if (access != Access.unknown) m['access'] = access.key;
  return m.isEmpty ? '' : jsonEncode(m);
}

// ---- a pasted link ----

/// What one pasted link's page says about itself.
class LinkInfo {
  const LinkInfo({
    this.title = '',
    this.source = '',
    this.type = 'article',
    this.minutes = 0,
    this.access = Access.unknown,
  });
  final String title, source, type;
  final int minutes;
  final Access access;
}

/// The item type a link most likely is, from its address and the page's
/// og:type: video sites are videos, course sites courses, book sites books,
/// anything else an article.
String guessLinkType(String url, {String ogType = ''}) {
  final u = Uri.tryParse(url.trim());
  final host = (u?.host ?? '').toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  final path = (u?.path ?? '').toLowerCase();
  bool on(String h) => host == h || host.endsWith('.$h');
  if (on('youtube.com') || host == 'youtu.be' || on('vimeo.com') || ogType.startsWith('video')) {
    return 'video';
  }
  if (on('openlibrary.org') ||
      (on('google.com') && path.startsWith('/books')) ||
      on('goodreads.com') ||
      ogType == 'book') {
    return 'book';
  }
  if (on('coursera.org') ||
      on('edx.org') ||
      on('udemy.com') ||
      on('futurelearn.com') ||
      on('khanacademy.org') ||
      on('e-lfh.org.uk') ||
      on('learninghub.nhs.uk') ||
      (on('linkedin.com') && path.startsWith('/learning')) ||
      (on('open.edu') && path.startsWith('/openlearn')) ||
      (on('learn.microsoft.com') && path.contains('/training/')) ||
      (on('mit.edu') && path.startsWith('/courses'))) {
    return 'course';
  }
  return linkTypeOf(url);
}

/// A first guess at how free a pasted link is, for the learner to correct:
/// video sites are free, Coursera and edX free to audit, Udemy and
/// LinkedIn Learning paid; else not known.
Access guessLinkAccess(String url) {
  final host = (Uri.tryParse(url.trim())?.host ?? '').toLowerCase();
  final path = (Uri.tryParse(url.trim())?.path ?? '').toLowerCase();
  bool on(String h) => host == h || host.endsWith('.$h');
  if (on('youtube.com') || host == 'youtu.be' || on('vimeo.com')) return Access.free;
  if (on('coursera.org') || on('edx.org')) return Access.audit;
  if (on('udemy.com') || (on('linkedin.com') && path.startsWith('/learning'))) return Access.paid;
  if (on('open.edu') || on('ocw.mit.edu') || on('learn.microsoft.com')) return Access.free;
  return Access.unknown;
}

/// The oEmbed address for YouTube and Vimeo links, else null.
Uri? oEmbedFor(String url) {
  final host = (Uri.tryParse(url.trim())?.host ?? '').toLowerCase();
  if (host.endsWith('youtube.com') || host == 'youtu.be') {
    return Uri.parse('https://www.youtube.com/oembed')
        .replace(queryParameters: {'format': 'json', 'url': url.trim()});
  }
  if (host.endsWith('vimeo.com')) {
    return Uri.parse('https://vimeo.com/api/oembed.json').replace(queryParameters: {'url': url.trim()});
  }
  return null;
}

/// Reads an oEmbed answer: the title, the channel, and minutes when given
/// (Vimeo gives a duration in seconds).
LinkInfo parseOEmbed(String body, String url) {
  final j = _json(body);
  if (j is! Map || _str(j['title']).isEmpty) throw const ResourceError('gave no title');
  final seconds = j['duration'] is num ? (j['duration'] as num).toInt() : 0;
  return LinkInfo(
    title: htmlUnescape(_str(j['title'])),
    source: _str(j['author_name']).isNotEmpty ? _str(j['author_name']) : _str(j['provider_name']),
    type: 'video',
    minutes: seconds > 0 ? (seconds / 60).ceil() : 0,
    access: guessLinkAccess(url),
  );
}

/// The content of the `<meta>` tag whose property or name is [name].
String _meta(String html, String name) {
  for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = m[0]!;
    final key = RegExp(
      r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(tag)?[1];
    if (key?.toLowerCase() != name) continue;
    final content = RegExp(
      'content\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')',
      caseSensitive: false,
    ).firstMatch(tag);
    final v = content?[1] ?? content?[2];
    if (v != null && v.trim().isNotEmpty) return htmlUnescape(v).trim();
  }
  return '';
}

/// Reads one page's own description of itself: og:title, else `<title>`;
/// og:site_name, else the host, as the source; og:type to guess the type.
/// Nothing else of the page is read or kept.
LinkInfo parsePageMeta(String html, String url) {
  var title = _meta(html, 'og:title');
  if (title.isEmpty) {
    final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?[1] ?? '';
    title = htmlUnescape(t).replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  final host = (Uri.tryParse(url.trim())?.host ?? '').replaceFirst(RegExp(r'^www\.'), '');
  final site = _meta(html, 'og:site_name');
  return LinkInfo(
    title: title,
    source: site.isNotEmpty ? site : host,
    type: guessLinkType(url, ogType: _meta(html, 'og:type').toLowerCase()),
    access: guessLinkAccess(url),
  );
}

/// The most of a page read for its title: its head is near the top.
const _pageBytes = 512 * 1024;

/// Reads a pasted link's title: through oEmbed for YouTube and Vimeo,
/// otherwise from that one page's og:title or `<title>`. Throws a
/// [ResourceError] when it cannot; the learner then types the title.
Future<LinkInfo> readLinkInfo(http.Client client, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http') || uri.host.isEmpty) {
    throw const ResourceError('That is not a web address.');
  }
  if (oEmbedFor(url) case final o?) {
    final r = await _get(client, o);
    return parseOEmbed(r.body, url);
  }
  final http.StreamedResponse r;
  try {
    r = await client
        .send(http.Request('GET', uri)..headers.addAll({'User-Agent': vidyaUserAgent, 'Accept': 'text/html'}))
        .timeout(_timeout);
  } on TimeoutException {
    throw const ResourceError('The page took too long to answer.');
  } on http.ClientException {
    throw const ResourceError('Could not reach the page (are you offline?).');
  }
  if (r.statusCode != 200) throw ResourceError('The page answered with an error (${r.statusCode}).');
  final bytes = <int>[];
  try {
    await for (final chunk in r.stream.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length >= _pageBytes) break;
    }
  } on TimeoutException {
    if (bytes.isEmpty) throw const ResourceError('The page took too long to answer.');
  }
  final info = parsePageMeta(utf8.decode(bytes, allowMalformed: true), url);
  if (info.title.isEmpty) throw const ResourceError('The page has no title to read.');
  return info;
}

/// One catalogue for the Settings list: what it is, its licence or terms,
/// and where to read them.
typedef DataSource = ({String name, String what, String terms, String url});

/// Every catalogue Vidya can search, for Settings > Data sources.
const dataSources = <DataSource>[
  (
    name: 'Microsoft Learn',
    what: 'Free modules and learning paths (tech, data, Microsoft products). The catalogue is kept on this device for a day.',
    terms: 'Microsoft Learn terms of use',
    url: 'https://learn.microsoft.com/en-us/legal/termsofuse',
  ),
  (
    name: 'MIT Learn',
    what: 'MIT OpenCourseWare and MIT courses, videos and podcasts.',
    terms: 'OpenCourseWare: CC BY-NC-SA 4.0; other MIT courses: their own terms',
    url: 'https://ocw.mit.edu/pages/privacy-and-terms-of-use/',
  ),
  (
    name: 'OpenLearn (link only)',
    what:
        'Free courses from The Open University, including health and care. Its feeds block apps, so Vidya does not '
        'search it: "Search OpenLearn" opens its own search in your browser.',
    terms: 'CC BY-NC-SA 4.0',
    url: 'https://www.open.edu/openlearn/about-openlearn/try',
  ),
  (
    name: 'Open Library',
    what: 'Books, with whether they can be read or borrowed free. At most 3 requests a second.',
    terms: 'Open Library API guidelines',
    url: 'https://openlibrary.org/developers/api',
  ),
  (
    name: 'YouTube (optional)',
    what: 'Video search with your own API key only. Off until you add one; about 100 searches a day.',
    terms: 'YouTube API Services terms',
    url: 'https://developers.google.com/youtube/terms/api-services-terms-of-service',
  ),
];
