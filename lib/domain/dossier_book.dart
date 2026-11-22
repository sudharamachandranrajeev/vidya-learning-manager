/// The job dossier in the database (journey plan J5): sources and fact
/// cards per program (one program per job journey), synced like the rest
/// of Vidya. Every write goes through the quote check in dossier.dart: a
/// card is saved as verified only when its quote is in the stored text of
/// its source.
library;

import 'package:brahma_core/brahma_core.dart' show newId;
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'dossier.dart';
import 'journey.dart';
import 'spoken_interview.dart' show parseBrainReply;

/// A record an official reader fetched, ready to keep: the text Vidya
/// stores and the facts read from it (each quote a line of [body]).
class ReaderRecord {
  const ReaderRecord({
    required this.kind,
    required this.url,
    required this.title,
    required this.body,
    this.sourceDate = '',
    this.facts = const [],
  });
  final String kind, url, title, body, sourceDate;
  final List<FactProposal> facts;
}

/// Asks an AI for the facts in [src] through [send] (system prompt, text;
/// returns the reply). Only the source's text is sent, at most
/// [maxAiText] characters. A reply with no JSON object is refused with a
/// [FormatException] in plain words, as the interviewer does; the facts
/// still have to pass the quote check ([DossierBook.addProposals]).
Future<List<FactProposal>> aiFactProposals(
  Future<String> Function(String system, String text) send,
  FactSource src,
) async {
  final text = src.body.length > maxAiText ? src.body.substring(0, maxAiText) : src.body;
  final reply = await send(factPromptSystem(src.kind), 'Source: ${src.title}\n\n$text');
  Map<String, Object?> j;
  try {
    j = parseBrainReply(reply);
  } on FormatException {
    throw const FormatException(
      'The AI did not reply in the form asked for, so nothing was added. Try again, or try another AI.',
    );
  }
  return parseFactProposals(j, defaultKind: defaultFactKind(src.kind));
}

/// [url] for comparing: no scheme, `www.`, fragment or trailing slash, in
/// lower case.
String sameUrl(String url) => url
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp(r'^https?://'), '')
    .replaceFirst(RegExp(r'^www\.'), '')
    .replaceFirst(RegExp(r'#.*$'), '')
    .replaceFirst(RegExp(r'/+$'), '');

extension DossierBook on LearningBook {
  Future<List<FactCard>> factCards(String programId) =>
      (db.select(db.learnFacts)
            ..where((f) => f.programId.equals(programId) & f.deleted.not())
            ..orderBy([(f) => OrderingTerm.asc(f.created), (f) => OrderingTerm.asc(f.id)]))
          .get();

  Future<List<FactSource>> factSources(String programId) =>
      (db.select(db.learnFactSources)
            ..where((s) => s.programId.equals(programId) & s.deleted.not())
            ..orderBy([(s) => OrderingTerm.desc(s.fetchedAt)]))
          .get();

  Future<FactSource?> factSource(String id) =>
      (db.select(db.learnFactSources)..where((s) => s.id.equals(id) & s.deleted.not())).getSingleOrNull();

  Future<FactCard?> factCard(String id) =>
      (db.select(db.learnFacts)..where((f) => f.id.equals(id) & f.deleted.not())).getSingleOrNull();

  /// Keeps a source's text. A source of the same kind and address is
  /// replaced (a reader run again, an advert sent again) rather than kept
  /// twice. Then every inference card is checked against it. Returns the
  /// source's id.
  Future<String> addFactSource(
    String programId, {
    String employer = '',
    required String kind,
    String url = '',
    String title = '',
    String sourceDate = '',
    required String body,
    required String now,
  }) async {
    if (!sourceKinds.containsKey(kind)) throw ArgumentError.value(kind, 'kind');
    final text = body.length > maxSourceText ? body.substring(0, maxSourceText) : body;
    final old = url.isEmpty
        ? null
        : (await factSources(programId))
              .where((s) => s.kind == kind && sameUrl(s.url) == sameUrl(url))
              .firstOrNull;
    final id = old?.id ?? newId();
    await save(
      db.learnFactSources,
      LearnFactSourcesCompanion.insert(
        id: id,
        programId: programId,
        employer: Value(employer),
        kind: kind,
        url: Value(url.trim()),
        title: Value(title.trim()),
        sourceDate: Value(sourceDate),
        fetchedAt: now,
        body: text,
      ),
      id,
    );
    await recheckInference(programId, now: now);
    return id;
  }

