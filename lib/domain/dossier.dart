/// The job dossier (journey plan J5): employer facts as cards. Each card
/// has a claim, the exact sentence that supports it, where that sentence
/// is from, the source's own date, when it was read, and a status:
///
/// - verified: the quote was found, word for word, in the source text
///   Vidya keeps (normalised: case, punctuation and spacing ignored);
/// - user-confirmed: the learner checked it themselves;
/// - inference: not checked. Always labelled so, never shown as fact.
///
/// A proposed fact whose quote is not in its source is dropped (from an
/// AI) or kept as inference (when the learner says so). Cards are flagged
/// as maybe out of date by their source's cycle ([staleAfterFor]). The
/// "why here" points and the questions to ask are built only from
/// verified and user-confirmed cards, by plain rules, never by an AI.
/// Nothing here touches the database or the network; see dossier_book.dart
/// and dossier_readers.dart.
library;

import 'package:brahma_core/brahma_core.dart';

/// Kinds of fact, in the order the dossier groups them.
const factKinds = {
  'strategy': 'Strategy and plans',
  'cqc': 'CQC inspection',
  'staff-survey': 'Staff survey',
  'board': 'Board papers',
  'pay': 'Pay',
  'team': 'The team',
  'systems': 'Systems',
  'values': 'Values',
  'reviews-anecdotal': 'Reviews (anecdotal)',
  'other': 'Other',
};

/// Card statuses and how the dossier labels them.
const factStatuses = {'verified': 'Verified', 'user-confirmed': 'You checked it', 'inference': 'Inference'};

/// Kinds of source: what the learner pastes, what Udyoga sends and what
/// the official readers fetch.
const sourceKinds = {
  'advert': 'Job advert',
  'board': 'Board papers',
  'annual-report': 'Annual report',
  'strategy': 'Strategy',
  'staff-survey': 'NHS Staff Survey',
  'reviews': 'Glassdoor or Indeed (anecdotal)',
  'linkedin': 'LinkedIn (read by you)',
  'web': 'Other web page',
  'ods': 'NHS ODS',
  'cqc': 'CQC',
  'companies-house': 'Companies House',
};

/// The kinds the learner can paste (the rest come from readers).
const pasteKinds = [
  'advert',
  'board',
  'annual-report',
  'strategy',
  'staff-survey',
  'reviews',
  'linkedin',
  'web',
];

/// The fact kind a source's facts take unless the learner picks another.
/// Every fact from reviews is anecdotal, whatever is picked.
String defaultFactKind(String sourceKind) => switch (sourceKind) {
  'board' => 'board',
  'annual-report' || 'strategy' => 'strategy',
  'staff-survey' => 'staff-survey',
  'reviews' => 'reviews-anecdotal',
  'linkedin' => 'team',
  'cqc' => 'cqc',
  _ => 'other',
};

/// The most text a source keeps, and the most sent to an AI at once.
const maxSourceText = 60000, maxAiText = 30000;

/// The fewest words a quote may have, so "the trust" cannot pass as
/// evidence.
const minQuoteWords = 4;

// ---- the quote check ----

