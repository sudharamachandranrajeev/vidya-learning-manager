/// The stage packs for checks, joining, the first 90 days and growing in
/// the post (J8): plain data and rules, no database (see
/// stage_packs_book.dart). Every factual line carries its dated source or
/// is labelled general advice (a [JourneyLine] without a source).
library;

import 'package:brahma_core/brahma_core.dart' show addDays, addMonths, isValidIsoDate;

import 'journey.dart';
import 'journey_templates.dart' show templatesChecked;
import 'stage_emails.dart' show packsChecked;

// ---- sources ----

const _references = JourneySource(
  url: 'https://nhsemployers.org/system/files/2024-09/employment-history-and-reference-checks-standard-1843.pdf',
  title: 'NHS Employers: employment history and reference checks standard',
  date: templatesChecked,
);
const _iat = JourneySource(
  url: 'https://www.nhsbsa.nhs.uk/sites/default/files/2023-02/5.%20NHS%20Jobs%20and%20ESR%20integration%20-%20Check%20an%20Inter%20Authority%20Transfer%20%28IAT%29%20consent.pdf',
  title: 'NHSBSA: check an Inter Authority Transfer (IAT) consent',
  date: templatesChecked,
);
const _iatGuide = JourneySource(
  url: 'https://leademployer.merseywestlancs.nhs.uk/media/Documents/Host%20Best%20Practice%20Guide.pdf',
  title: 'Mersey West Lancashire lead employer: host best practice guide',
  date: templatesChecked,
);
const _dbsUpdate = JourneySource(
  url: 'https://www.gov.uk/dbs-update-service',
  title: 'GOV.UK: DBS Update Service',
  date: packsChecked,
);
const _rightToWork = JourneySource(
  url: 'https://www.gov.uk/prove-right-to-work',
  title: 'GOV.UK: prove your right to work to an employer',
  date: packsChecked,
);
const _cstf = JourneySource(
  url: 'https://www.skillsforhealth.org.uk/news/core-skills-training-framework-overview/',
  title: 'Skills for Health: Core Skills Training Framework overview',
  date: packsChecked,
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
const _employmentRights = JourneySource(
  url: 'https://www.nhsemployers.org/articles/more-work-you-may-think',
  title: 'NHS Employers: the Employment Rights Act 2025 and probation',
  date: templatesChecked,
);
const _payPromotion = JourneySource(
  url: 'https://nhsemployers.org/articles/pay-promotion-scenarios-faqs',
  title: 'NHS Employers: pay on promotion FAQs (Agenda for Change Annex 23)',
  date: templatesChecked,
);

// ---- checks (stage "checks") ----

/// One pre-employment check as the pack shows it: from Udyoga's finalise
/// checklist (read-only here; it changes in Udyoga) or Vidya's own list.
class PackCheck {
  const PackCheck({
    required this.kind,
    required this.title,
    this.status = 'todo',
    this.due,
    this.done,
    this.fromUdyoga = false,
  });
  final String kind, title, status;
  final String? due, done;
  final bool fromUdyoga;

  bool get open => status == 'todo' || status == 'sent';

  bool overdueOn(String today) => open && due != null && due!.compareTo(today) < 0;

  /// Due within [days] days of [today] and still open.
  bool dueSoonOn(String today, {int days = 3}) =>
      open && due != null && !overdueOn(today) && due!.compareTo(addDays(today, days)) <= 0;
}

/// Vidya's own checks for [sector], when Udyoga sends none.
List<({String kind, String title})> ownChecks(String sector) => [
  (kind: 'identity', title: 'Identity and right to work: originals or a share code ready'),
  (kind: 'references', title: 'References: referees told and covering the right period'),
  if (sector == 'nhs' || sector == 'university')
    (kind: 'criminal_record', title: 'DBS check (if the post needs one), and the Update Service'),
  if (sector == 'nhs') (kind: 'health', title: 'Occupational health questionnaire and immunisation evidence'),
  if (sector == 'nhs') (kind: 'iat', title: 'IAT consent (moving from one NHS employer to another)'),
];

/// What to know about each kind of check.
List<JourneyLine> checkNotes(String kind, String sector) => switch (kind) {
  'identity' => const [
    JourneyLine(
      'You need to prove your right to work before you start, with your documents or, if you are not a British '
      'or Irish citizen, a share code.',
      source: _rightToWork,
    ),
  ],
  'references' => [
    if (sector == 'nhs')
      const JourneyLine(
        'If you work in the NHS now, references cover the 6 months before the offer letter; otherwise they cover '
        '3 years.',
        source: _references,
      )
    else
      const JourneyLine(
        'Tell your referees to expect a request, and check the period the employer wants covered.',
      ),
  ],
  'criminal_record' => const [
    JourneyLine(
      'Join the DBS Update Service within 30 days of the certificate being issued (it costs £15 a year), so '
      'future employers can check it online with your permission.',
      source: _dbsUpdate,
      staleAfter: '2027-04-01',
    ),
  ],
  'health' => const [
    JourneyLine('Return the health questionnaire promptly and gather your immunisation records early.'),
  ],
  'iat' => const [
    JourneyLine(
      'Say yes to the Inter Authority Transfer (IAT) when you accept the conditional offer.',
      source: _iat,
    ),
    JourneyLine(
      'The IAT moves your mandatory training record, continuous service and leave details, if your old employer '
      'acts on it.',
      source: _iatGuide,
    ),
    JourneyLine('Records may be missing on day one: keep your own training certificates to hand.'),
  ],
  _ => const [],
};

/// The checks the pack shows: Udyoga's list when it sent one, with any of
/// Vidya's own kinds it lacks (the IAT note for NHS posts) added; Vidya's
/// own list otherwise, with the learner's statuses and due dates ([own],
/// by kind: `status`, `due`, `done`).
List<PackCheck> packChecks(Journey journey, Map<String, Object?> own) {
  PackCheck mine(({String kind, String title}) c) {
    final s = own[c.kind];
    final m = s is Map ? s : const {};
    final status = m['status'] is String && checkStatuses.containsKey(m['status'])
        ? m['status'] as String
        : 'todo';
    String? date(Object? v) => v is String && isValidIsoDate(v) ? v : null;
    return PackCheck(
      kind: c.kind,
      title: c.title,
      status: status,
      due: date(m['due']),
      done: date(m['done']),
    );
  }

  final udyoga = journey.checks;
  if (udyoga.isEmpty) return [for (final c in ownChecks(journey.sector)) mine(c)];
  final kinds = {for (final c in udyoga) c.kind};
  return [
    for (final c in udyoga)
      PackCheck(kind: c.kind, title: c.title, status: c.status, due: c.due, done: c.done, fromUdyoga: true),
    for (final c in ownChecks(journey.sector))
      if (!kinds.contains(c.kind) && c.kind == 'iat') mine(c),
  ];
}

/// The open checks past their due date on [today].
List<PackCheck> overdueChecks(List<PackCheck> checks, String today) => [
  for (final c in checks)
    if (c.overdueOn(today)) c,
];

// ---- joining (stage "joining") ----

/// A starter day-one list. General advice: the learner edits it.
const dayOneStarter = [
  'Photo ID and bank details for payroll',
  'Where to go, who to ask for and what time',
  'Log-ins: email, rota or timesheet, records systems',
  'Ask for an induction plan and who my buddy is',
  'Note names and roles as I meet people',
];

/// The joining stage's lines: what training to expect.
List<JourneyLine> trainingNotes(String sector) => [
  if (sector == 'nhs')
    const JourneyLine(
      'NHS employers in England use the Core Skills Training Framework: 11 core subjects such as fire safety, '
      'infection prevention and control, information governance and safeguarding. Your employer\'s list wins.',
      source: _cstf,
    )
  else
    const JourneyLine('Ask for the list of mandatory training and the date each course is due.'),
];

/// A starter mandatory-training list for [sector]. General advice: the
/// learner keeps the employer's own list.
List<String> trainingStarter(String sector) => sector == 'nhs'
    ? const [
        'Fire safety',
        'Infection prevention and control',
        'Information governance and data security',
        'Safeguarding adults',
        'Safeguarding children',
        'Health, safety and welfare',
        'Equality, diversity and human rights',
        'Moving and handling',
        'Conflict resolution',
        'Preventing radicalisation',
        'Resuscitation',
      ]
    : const ['Induction', 'Health and safety', 'Data protection', 'Equality and diversity'];

/// One training course and its dates.
typedef TrainingRow = ({String name, String due, String done});

List<TrainingRow> trainingRows(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map && r['name'] is String && (r['name'] as String).trim().isNotEmpty)
        (
          name: (r['name'] as String).trim(),
          due: r['due'] is String && isValidIsoDate(r['due'] as String) ? r['due'] as String : '',
          done: r['done'] is String && isValidIsoDate(r['done'] as String) ? r['done'] as String : '',
        ),
];

