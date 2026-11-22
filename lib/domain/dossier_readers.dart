/// The dossier's official readers (journey plan J5): NHS ODS (no key),
/// and CQC and Companies House with the learner's own keys (off until a
/// key is added; without one Vidya only links to their sites). Each reads
/// only when the learner asks, waits between requests to a site, names
/// Vidya in every request and keeps answers for a week, so a second look
/// asks nothing. Glassdoor, Indeed and LinkedIn are never read by a
/// program: their terms forbid it, so the learner pastes what they read.
///
/// Each record becomes the text Vidya keeps as a source, with one line per
/// fact; the facts' quotes are those lines, so they pass the quote check.
library;

import 'dart:async';
import 'dart:convert';

import 'package:brahma_core/brahma_core.dart' show SecretStore, isValidIsoDate;
import 'package:http/http.dart' as http;

import 'dossier.dart';
import 'dossier_book.dart';

/// Every request names Vidya and where it comes from.
const researchAgent =
    'Vidya/1.0 (personal job research; +https://github.com/sudharamachandranrajeev/vidya-learning-manager)';

class ResearchException implements Exception {
  const ResearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where the learner's research keys live: this device's keychain only.
/// Never synced, never in the repository or a test fixture.
abstract final class ResearchSecrets {
  static const cqc = 'vidya.research.cqc.key';
  static const companiesHouse = 'vidya.research.companies-house.key';

  /// The saved key named [name], '' when none (that reader is then off).
  static Future<String> read(SecretStore? store, String name) async =>
      store == null ? '' : (await store.read(name) ?? '').trim();

  /// Saves the key; an empty one removes it (the reader off).
  static Future<void> save(SecretStore store, String name, String key) =>
      key.trim().isEmpty ? store.delete(name) : store.write(name, key.trim());
}

/// The polite layer every reader goes through: a cache kept on this device
/// for [cacheFor], at least [gap] between requests to one site, a time
/// limit, and plain words for every failure.
class PoliteGate {
  PoliteGate(
    this.client, {
    required this.cacheRead,
    required this.cacheWrite,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.gap = const Duration(seconds: 1),
    this.cacheFor = const Duration(days: 7),
  }) : _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;
  final http.Client client;
  final Future<String?> Function(String key) cacheRead;
  final Future<void> Function(String key, String value) cacheWrite;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final Duration gap, cacheFor;
  final _last = <String, DateTime>{};

  /// How many requests went out (for tests and the screens).
  int sent = 0;

  static String cacheKey(Uri uri) => 'vidya.research.cache.$uri';

