/// The offer checker (J8, stage "offer"): the learner types in the offer's
/// facts and the checker sets them against dated rule cards: Agenda for
/// Change for NHS posts (2026/27), and a university's grade table when the
/// employer is a university. It says what is normal, what to ask and what
/// to watch, each line with its rule card's source and checked date, and
/// flags the cards once they may be out of date. Not legal advice.
library;

import 'package:brahma_core/brahma_core.dart' show addDays, isValidIsoDate;

import 'journey.dart';
import 'journey_templates.dart' show templatesChecked;
import 'stage_emails.dart' show acasNoticeSource, packsChecked, startingSalarySource;

/// Shown with every result.
const notLegalAdvice =
    'Not legal or financial advice: a check of the facts you typed against dated public rules. Your contract and '
    'your employer\'s own policy decide.';

/// A dated rule the checker uses.
class RuleCard {
  const RuleCard({
    required this.id,
    required this.title,
    required this.text,
    required this.source,
    this.staleAfter = '',
  });
  final String id, title, text;
  final JourneySource source;

  /// yyyy-MM-dd from which the card may be out of date, '' when it does
  /// not date.
  final String staleAfter;

  bool staleOn(String today) => staleAfter.isNotEmpty && today.compareTo(staleAfter) >= 0;

  JourneyLine get line => JourneyLine(text, source: source, staleAfter: staleAfter);
}

/// The day the 2026/27 Agenda for Change cards may go out of date.
const afcStale = '2027-04-01';

const _payPromotion = JourneySource(
  url: 'https://nhsemployers.org/articles/pay-promotion-scenarios-faqs',
  title: 'NHS Employers: pay on promotion FAQs (Agenda for Change Annex 23)',
  date: templatesChecked,
);
const _payScales = JourneySource(
  url: 'https://www.nhsemployers.org/articles/pay-scales-202627',
  title: 'NHS Employers: pay scales 2026/27',
  date: templatesChecked,
);
const _nhsProbation = JourneySource(
  url: 'https://www.tewv.nhs.uk/about/publications/probationary-period/',
  title: 'An NHS trust probationary period policy',
  date: templatesChecked,
);
const _universityProbation = JourneySource(
  url: 'https://hr.leeds.ac.uk/download/downloads/id/155/probationary-procedures',
  title: 'A university\'s probation procedure for support staff',
  date: templatesChecked,
);
const _leedsScale = JourneySource(
  url: 'https://hr.leeds.ac.uk/download/downloads/id/1086/salary-scale-grades-2---9.pdf',
  title: 'University of Leeds: single pay spine, August 2025',
  date: packsChecked,
);

/// Agenda for Change rule cards, England, 2026/27.
const afcRuleCards = [
  RuleCard(
    id: 'afc-promotion',
    title: 'Promotion starts at the bottom of the new band',
    text:
        'Moving up a band normally starts you on the bottom pay point of the new band (Agenda for Change Annex 23, '
        'paragraph 11).',
    source: _payPromotion,
    staleAfter: afcStale,
  ),
  RuleCard(
    id: 'afc-experience',
    title: 'Experience credit is discretionary',
    text:
        'Starting above the bottom pay point for experience is at the employer\'s discretion, is often counted in '
        'completed years only, and must be agreed in writing before you accept the offer.',
    source: startingSalarySource,
    staleAfter: afcStale,
  ),
  RuleCard(
    id: 'afc-pay-2026',
    title: 'Pay ranges 2026/27 (England)',
    text:
        'Agenda for Change pay in England for 2026/27: Band 3 £25,760 to £27,476; Band 4 £28,392 to £31,157; '
        'Band 5 £32,073 to £39,043.',
    source: _payScales,
    staleAfter: afcStale,
  ),
  RuleCard(
    id: 'afc-progression',
    title: 'Moving up the pay points',
    text: 'Moving up the pay points within a band depends on appraisal and local policy (Annex 23).',
    source: _payPromotion,
    staleAfter: afcStale,
  ),
];

/// A band's pay range for one year.
typedef PayRange = ({String grade, int min, int max, int? firstPoint, int? lastPoint});

/// Agenda for Change ranges, England, 2026/27 (from [afcRuleCards]).
const afcRanges = <String, PayRange>{
  '3': (grade: 'Band 3', min: 25760, max: 27476, firstPoint: null, lastPoint: null),
  '4': (grade: 'Band 4', min: 28392, max: 31157, firstPoint: null, lastPoint: null),
  '5': (grade: 'Band 5', min: 32073, max: 39043, firstPoint: null, lastPoint: null),
};