/// A person or an acronym for the flashcards: [front] is the name or term,
/// [back] the role or meaning.
typedef PackCard = ({String front, String back});

List<PackCard> packCards(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map && r['front'] is String && r['back'] is String)
        if (((r['front'] as String).trim(), (r['back'] as String).trim()) case (final f, final b)
            when f.isNotEmpty && b.isNotEmpty)
          (front: f, back: b),
];

/// The flashcard decks a journey's people and acronyms go in.
String peopleDeck(Journey j) => 'Who\'s who: ${_place(j)}';
String acronymDeck(Journey j) => 'Acronyms and systems: ${_place(j)}';

String _place(Journey j) => j.employer.isNotEmpty ? j.employer : (j.role.isNotEmpty ? j.role : 'new job');

// ---- first 90 days (stage "first-90-days") ----

/// The 30/60/90 plan's three parts and what each asks.
const plan90Parts = {
  'd30': 'Days 1 to 30: learn. People, systems, how work gets done; one small thing done well.',
  'd60': 'Days 31 to 60: contribute. Take on my own work; agree objectives with my manager.',
  'd90': 'Days 61 to 90: improve. One improvement that matters to my manager; evidence for my review.',
};

/// The probation lines for [sector], each sourced.
List<JourneyLine> probationNotes(String sector) => [
  switch (sector) {
    'nhs' => const JourneyLine(
      'NHS trusts usually set a probation period of about 6 months, and appraisal often starts after it.',
      source: _nhsProbation,
    ),
    'university' => const JourneyLine(
      'Probation for university support staff is often 6 months and can be extended: one published procedure '
      'allows up to 9.',
      source: _universityProbation,
    ),
    _ => const JourneyLine(
      'Probation in private companies is commonly 3 to 6 months; your contract says which.',
    ),
  },
  const JourneyLine(
    'The Employment Rights Act 2025 pushes employers towards measurable objectives and structured probation '
    'reviews.',
    source: _employmentRights,
  ),
];