  /// The JSON at [uri], from the cache when it is fresh.
  Future<Object?> getJson(Uri uri, {Map<String, String> headers = const {}}) async {
    final key = cacheKey(uri);
    final cached = await cacheRead(key);
    if (cached != null && cached.isNotEmpty) {
      try {
        final j = jsonDecode(cached);
        final at = j is Map ? DateTime.tryParse('${j['at']}') : null;
        if (at != null && _clock().difference(at) < cacheFor) return j['body'];
      } on FormatException {
        // Read again below.
      }
    }
    final last = _last[uri.host];
    if (last != null) {
      final wait = gap - _clock().difference(last);
      if (wait > Duration.zero) await _sleep(wait);
    }
    _last[uri.host] = _clock();
    sent++;
    http.Response r;
    try {
      r = await client
          .get(uri, headers: {'accept': 'application/json', 'user-agent': researchAgent, ...headers})
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ResearchException('${uri.host} did not answer in time. Try again later.');
    } on http.ClientException {
      throw ResearchException('${uri.host} could not be reached. Check the connection and try again.');
    }
    switch (r.statusCode) {
      case 200:
        break;
      case 401 || 403:
        throw const ResearchException('The key was refused. Check it in Settings, Job research keys.');
      case 404:
        throw const ResearchException('Not found in that register.');
      case 429:
        throw ResearchException('${uri.host} asked Vidya to slow down. Try again in a few minutes.');
      default:
        throw ResearchException('${uri.host} answered with error ${r.statusCode}. Try again later.');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      throw ResearchException('${uri.host} sent a reply that could not be read.');
    }
    await cacheWrite(key, jsonEncode({'at': _clock().toUtc().toIso8601String(), 'body': body}));
    return body;
  }
}

Map<String, Object?> _obj(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
List<Map<String, Object?>> _objs(Object? v) => [
  if (v is List)
    for (final x in v)
      if (x is Map) x.cast<String, Object?>(),
];
String _s(Object? v) => v is String ? v.trim() : (v is num ? '$v' : '');

/// The start date of the first entry of an ODS `Date` list.
String _start(Object? dates) {
  for (final d in _objs(dates)) {
    final s = _s(d['Start']);
    if (isValidIsoDate(s)) return s;
  }
  return '';
}

// ---- NHS ODS ----

/// One organisation in an ODS search.
typedef OdsOrg = ({String name, String code, String status, String postcode, String role});

/// NHS Organisation Data Service: official names, sites and successors.
/// No key. ODS asks for under 5 requests a second; the gate keeps to one.
class OdsReader {
  const OdsReader(this.gate);
  final PoliteGate gate;
  static const host = 'directory.spineservices.nhs.uk';
  static const base = '/ORD/2-0-0/organisations';

  static String recordUrl(String code) => 'https://$host$base/${Uri.encodeComponent(code)}';

  /// Organisations whose name holds [name], active ones first.
  Future<List<OdsOrg>> search(String name) async {
    final q = name.trim();
    if (q.length < 3) throw const ResearchException('Type at least three letters of the name.');
    return parseOdsSearch(await gate.getJson(Uri.https(host, base, {'Name': q, 'Limit': '20'})));
  }

  static List<OdsOrg> parseOdsSearch(Object? body) {
    final out = [
      for (final o in _objs(_obj(body)['Organisations']))
        if (_s(o['OrgId']).isNotEmpty)
          (
            name: _s(o['Name']),
            code: _s(o['OrgId']),
            status: _s(o['Status']),
            postcode: _s(o['PostCode']),
            role: _s(o['PrimaryRoleDescription']),
          ),
    ];
    out.sort((a, b) => (a.status == 'Active' ? 0 : 1).compareTo(b.status == 'Active' ? 0 : 1));
    return out;
  }

  /// The organisation [code]'s record and its active sites.
  Future<ReaderRecord> record(String code) async {
    final org = await gate.getJson(Uri.https(host, '$base/${code.trim()}'));
    final sites = await gate.getJson(
      Uri.https(host, base, {
        'TargetOrgId': code.trim(),
        'RelTypeId': 'RE6',
        'RelStatus': 'active',
        'Limit': '100',
      }),
    );
    return odsRecord(org, sites);
  }

  /// The text and facts of an ODS record ([org], from `organisations/{code}`)
  /// and its sites ([sites], from the relationship search).
  static ReaderRecord odsRecord(Object? org, Object? sites) {
    final o = _obj(_obj(org)['Organisation']);
    final name = _s(o['Name']);
    if (name.isEmpty) throw const ResearchException('That ODS record could not be read.');
    final code = _s(_obj(o['OrgId'])['extension']);
    final status = _s(o['Status']);
    final since = _start(o['Date']);
    final changed = _s(o['LastChangeDate']);
    final loc = _obj(_obj(o['GeoLoc'])['Location']);
    final address = [
      for (final k in ['AddrLn1', 'AddrLn2', 'AddrLn3', 'Town', 'PostCode'])
        if (_s(loc[k]).isNotEmpty) _s(loc[k]),
    ].join(', ');
    final web = [
      for (final c in _objs(_obj(o['Contacts'])['Contact']))
        if (_s(c['type']) == 'http') _s(c['value']).toLowerCase(),
    ].firstOrNull;
    final successors = [
      for (final s in _objs(_obj(o['Succs'])['Succ']))
        if (_s(s['Type']) == 'Successor')
          (code: _s(_obj(_obj(s['Target'])['OrgId'])['extension']), from: _start(s['Date'])),
    ];
    final siteList = [
      for (final s in _objs(_obj(sites)['Organisations']))
        if (_s(s['Name']).isNotEmpty) (name: _s(s['Name']), postcode: _s(s['PostCode'])),
    ];
    final nameLine = 'Official name in the NHS ODS register: $name';
    final statusLine = 'Status in the NHS ODS register: $status';
    final sitesLine = 'Active sites in the register: ${siteList.length}';
    final succLines = [
      for (final s in successors)
        'Successor organisation: ODS code ${s.code}${s.from.isEmpty ? '' : ', from ${s.from}'}',
    ];
    final body = [
      '$nameLine.',
      if (code.isNotEmpty) 'ODS code: $code.',
      '$statusLine.',
      if (since.isNotEmpty) 'Operational since $since.',
      if (address.isNotEmpty) 'Main address: $address.',
      if (web != null) 'Website: $web',
      for (final l in succLines) '$l.',
      '$sitesLine.',
      for (final s in siteList) 'Site: ${s.name}${s.postcode.isEmpty ? '' : ', ${s.postcode}'}.',
      if (changed.isNotEmpty) 'Last changed in the register: $changed.',
    ].join('\n');
    return ReaderRecord(
      kind: 'ods',
      url: OdsReader.recordUrl(code),
      title: 'NHS ODS record: $name',
      sourceDate: isValidIsoDate(changed) ? changed : '',
      body: body,
      facts: [
        FactProposal(
          claim: 'The official name is $name${code.isEmpty ? '' : ' (ODS code $code)'}.',
          quote: nameLine,
        ),
        FactProposal(claim: 'The NHS ODS register lists it as ${status.toLowerCase()}.', quote: statusLine),
        for (final (i, s) in successors.indexed)
          FactProposal(
            claim:
                'It has a successor organisation, ODS code ${s.code}${s.from.isEmpty ? '' : ', from ${s.from}'}.',
            quote: succLines[i],
          ),
        if (siteList.isNotEmpty)
          FactProposal(
            claim:
                'The register lists ${siteList.length} active sites, including '
                '${siteList.take(3).map((s) => s.name).join(', ')}.',
            quote: sitesLine,
          ),
      ],
    );
  }
}

// ---- CQC ----

/// The Care Quality Commission's public API: ratings and report dates.
/// Needs the learner's own subscription key from CQC's API portal.
class CqcReader {
  const CqcReader(this.gate, this.key);
  final PoliteGate gate;
  final String key;
  static const host = 'api.service.cqc.org.uk';

  /// CQC's own page for provider [id] (for NHS trusts, usually the ODS code).
  static String pageUrl(String id) => 'https://www.cqc.org.uk/provider/${Uri.encodeComponent(id.trim())}';

  Future<ReaderRecord> record(String providerId) async {
    final id = providerId.trim();
    if (id.isEmpty) {
      throw const ResearchException('Type the CQC provider ID (for an NHS trust, its ODS code).');
    }
    return cqcRecord(
      await gate.getJson(
        Uri.https(host, '/public/v1/providers/${Uri.encodeComponent(id)}'),
        headers: {'Ocp-Apim-Subscription-Key': key},
      ),
    );
  }

  /// The text and facts of a CQC provider record.
  static ReaderRecord cqcRecord(Object? body) {
    final p = _obj(body);
    final name = _s(p['name']);
    final id = _s(p['providerId']);
    if (name.isEmpty || id.isEmpty) throw const ResearchException('That CQC record could not be read.');
    final status = _s(p['registrationStatus']);
    final overall = _obj(_obj(p['currentRatings'])['overall']);
    final rating = _s(overall['rating']);
    final reportDate = _s(overall['reportDate']).split('T').first;
    final keys = [
      for (final k in _objs(overall['keyQuestionRatings']))
        if (_s(k['name']).isNotEmpty && _s(k['rating']).isNotEmpty)
          (name: _s(k['name']), rating: _s(k['rating']), date: _s(k['reportDate']).split('T').first),
    ];
    final inspected = _s(_obj(p['lastInspection'])['date']).split('T').first;
    final overallLine = rating.isEmpty
        ? ''
        : 'Overall CQC rating: $rating${reportDate.isEmpty ? '' : ', report date $reportDate'}';
    final keyLines = [
      for (final k in keys)
        'CQC rating for ${k.name}: ${k.rating}${k.date.isEmpty ? '' : ', report date ${k.date}'}',
    ];
    final text = [
      'Provider: $name (CQC provider ID $id).',
      if (status.isNotEmpty) 'Registration status: $status.',
      if (overallLine.isNotEmpty) '$overallLine.',
      for (final l in keyLines) '$l.',
      if (inspected.isNotEmpty) 'Last inspection: $inspected.',
    ].join('\n');
    return ReaderRecord(
      kind: 'cqc',
      url: pageUrl(id),
      title: 'CQC: $name',
      sourceDate: isValidIsoDate(reportDate) ? reportDate : '',
      body: text,
      facts: [
        if (overallLine.isNotEmpty)
          FactProposal(
            claim: 'CQC rates it $rating overall${reportDate.isEmpty ? '' : ' (report of $reportDate)'}.',
            quote: overallLine,
            kind: 'cqc',
          ),
        for (final (i, k) in keys.indexed)
          FactProposal(claim: 'CQC rates it ${k.rating} for ${k.name}.', quote: keyLines[i], kind: 'cqc'),
      ],
    );
  }
}

// ---- Companies House ----

typedef CompanyHit = ({String name, String number, String status, String created, String address});

/// Companies House's public data API: a private employer's officers and
/// filings. Needs the learner's own free key (600 requests per five
/// minutes); the gate asks far less.
class CompaniesHouseReader {
  const CompaniesHouseReader(this.gate, this.key);
  final PoliteGate gate;
  final String key;
  static const host = 'api.company-information.service.gov.uk';

  static String pageUrl(String number) =>
      'https://find-and-update.company-information.service.gov.uk/company/${Uri.encodeComponent(number.trim())}';

  /// Companies House's own search page, for when no key is added.
  static String searchUrl(String name) =>
      'https://find-and-update.company-information.service.gov.uk/search/companies?q=${Uri.encodeQueryComponent(name)}';

  Map<String, String> get _auth => {'authorization': 'Basic ${base64Encode(utf8.encode('$key:'))}'};

  Future<List<CompanyHit>> search(String name) async {
    final q = name.trim();
    if (q.length < 3) throw const ResearchException('Type at least three letters of the name.');
    return parseSearch(
      await gate.getJson(
        Uri.https(host, '/search/companies', {'q': q, 'items_per_page': '10'}),
        headers: _auth,
      ),
    );
  }

  static List<CompanyHit> parseSearch(Object? body) => [
    for (final i in _objs(_obj(body)['items']))
      if (_s(i['company_number']).isNotEmpty)
        (
          name: _s(i['title']),
          number: _s(i['company_number']),
          status: _s(i['company_status']),
          created: _s(i['date_of_creation']),
          address: _s(i['address_snippet']),
        ),
  ];

  Future<ReaderRecord> record(String number, {required String today}) async {
    final n = number.trim();
    final profile = await gate.getJson(Uri.https(host, '/company/${Uri.encodeComponent(n)}'), headers: _auth);
    final officers = await gate.getJson(
      Uri.https(host, '/company/${Uri.encodeComponent(n)}/officers', {'items_per_page': '35'}),
      headers: _auth,
    );
    return companyRecord(profile, officers, today: today);
  }

  /// The text and facts of a company's profile and its current officers,
  /// as the register stood on [today].
  static ReaderRecord companyRecord(Object? profile, Object? officers, {required String today}) {
    final p = _obj(profile);
    final name = _s(p['company_name']);
    final number = _s(p['company_number']);
    if (name.isEmpty || number.isEmpty) {
      throw const ResearchException('That company record could not be read.');
    }
    final status = _s(p['company_status']);
    final created = _s(p['date_of_creation']);
    final office = _obj(p['registered_office_address']);
    final address = [
      for (final k in ['address_line_1', 'address_line_2', 'locality', 'postal_code'])
        if (_s(office[k]).isNotEmpty) _s(office[k]),
    ].join(', ');
    final sic = [
      if (p['sic_codes'] is List)
        for (final c in p['sic_codes'] as List) _s(c),
    ].where((c) => c.isNotEmpty).join(', ');
    final accounts = _obj(p['accounts']);
    final madeUpTo = _s(_obj(accounts['last_accounts'])['made_up_to']);
    final nextDue = _s(accounts['next_due']);
    final current = [
      for (final o in _objs(_obj(officers)['items']))
        if (_s(o['name']).isNotEmpty && _s(o['resigned_on']).isEmpty)
          (name: _s(o['name']), role: _s(o['officer_role']), appointed: _s(o['appointed_on'])),
    ].take(20).toList();
    final statusLine = 'Company status on the register: $status';
    final accountsLine = madeUpTo.isEmpty ? '' : 'Latest accounts filed are made up to $madeUpTo';
    final officerLines = [
      for (final o in current)
        'Current officer: ${o.name}, ${o.role.replaceAll('-', ' ')}${o.appointed.isEmpty ? '' : ', appointed ${o.appointed}'}',
    ];
    final text = [
      'Company name: $name.',
      'Company number: $number.',
      '$statusLine.',
      if (created.isNotEmpty) 'Incorporated on $created.',
      if (address.isNotEmpty) 'Registered office: $address.',
      if (sic.isNotEmpty) 'Nature of business (SIC codes): $sic.',
      if (accountsLine.isNotEmpty) '$accountsLine.',
      if (nextDue.isNotEmpty) 'Next accounts due by $nextDue.',
      for (final l in officerLines) '$l.',
      'Read from the Companies House register on $today.',
    ].join('\n');
    return ReaderRecord(
      kind: 'companies-house',
      url: pageUrl(number),
      title: 'Companies House: $name',
      sourceDate: today,
      body: text,
      facts: [
        FactProposal(
          claim: '$name (company $number) is ${status.replaceAll('-', ' ')} on the register.',
          quote: statusLine,
        ),
        if (accountsLine.isNotEmpty)
          FactProposal(claim: 'Its latest filed accounts are made up to $madeUpTo.', quote: accountsLine),
        for (final (i, o) in current.indexed)
          FactProposal(
            claim: '${o.name} is a current ${o.role.replaceAll('-', ' ')}.',
            quote: officerLines[i],
            kind: 'team',
          ),
      ],
    );
  }
}

/// The keyed readers the learner turned on by adding a key: null for each
/// without one, so no request can be made.
Future<({CqcReader? cqc, CompaniesHouseReader? companiesHouse})> keyedReaders(
  SecretStore? store,
  PoliteGate gate,
) async {
  final cqc = await ResearchSecrets.read(store, ResearchSecrets.cqc);
  final ch = await ResearchSecrets.read(store, ResearchSecrets.companiesHouse);
  return (
    cqc: cqc.isEmpty ? null : CqcReader(gate, cqc),
    companiesHouse: ch.isEmpty ? null : CompaniesHouseReader(gate, ch),
  );
}

/// Links for the sources Vidya never reads by itself, with what to do.
/// Review sites and LinkedIn forbid automated access in their terms.
List<({String label, String url, String note})> linkOnlySources(String employer) {
  final e = Uri.encodeQueryComponent(employer);
  return [
    (
      label: 'NHS Staff Survey results',
      url: 'https://www.nhsstaffsurveys.com/results/',
      note: 'Find the organisation, then paste the results you need with the survey year.',
    ),
    (
      label: 'Glassdoor',
      url: 'https://www.glassdoor.co.uk/Search/results.htm?keyword=$e',
      note: 'Anecdotal. Vidya never reads it for you (its terms forbid it); paste what you read.',
    ),
    (
      label: 'Indeed company reviews',
      url: 'https://uk.indeed.com/companies/search?q=$e',
      note: 'Anecdotal. Vidya never reads it for you (its terms forbid it); paste what you read.',
    ),
    (
      label: 'LinkedIn',
      url: 'https://www.linkedin.com/search/results/all/?keywords=$e',
      note: 'Read it yourself and paste what matters. Vidya never opens or reads LinkedIn for you.',
    ),
  ];
}