/// A university's published grade table.
class GradeTable {
  const GradeTable({required this.employer, required this.match, required this.card, required this.grades});

  /// The university's name, as shown.
  final String employer;

  /// Lower-case words that must all appear in the employer's name.
  final List<String> match;
  final RuleCard card;
  final Map<String, PayRange> grades;

  bool matches(String employer) {
    final e = employer.toLowerCase();
    return match.every(e.contains);
  }
}

/// The grade tables Vidya ships. A university not listed here: the learner
/// types its grade's range from the university's own pay page.
const gradeTables = [
  GradeTable(
    employer: 'University of Leeds',
    match: ['leeds', 'university'],
    card: RuleCard(
      id: 'leeds-grades-2025',
      title: 'University of Leeds grades (August 2025 pay spine)',
      text:
          'University of Leeds, from August 2025: Grade 5 is spine points 20 to 24, £29,588 to £33,002; Grade 6 is '
          'points 25 to 31, £33,951 to £39,906. Check for a newer pay award each August.',
      source: _leedsScale,
      staleAfter: '2026-08-01',
    ),
    grades: {
      '5': (grade: 'Grade 5', min: 29588, max: 33002, firstPoint: 20, lastPoint: 24),
      '6': (grade: 'Grade 6', min: 33951, max: 39906, firstPoint: 25, lastPoint: 31),
    },
  ),
];

GradeTable? gradeTableFor(String employer) => gradeTables.where((t) => t.matches(employer)).firstOrNull;

/// What the learner typed in about the offer. Every field may be empty.
class OfferFacts {
  const OfferFacts({
    this.band = '',
    this.point,
    this.salary,
    this.hours,
    this.fixedTerm = false,
    this.fixedTermEnd = '',
    this.probationMonths,
    this.startDate = '',
    this.noticeWeeks,
    this.promotion = false,
    this.relevantYears,
    this.rangeMin,
    this.rangeMax,
  });

  /// The band or grade, as a number or name ("5", "Band 5", "Grade 6").
  final String band;

  /// The pay point or step offered (1 = the bottom).
  final int? point;

  /// Full-time salary in pounds a year.
  final int? salary;

  /// Hours a week.
  final double? hours;
  final bool fixedTerm;
  final String fixedTermEnd;
  final int? probationMonths;

  /// yyyy-MM-dd.
  final String startDate;

  /// Notice owed to the current employer, in weeks.
  final int? noticeWeeks;

  /// Whether the post is a move up a band from the learner's current one
  /// with the same kind of employer.
  final bool promotion;

  /// Completed years of relevant experience.
  final int? relevantYears;

  /// The grade's range from the employer's own pay page, when Vidya has no
  /// table for it.
  final int? rangeMin, rangeMax;

  /// The band's number ("Band 5" → "5"), '' when none.
  String get bandKey => RegExp(r'\d+').firstMatch(band)?.group(0) ?? '';

  factory OfferFacts.fromJson(Map<String, Object?> j) {
    int? i(Object? v) => v is num ? v.round() : int.tryParse('${v ?? ''}'.replaceAll(RegExp(r'[£,\s]'), ''));
    double? d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    String s(Object? v) => v is String ? v.trim() : '';
    return OfferFacts(
      band: s(j['band']),
      point: i(j['point']),
      salary: i(j['salary']),
      hours: d(j['hours']),
      fixedTerm: j['fixedTerm'] == true,
      fixedTermEnd: isValidIsoDate(s(j['fixedTermEnd'])) ? s(j['fixedTermEnd']) : '',
      probationMonths: i(j['probationMonths']),
      startDate: isValidIsoDate(s(j['startDate'])) ? s(j['startDate']) : '',
      noticeWeeks: i(j['noticeWeeks']),
      promotion: j['promotion'] == true,
      relevantYears: i(j['relevantYears']),
      rangeMin: i(j['rangeMin']),
      rangeMax: i(j['rangeMax']),
    );
  }