  /// Saves the facts proposed from [sourceId] whose quote is in its text,
  /// as verified cards (a fact already on a card from that source is not
  /// added twice). Gives how many were added and those whose quote is not
  /// in the text, for the caller to drop or keep as inference.
  Future<({int added, List<FactProposal> unmatched})> addProposals(
    String sourceId,
    List<FactProposal> proposals, {
    required String origin,
    required String now,
  }) async {
    final src = await factSource(sourceId);
    if (src == null) return (added: 0, unmatched: proposals);
    final checked = checkProposals(proposals, src.body);
    final have = {
      for (final c in await factCards(src.programId))
        if (c.sourceId == sourceId) normaliseForQuote(c.quote),
    };
    var added = 0;
    for (final p in checked.verified) {
      if (!have.add(normaliseForQuote(p.quote))) continue;
      await _insert(
        src.programId,
        employer: src.employer,
        claim: p.claim,
        quote: p.quote,
        kind: src.kind == 'reviews' ? 'reviews-anecdotal' : p.kind,
        status: 'verified',
        source: src,
        origin: origin,
        now: now,
      );
      added++;
    }
    return (added: added, unmatched: checked.unmatched);
  }

  /// Saves a fact the learner wrote. With a source and a quote that is in
  /// its text it is verified; with [checkedMyself] it is user-confirmed;
  /// otherwise it is kept as inference. Returns the card's id and status.
  Future<({String id, String status})> addOwnFact(
    String programId, {
    String employer = '',
    required String claim,
    String quote = '',
    required String kind,
    String? sourceId,
    String sourceUrl = '',
    String sourceTitle = '',
    String sourceDate = '',
    bool checkedMyself = false,
    required String now,
  }) async {
    final src = sourceId == null ? null : await factSource(sourceId);
    final verified = src != null && quoteInSource(quote, src.body);
    final status = verified ? 'verified' : (checkedMyself ? 'user-confirmed' : 'inference');
    final id = await _insert(
      programId,
      employer: employer,
      claim: claim.trim(),
      quote: quote.trim(),
      kind: src?.kind == 'reviews' ? 'reviews-anecdotal' : kind,
      status: status,
      source: src,
      sourceUrl: sourceUrl,
      sourceTitle: sourceTitle,
      sourceDate: sourceDate,
      origin: 'you',
      now: now,
    );
    return (id: id, status: status);
  }

  Future<String> _insert(
    String programId, {
    required String employer,
    required String claim,
    required String quote,
    required String kind,
    required String status,
    FactSource? source,
    String sourceUrl = '',
    String sourceTitle = '',
    String sourceDate = '',
    required String origin,
    required String now,
  }) async {
    final id = newId();
    final k = factKinds.containsKey(kind) ? kind : 'other';
    final date = source?.sourceDate ?? sourceDate;
    final fetched = source?.fetchedAt ?? '';
    await save(
      db.learnFacts,
      LearnFactsCompanion.insert(
        id: id,
        programId: programId,
        employer: Value(employer),
        claim: claim.length > 500 ? claim.substring(0, 500) : claim,
        sourceId: Value(source?.id ?? ''),
        sourceUrl: Value(source?.url ?? sourceUrl),
        sourceTitle: Value(source?.title ?? sourceTitle),
        sourceDate: Value(date),
        fetchedAt: Value(fetched),
        quote: Value(quote.length > 1000 ? quote.substring(0, 1000) : quote),
        status: Value(status),
        kind: Value(k),
        staleAfter: Value(
          staleAfterFor(
            k,
            sourceDate: isRegister(source?.kind ?? '') ? '' : date,
            fetchedAt: fetched.isEmpty ? now : fetched,
          ),
        ),
        origin: Value(origin),
        created: now,
        updated: now,
      ),
      id,
    );
    return id;
  }

  /// The learner checked an inference card themselves.
  Future<void> confirmFact(String id, {required String now}) async {
    final c = await factCard(id);
    if (c == null || c.status != 'inference') return;
    await save(db.learnFacts, c.copyWith(status: 'user-confirmed', updated: now), id);
  }

  /// Gives a card [quote] from [sourceId] as its supporting sentence. The
  /// card becomes verified only when the quote is in the source's text;
  /// returns why not otherwise (null when it passed).
  Future<String?> attachQuote(String id, String sourceId, String quote, {required String now}) async {
    final c = await factCard(id);
    final src = await factSource(sourceId);
    if (c == null || src == null) return 'That card or source was deleted.';
    final problem = quoteProblem(quote, src.body);
    if (problem != null) return problem;
    await save(db.learnFacts, _verifiedFrom(c, src, quote.trim(), now), id);
    return null;
  }