/// [s] lower-cased with curly quotes, dashes and every other mark turned
/// into spaces, and runs of space made one: what the quote check compares.
/// A decimal point stays part of its number ("4.9" is one word, not two)
/// and a thousands comma goes ("1,200" reads as "1200").
String normaliseForQuote(String s) => s
    .toLowerCase()
    .replaceAllMapped(RegExp(r'(\d),(\d{3})'), (m) => '${m[1]}${m[2]}')
    .replaceAllMapped(RegExp(r'(\d)\.(\d)'), (m) => '${m[1]}d${m[2]}')
    .replaceAll(RegExp('[’‘`´]'), "'")
    .replaceAll(RegExp(r"[^a-z0-9%£$€']+"), ' ')
    .replaceAll("'", '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// True when [quote] is in [text]: the same words in the same order,
/// ignoring case, punctuation and spacing. No skipping with an ellipsis:
/// the supporting sentence must be there as it is. A quote needs
/// [minQuoteWords] words or more.
bool quoteInSource(String quote, String text) {
  if (quote.contains('...') || quote.contains('…')) return false;
  final q = normaliseForQuote(quote);
  if (q.isEmpty || q.split(' ').length < minQuoteWords) return false;
  return ' ${normaliseForQuote(text)} '.contains(' $q ');
}

/// Why a quote fails the check, in plain words, or null when it passes.
String? quoteProblem(String quote, String text) {
  if (quote.trim().isEmpty) return 'There is no supporting sentence.';
  if (quote.contains('...') || quote.contains('…')) {
    return 'The sentence skips words ("…"). Copy it whole from the source.';
  }
  if (normaliseForQuote(quote).split(' ').length < minQuoteWords) {
    return 'The sentence is too short: copy at least $minQuoteWords words.';
  }
  return quoteInSource(quote, text) ? null : 'That sentence is not in the source text, word for word.';
}

/// The sentences of [text]: split at full stops, question and exclamation
/// marks and line breaks; very short pieces dropped.
List<String> sentencesOf(String text) => [
  for (final line in text.split(RegExp(r'[\r\n]+')))
    for (final s in line.split(RegExp(r'(?<=[.!?])\s+')))
      if (s.trim() case final t when normaliseForQuote(t).split(' ').length >= minQuoteWords) t,
];

// ---- freshness ----

/// yyyy-MM-dd from which a card of [kind] may be out of date, counted from
/// the source's own date (from when it was read when that is not known):
///
/// - staff survey: a year (results come out once a year);
/// - CQC: two years from the report date (look for a newer report);
/// - board papers: three months from the meeting (boards meet every one
///   to three months);
/// - pay: the next 1 April (pay follows the financial year);
/// - the team: six months; values: two years; anything else: a year.
String staleAfterFor(String kind, {String sourceDate = '', String fetchedAt = ''}) {
  final base = isValidIsoDate(sourceDate)
      ? sourceDate
      : (fetchedAt.length >= 10 && isValidIsoDate(fetchedAt.substring(0, 10))
            ? fetchedAt.substring(0, 10)
            : '');
  if (base.isEmpty) return '';
  final d = DateTime.parse(base);
  DateTime months(int n) => DateTime(d.year, d.month + n, d.day);
  final out = switch (kind) {
    'cqc' || 'values' => months(24),
    'board' => months(3),
    'team' => months(6),
    'pay' => DateTime(d.month >= 4 ? d.year + 1 : d.year, 4, 1),
    _ => months(12),
  };
  return isoDate(out);
}

/// True for a register read live (NHS ODS, Companies House): its own date
/// is when the record last changed, so its cards age from when it was
/// read, not from that date.
bool isRegister(String sourceKind) => sourceKind == 'ods' || sourceKind == 'companies-house';

/// Whether a card with [staleAfter] should be checked again on [today].
bool isStale(String staleAfter, String today) => staleAfter.isNotEmpty && today.compareTo(staleAfter) >= 0;

/// What the stale flag says for a card of [kind].
String staleNote(String kind) => switch (kind) {
  'staff-survey' => 'May be out of date: a newer staff survey may be out',
  'cqc' => 'May be out of date: look for a newer CQC report',
  'board' => 'May be out of date: newer board papers may be out',
  'pay' => 'May be out of date: a new financial year has started',
  _ => 'May be out of date: check the source again',
};

// ---- proposals ----

/// A fact proposed by the learner, an AI, Udyoga or a reader, before the
/// quote check.
class FactProposal {
  const FactProposal({required this.claim, this.quote = '', this.kind = 'other'});
  final String claim, quote;

  /// One of [factKinds].
  final String kind;
}

/// The facts in an AI's reply object (`{"facts": [{"claim", "quote",
/// "kind"}]}`). Drops what it cannot read; at most 40.
List<FactProposal> parseFactProposals(Map<String, Object?> j, {String defaultKind = 'other'}) {
  final facts = j['facts'];
  if (facts is! List) {
    throw const FormatException(
      'The AI did not reply in the form asked for, so nothing was added. Try again.',
    );
  }
  return [
    for (final f in facts.take(40))
      if (f is Map && f['claim'] is String && (f['claim'] as String).trim().isNotEmpty)
        FactProposal(
          claim: _clip((f['claim'] as String).trim(), 500),
          quote: f['quote'] is String ? _clip((f['quote'] as String).trim(), 1000) : '',
          kind: factKinds.containsKey(f['kind']) ? f['kind'] as String : defaultKind,
        ),
  ];
}

/// [proposals] split by the quote check against [text]: those whose quote
/// is in it, and those whose quote is not.
({List<FactProposal> verified, List<FactProposal> unmatched}) checkProposals(
  List<FactProposal> proposals,
  String text,
) {
  final verified = <FactProposal>[], unmatched = <FactProposal>[];
  for (final p in proposals) {
    (quoteInSource(p.quote, text) ? verified : unmatched).add(p);
  }
  return (verified: verified, unmatched: unmatched);
}

/// The instructions for an AI asked to propose facts from one source.
String factPromptSystem(String sourceKind) =>
    'You read one source about an employer and list the facts in it that would help a job applicant: '
    'plans and strategy, inspection ratings, staff survey results, board decisions, pay, the team, systems '
    'and values. For each fact give "claim" (the fact in one plain sentence), "quote" (ONE whole sentence '
    'copied character for character from the source, which states the fact; never shorten it or join two '
    'sentences) and "kind" (one of: ${factKinds.keys.join(', ')}). Use only what the source says: never add '
    'anything from elsewhere, never guess. '
    '${sourceKind == 'reviews' ? 'These are staff reviews: every fact is anecdotal, kind "reviews-anecdotal". ' : ''}'
    'If the source has no such facts, give an empty list.\n\n'
    'Reply with one JSON object only, with no other text before or after it, like this: '
    '{"facts": [{"claim": "…", "quote": "…", "kind": "strategy"}]}';

// ---- kinds from words ----

/// A fact kind guessed from a claim's words (for facts Udyoga sends,
/// which carry none). The learner can change it.
String guessFactKind(String claim) {
  final c = ' ${normaliseForQuote(claim)} ';
  bool has(String words) => RegExp(' ($words) ').hasMatch(c);
  if (has('staff survey|nhs staff survey')) return 'staff-survey';
  if (has('cqc|care quality commission|inspection|inspected|rated|rating')) return 'cqc';
  if (has('board|board papers|board meeting')) return 'board';
  if (has('pay|salary|band|agenda for change|pay award')) return 'pay';
  if (has('epr|electronic patient record|system|systems|software|digital')) return 'systems';
  if (has('strategy|plan|plans|programme|annual report|merger|transformation')) return 'strategy';
  if (has('values|value|culture')) return 'values';
  if (has('glassdoor|indeed|reviews|review')) return 'reviews-anecdotal';
  if (has('team|manager|department|service')) return 'team';
  return 'other';
}

// ---- matching a claim to a sentence ----

const _stop = {
  'the', 'and', 'for', 'with', 'from', 'that', 'this', 'its', 'our', 'are', 'was', 'were', 'has', 'have', //
  'will', 'into', 'their', 'they', 'which', 'also', 'been', 'per', 'cent', 'more', 'than', 'over', 'trust',
};

List<String> _keyWords(String s) => [
  for (final w in normaliseForQuote(s).split(' '))
    if (w.length >= 3 && !_stop.contains(w)) w,
];

List<String> _numbers(String s) => [
  for (final m in RegExp(r'\d+(?:[.,]\d+)?').allMatches(s)) m[0]!.replaceAll(',', ''),
];

/// The sentence of [text] that supports [claim] by plain rules, or null:
/// it must hold every number in the claim and at least 60% of its key
/// words (and three or more of them). Used to check facts Udyoga proposes,
/// which carry a claim and a link but no quote.
String? supportingSentence(String claim, String text) {
  final words = _keyWords(claim).toSet();
  final numbers = _numbers(claim).toSet();
  if (words.length < 3) return null;
  String? best;
  var bestScore = 0.0;
  for (final s in sentencesOf(text)) {
    final have = _keyWords(s).toSet();
    final nums = _numbers(s).toSet();
    if (!numbers.every(nums.contains)) continue;
    final found = words.where(have.contains).length;
    final score = found / words.length;
    if (found >= 3 && score >= 0.6 && score > bestScore) {
      best = s.trim();
      bestScore = score;
    }
  }
  return best;
}

/// Sentences of [text] that share key words with [claim], best first: the
/// choices offered when the learner picks a supporting sentence by hand.
List<String> candidateSentences(String claim, String text, {int max = 8}) {
  final words = _keyWords(claim).toSet();
  if (words.isEmpty) return const [];
  final scored = [
    for (final s in sentencesOf(text))
      if (_keyWords(s).where(words.contains).length case final n when n > 0) (s: s.trim(), n: n),
  ]..sort((a, b) => b.n.compareTo(a.n));
  return [for (final x in scored.take(max)) x.s];
}

// ---- asking the dossier ----

/// What "ask the dossier" found for a question: cards whose claim or
/// quote shares its key words, and sentences in the sources not yet on a
/// card. Both empty means "not found in your sources".
typedef DossierAnswer = ({List<String> cardIds, List<({String sourceId, String sentence})> sentences});

/// Looks for [question]'s key words in [cards] (id, claim, quote) and in
/// [sources] (id, body). A card or sentence matches when it holds at least
/// half the key words (all of them for one or two). Never guesses.
DossierAnswer askDossier(
  String question, {
  required List<({String id, String claim, String quote})> cards,
  required List<({String id, String body})> sources,
}) {
  final words = _keyWords(question).toSet();
  if (words.isEmpty) return (cardIds: const [], sentences: const []);
  final need = words.length <= 2 ? words.length : (words.length / 2).ceil();
  bool hits(String s) => _keyWords(s).toSet().where(words.contains).length >= need;
  final cardIds = [
    for (final c in cards)
      if (hits('${c.claim} ${c.quote}')) c.id,
  ];
  final quoted = {for (final c in cards) normaliseForQuote(c.quote)};
  final sentences = <({String sourceId, String sentence})>[];
  for (final s in sources) {
    for (final line in sentencesOf(s.body)) {
      if (sentences.length >= 6) break;
      if (hits(line) && !quoted.contains(normaliseForQuote(line))) {
        sentences.add((sourceId: s.id, sentence: line.trim()));
      }
    }
  }
  return (cardIds: cardIds, sentences: sentences);
}

/// Where to look for something the sources do not have, by the
/// question's words.
List<({String label, String url})> whereToLook(String question, {String employer = '', String odsCode = ''}) {
  final q = ' ${normaliseForQuote(question)} ';
  bool has(String words) => RegExp(' ($words) ').hasMatch(q);
  final e = Uri.encodeQueryComponent(employer);
  return [
    if (has('pay|salary|band|bands|pension|leave|hours'))
      (
        label: 'NHS Employers: Agenda for Change pay',
        url: 'https://www.nhsemployers.org/topics/pay-pensions-and-reward',
      ),
    if (has('survey|morale|staff|culture|bullying|wellbeing'))
      (label: 'NHS Staff Survey results', url: 'https://www.nhsstaffsurveys.com/results/'),
    if (has('cqc|rating|rated|inspection|safe|quality'))
      (
        label: 'CQC',
        url: odsCode.isNotEmpty ? 'https://www.cqc.org.uk/provider/$odsCode' : 'https://www.cqc.org.uk/',
      ),
    if (has('director|directors|company|accounts|officers|owner'))
      (
        label: 'Companies House',
        url: 'https://find-and-update.company-information.service.gov.uk/search/companies?q=$e',
      ),
    (label: 'The employer\'s board papers and annual report (its own website)', url: ''),
  ];
}

// ---- artefacts ----

/// A card as the artefacts read it.
typedef CardFacts = ({
  String id,
  String claim,
  String kind,
  String status,
  String sourceTitle,
  String sourceDate,
  String staleAfter,
});

/// A point or question and the card it rests on.
typedef Artefact = ({String text, String cardId});

bool _usable(CardFacts c) => c.status == 'verified' || c.status == 'user-confirmed';

/// The kinds that make good reasons to want a job, best first.
const _whyOrder = ['strategy', 'values', 'systems', 'team', 'staff-survey', 'cqc', 'board', 'other', 'pay'];

/// Up to three "why here" points, each from one verified or user-confirmed
/// card (never an anecdotal review, never an inference), fresh cards
/// first, one per kind before a second of any kind.
List<Artefact> whyHerePoints(List<CardFacts> cards, {required String today}) {
  final pool =
      [
        for (final c in cards)
          if (_usable(c) && c.kind != 'reviews-anecdotal') c,
      ]..sort((a, b) {
        final s = (isStale(a.staleAfter, today) ? 1 : 0).compareTo(isStale(b.staleAfter, today) ? 1 : 0);
        if (s != 0) return s;
        return _rank(a.kind).compareTo(_rank(b.kind));
      });
  final out = <Artefact>[];
  final kinds = <String>{};
  for (final pass in [true, false]) {
    for (final c in pool) {
      if (out.length == 3) break;
      if (out.any((o) => o.cardId == c.id)) continue;
      if (pass && !kinds.add(c.kind)) continue;
      out.add((text: '${_sentence(c.claim)} (${_cite(c)})', cardId: c.id));
    }
  }
  return out;
}

int _rank(String kind) {
  final i = _whyOrder.indexOf(kind);
  return i < 0 ? _whyOrder.length : i;
}

/// Up to three questions to ask the panel, each built from one verified or
/// user-confirmed card by a fixed pattern for its kind. Concerns (staff
/// survey, CQC, anecdotal reviews) come first: they make the best
/// questions.
List<Artefact> questionsToAsk(List<CardFacts> cards, {required String today}) {
  const order = [
    'staff-survey',
    'cqc',
    'strategy',
    'board',
    'systems',
    'reviews-anecdotal',
    'team',
    'values',
    'other',
  ];
  int rank(String k) => order.contains(k) ? order.indexOf(k) : order.length;
  final pool = [
    for (final c in cards)
      if (_usable(c) && c.kind != 'pay') c,
  ]..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
  final out = <Artefact>[];
  final kinds = <String>{};
  for (final pass in [true, false]) {
    for (final c in pool) {
      if (out.length == 3) break;
      if (out.any((o) => o.cardId == c.id)) continue;
      if (pass && !kinds.add(c.kind)) continue;
      final claim = _plainClaim(c.claim);
      final text = switch (c.kind) {
        'strategy' || 'board' => 'I read that $claim. How will this post help with that?',
        'staff-survey' ||
        'cqc' => 'I read that $claim. What is the team doing about it, and how could I help?',
        'systems' => 'I read that $claim. How does that change day-to-day work in this team?',
        'reviews-anecdotal' => 'Some staff reviews say $claim. How is that for this team now?',
        'team' => 'I read that $claim. How does the team work together day to day?',
        _ => 'I read that $claim. How does that touch this role?',
      };
      out.add((text: text, cardId: c.id));
    }
  }
  return out;
}

String _cite(CardFacts c) => [
  c.sourceTitle.isNotEmpty ? c.sourceTitle : 'your source',
  if (c.sourceDate.isNotEmpty) niceDate(c.sourceDate),
].join(', ');

String _sentence(String s) {
  final t = s.trim();
  if (t.isEmpty) return t;
  return RegExp(r'[.!?]$').hasMatch(t) ? t.substring(0, t.length - 1) : t;
}

/// A claim fit to follow "I read that": its end mark dropped and its first
/// letter lower-cased, unless it starts with an acronym ("CQC") or a name
/// (two capitalised words, "Example Health").
String _plainClaim(String s) {
  final t = _sentence(s);
  final words = t.split(' ');
  if (t.length < 2) return t;
  bool cap(String w) => w.isNotEmpty && w[0] != w[0].toLowerCase();
  final acronym = words.first.length > 1 && words.first == words.first.toUpperCase() && cap(words.first);
  final name = words.length > 1 && cap(words[0]) && cap(words[1]);
  return acronym || name ? t : '${t[0].toLowerCase()}${t.substring(1)}';
}

String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;