  Map<String, Object> toJson() => {
    if (band.isNotEmpty) 'band': band,
    'point': ?point,
    'salary': ?salary,
    'hours': ?hours,
    if (fixedTerm) 'fixedTerm': true,
    if (fixedTermEnd.isNotEmpty) 'fixedTermEnd': fixedTermEnd,
    'probationMonths': ?probationMonths,
    if (startDate.isNotEmpty) 'startDate': startDate,
    'noticeWeeks': ?noticeWeeks,
    if (promotion) 'promotion': true,
    'relevantYears': ?relevantYears,
    'rangeMin': ?rangeMin,
    'rangeMax': ?rangeMax,
  };

  bool get isEmpty => toJson().isEmpty;
}

enum FindingKind {
  /// What the offer shows is the usual rule.
  normal('Normal'),

  /// Worth asking about, in writing, before accepting.
  ask('Ask'),

  /// Looks wrong or clashes with another fact.
  watch('Check this'),

  /// The rule card may be out of date.
  stale('May be out of date');

  const FindingKind(this.label);
  final String label;
}

/// One thing the checker found: a line, its kind and the rule behind it
/// (a sourced line, or general advice when [line] has no source).
typedef OfferFinding = ({FindingKind kind, JourneyLine line});

String pounds(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '£$b';
}