  FactCard _verifiedFrom(FactCard c, FactSource src, String quote, String now) => c.copyWith(
    quote: quote,
    status: 'verified',
    sourceId: src.id,
    sourceUrl: src.url,
    sourceTitle: src.title.isNotEmpty ? src.title : c.sourceTitle,
    sourceDate: src.sourceDate,
    fetchedAt: src.fetchedAt,
    staleAfter: staleAfterFor(
      c.kind,
      sourceDate: isRegister(src.kind) ? '' : src.sourceDate,
      fetchedAt: src.fetchedAt,
    ),
    updated: now,
  );

  Future<void> setFactKind(String id, String kind, {required String now}) async {
    final c = await factCard(id);
    if (c == null || !factKinds.containsKey(kind) || c.kind == kind) return;
    final register = c.sourceId.isNotEmpty && isRegister((await factSource(c.sourceId))?.kind ?? '');
    await save(
      db.learnFacts,
      c.copyWith(
        kind: kind,
        staleAfter: staleAfterFor(
          kind,
          sourceDate: register ? '' : c.sourceDate,
          fetchedAt: c.fetchedAt.isEmpty ? c.created : c.fetchedAt,
        ),
        updated: now,
      ),
      id,
    );
  }

  Future<void> removeFact(String id) => remove(db.learnFacts, id);

  /// Deletes a source. Its cards stay, with the status they had.
  Future<void> removeFactSource(String id) => remove(db.learnFactSources, id);

  /// Keeps what a reader fetched: the record as a source and its facts as
  /// verified cards (their quotes are lines of the record). Returns the
  /// source's id.
  Future<String> saveReaderRecord(
    String programId,
    ReaderRecord r, {
    String employer = '',
    required String now,
  }) async {
    final id = await addFactSource(
      programId,
      employer: employer,
      kind: r.kind,
      url: r.url,
      title: r.title,
      sourceDate: r.sourceDate,
      body: r.body,
      now: now,
    );
    await addProposals(id, r.facts, origin: 'reader', now: now);
    return id;
  }

  /// Keeps the advert text Udyoga sent with the journey as a source.
  /// Returns its id, or null when there is no advert text.
  Future<String?> addAdvertSource(String programId, Journey j, {required String now}) async {
    if (j.advertText.trim().isEmpty) return null;
    return addFactSource(
      programId,
      employer: j.employer,
      kind: 'advert',
      url: j.advertUrl,
      title: j.role.isEmpty ? 'The job advert' : 'Advert: ${j.role}',
      body: j.advertText,
      now: now,
    );
  }

  /// Keeps the facts Udyoga proposes (from its employer brief) as
  /// inference cards, each once, and checks them against the sources
  /// already kept. Gives how many were new.
  Future<int> importJourneyFacts(String programId, Journey j, {required String now}) async {
    if (j.facts.isEmpty) return 0;
    final have = {
      for (final c in await factCards(programId)) '${normaliseForQuote(c.claim)}|${sameUrl(c.sourceUrl)}',
    };
    var added = 0;
    for (final f in j.facts) {
      if (!have.add('${normaliseForQuote(f.claim)}|${sameUrl(f.url)}')) continue;
      await _insert(
        programId,
        employer: j.employer,
        claim: f.claim,
        quote: '',
        kind: guessFactKind(f.claim),
        status: 'inference',
        sourceUrl: f.url,
        sourceTitle: f.title,
        origin: 'udyoga',
        now: now,
      );
      added++;
    }
    if (added > 0) await recheckInference(programId, now: now);
    return added;
  }

  /// Checks every inference card against the sources kept from the same
  /// address: a card with a quote is verified when the quote is in the
  /// text; one without (Udyoga's) when a sentence of the text holds all
  /// its numbers and most of its words ([supportingSentence]), which
  /// becomes its quote. Gives how many became verified.
  Future<int> recheckInference(String programId, {required String now}) async {
    final sources = await factSources(programId);
    if (sources.isEmpty) return 0;
    var n = 0;
    for (final c in await factCards(programId)) {
      if (c.status != 'inference') continue;
      final from = [
        for (final s in sources)
          if (s.id == c.sourceId || (c.sourceUrl.isNotEmpty && sameUrl(s.url) == sameUrl(c.sourceUrl))) s,
      ];
      for (final s in from) {
        final quote = c.quote.isNotEmpty
            ? (quoteInSource(c.quote, s.body) ? c.quote : null)
            : supportingSentence(c.claim, s.body);
        if (quote == null) continue;
        await save(db.learnFacts, _verifiedFrom(c, s, quote, now), c.id);
        n++;
        break;
      }
    }
    return n;
  }
}