/// The usual probation length in months, NHS and university (see
/// [probationNotes]); a private contract may say 3.
const usualProbationMonths = 6;

/// The review points of a probation of [months] months from [start]: a
/// first review after a month, one at the middle, and the final review a
/// fortnight before the end. General advice: the employer's policy sets
/// the real dates.
List<({String day, String label})> probationReviews(String start, int months) {
  if (!isValidIsoDate(start) || months < 1) return const [];
  final end = addMonths(start, months);
  return [
    (day: addMonths(start, 1), label: 'First review: settling in, objectives agreed'),
    if (months >= 4)
      (day: addMonths(start, months ~/ 2), label: 'Mid-point review: progress against objectives'),
    (day: addDays(end, -14), label: 'Final review: evidence for each objective'),
    (day: end, label: 'Probation ends'),
  ];
}

/// What the probation review prep asks.
const probationPrompts = [
  'Each objective: what I did and the evidence (from my wins log)',
  'Feedback I have had, and what I changed because of it',
  'Training done, and what is still due',
  'What I need from my manager for the next stage',
];

/// The monthly check-in's questions.
const checkInPrompts = ['What went well this month?', 'What do I need to fix?', 'What did my manager say?'];

/// The next monthly check-in after [last] (or from [start] when there is
/// none yet); null with neither.
String? nextCheckIn({String last = '', String start = ''}) {
  if (isValidIsoDate(last)) return addMonths(last, 1);
  if (isValidIsoDate(start)) return addMonths(start, 1);
  return null;
}

/// One entry of the weekly wins log.
typedef Win = ({String id, String day, String text, String story});

List<Win> wins(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map && r['text'] is String && (r['text'] as String).trim().isNotEmpty)
        (
          id: r['id'] is String ? r['id'] as String : '',
          day: r['day'] is String ? r['day'] as String : '',
          text: (r['text'] as String).trim(),
          story: r['story'] is String ? r['story'] as String : '',
        ),
];

// ---- grow (stage "grow") ----

/// What the appraisal (PDR) prep asks.
const pdrPrompts = {
  'met': 'Objectives met this year, each with its evidence',
  'learning': 'Learning and training done',
  'next': 'Objectives I propose for next year',
  'support': 'Support or development I am asking for',
};

const growNotes = [
  JourneyLine(
    'Moving up the pay points in a band depends on appraisal and local policy (Agenda for Change Annex 23).',
    source: _payPromotion,
  ),
  JourneyLine('Map your evidence to the next role\'s person specification, criterion by criterion.'),
];

/// The criteria pasted from the next role's specification: one a line,
/// bullets and numbering removed; a line starting "Desirable" or ending
/// "(D)" is desirable, the rest essential.
List<({String text, bool essential})> parseNextCriteria(String text) => [
  for (final raw in text.split('\n'))
    if (raw.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)])\s*'), '').trim() case final line when line.length > 2)
      (
        text: line
            .replaceFirst(RegExp(r'^(desirable|essential)\s*[:\-]\s*', caseSensitive: false), '')
            .replaceFirst(RegExp(r'\s*\((d|e)\)$', caseSensitive: false), ''),
        essential: !RegExp(r'^desirable\b|\(d\)$', caseSensitive: false).hasMatch(line),
      ),
];