/// Sets [f] against the rule cards for [sector] (and, for a university,
/// [employer]'s grade table) on [today].
List<OfferFinding> checkOffer(
  OfferFacts f, {
  required String sector,
  String employer = '',
  required String today,
}) {
  final out = <OfferFinding>[];
  void add(FindingKind k, String text, {JourneySource? source, String staleAfter = ''}) =>
      out.add((kind: k, line: JourneyLine(text, source: source, staleAfter: staleAfter)));
  final band = f.bandKey;

  if (sector == 'nhs') {
    if (today.compareTo(afcStale) >= 0) {
      add(
        FindingKind.stale,
        'These Agenda for Change rule cards are for 2026/27 and may be out of date from 1 April 2027. Check the '
        'current year\'s pay scales and policy before relying on them.',
        source: _payScales,
        staleAfter: afcStale,
      );
    }
    final range = afcRanges[band];
    if (band.isNotEmpty && range == null) {
      add(
        FindingKind.ask,
        'Vidya has no dated figures for Band $band. Check the range on the NHS Employers pay scales page.',
        source: _payScales,
      );
    }
    if (f.promotion) {
      final atBottom =
          (f.point == null || f.point == 1) && (range == null || f.salary == null || f.salary == range.min);
      add(
        FindingKind.normal,
        atBottom
            ? 'Moving up a band normally starts on the bottom pay point of the new band, as this offer does.'
            : 'Moving up a band normally starts on the bottom pay point of the new band. This offer is above it: get '
                  'that in writing before you accept.',
        source: _payPromotion,
        staleAfter: afcStale,
      );
    } else if (range != null && (f.point == 1 || f.salary == range.min)) {
      add(
        FindingKind.ask,
        'This offer is the bottom of ${range.grade}. Starting higher for experience is discretionary and often '
        'counts completed years only${f.relevantYears != null && f.relevantYears! > 0 ? ' (you entered ${f.relevantYears})' : ''}. '
        'Ask once, in writing, before you accept, with an evidence table.',
        source: startingSalarySource,
        staleAfter: afcStale,
      );
    }
    if (range != null && f.salary != null && (f.salary! < range.min || f.salary! > range.max)) {
      add(
        FindingKind.watch,
        '${pounds(f.salary!)} is outside ${range.grade}\'s 2026/27 range (${pounds(range.min)} to '
        '${pounds(range.max)}). Check the band, whether the figure is full-time, and the pay year.',
        source: _payScales,
        staleAfter: afcStale,
      );
    }
    if (f.probationMonths != null && f.probationMonths! > 6) {
      add(
        FindingKind.ask,
        'NHS trusts usually set probation at about 6 months; ${f.probationMonths} months is longer. Ask why, and '
        'how reviews will work.',
        source: _nhsProbation,
      );
    }
  } else if (sector == 'university') {
    final table = gradeTableFor(employer);
    final range =
        table?.grades[band] ??
        (f.rangeMin != null && f.rangeMax != null
            ? (
                grade: band.isEmpty ? 'this grade' : 'Grade $band',
                min: f.rangeMin!,
                max: f.rangeMax!,
                firstPoint: null,
                lastPoint: null,
              )
            : null);
    if (table != null && table.card.staleOn(today)) {
      add(FindingKind.stale, table.card.text, source: table.card.source, staleAfter: table.card.staleAfter);
    }
    if (range == null) {
      add(
        FindingKind.ask,
        'Vidya has no grade table for this university. Type the grade\'s lowest and highest salary from the '
        'university\'s own pay page to check the offer against it.',
      );
    } else {
      final src = table?.grades[band] != null ? table!.card.source : null;
      final stale = table?.grades[band] != null ? table!.card.staleAfter : '';
      if (f.salary != null && (f.salary! < range.min || f.salary! > range.max)) {
        add(
          FindingKind.watch,
          '${pounds(f.salary!)} is outside ${range.grade}\'s range (${pounds(range.min)} to ${pounds(range.max)}). '
          'Check the grade, whether the figure is full-time, and the pay year.',
          source: src,
          staleAfter: stale,
        );
      } else if (f.salary != null && f.salary == range.min) {
        add(
          FindingKind.ask,
          'This offer is the bottom of ${range.grade}. Your starting point follows the university\'s own policy: '
          'ask, in writing and before you accept, whether your experience can start you higher.',
          source: src,
          staleAfter: stale,
        );
      } else if (f.salary != null) {
        add(
          FindingKind.normal,
          '${pounds(f.salary!)} is within ${range.grade}\'s range (${pounds(range.min)} to ${pounds(range.max)}).',
          source: src,
          staleAfter: stale,
        );
      }
    }
    if (f.probationMonths != null && f.probationMonths! > 6) {
      add(
        FindingKind.ask,
        'University support staff probation is often 6 months, extendable (one procedure allows up to 9). '
        '${f.probationMonths} months from the start is longer: ask why.',
        source: _universityProbation,
      );
    }
  } else {
    if (f.salary != null) {
      add(
        FindingKind.ask,
        'Private employers often have more room on pay than the public sector. If you ask, ask once, with reasons, '
        'before you accept.',
      );
    }
    if (f.probationMonths != null && f.probationMonths! > 6) {
      add(
        FindingKind.ask,
        'Probation of ${f.probationMonths} months is long: ask why, and how reviews will work.',
      );
    }
  }

  // Facts that matter whoever the employer is.
  if (f.hours != null && f.hours! < 37.5 && f.hours! > 0) {
    add(
      FindingKind.normal,
      'At ${_hours(f.hours!)} hours a week, pay is usually pro rata to a full-time figure: check which one the offer '
      'states.',
    );
  }
  if (f.fixedTerm) {
    add(
      FindingKind.ask,
      'A fixed-term post${f.fixedTermEnd.isNotEmpty ? ' ending ${f.fixedTermEnd}' : ''}: ask how the funding is going, '
      'whether it may be extended or made permanent, and get the end date in writing.',
    );
  }
  if (f.startDate.isNotEmpty && f.noticeWeeks != null) {
    final free = addDays(today, f.noticeWeeks! * 7);
    if (f.startDate.compareTo(free) < 0) {
      add(
        FindingKind.watch,
        'The start date ${f.startDate} is before your ${f.noticeWeeks}-week notice would end if you resigned today '
        '($free). Agree the start date, or an earlier release, in writing.',
        source: acasNoticeSource,
      );
    }
  }
  if (out.isEmpty) {
    add(FindingKind.normal, 'Nothing to flag from the facts entered. Fill in more to check more.');
  }
  return out;
}

String _hours(double h) => h == h.roundToDouble() ? h.toInt().toString() : h.toString();

/// The written-evidence table for asking for a higher starting point: one
/// row per earlier role, ready to paste into the "starting pay point"
/// email ([rows] are the learner's own; one blank row when none).
String evidenceTable(List<Map<String, String>> rows) {
  const head = [
    'Role',
    'Employer',
    'From',
    'To',
    'Completed years',
    'How it matches the new post',
    'Evidence',
  ];
  final lines = [
    '| ${head.join(' | ')} |',
    '|${List.filled(head.length, '---').join('|')}|',
    for (final r in rows.isEmpty ? [<String, String>{}] : rows)
      '| ${[for (final k in evidenceColumns) (r[k] ?? '').replaceAll('|', '/').trim().isEmpty ? '[ ]' : r[k]!.replaceAll('|', '/').trim()].join(' | ')} |',
  ];
  return lines.join('\n');
}

/// The keys of an [evidenceTable] row, in column order.
const evidenceColumns = ['role', 'employer', 'from', 'to', 'years', 'match', 'evidence'];
