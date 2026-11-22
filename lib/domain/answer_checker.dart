/// The answer checker (journey plan J6): Vidya's own data mapped to the
/// interview engine's honesty rules, so Vidya and Udyoga check answers the
/// same way.
///
/// - Fact cards from the dossier become the engine's evidence cards. Only
///   verified and checked cards feed likely questions and the organisation
///   and manager expectations; an inference card never does.
/// - Program criteria become engine criteria, with how each is assessed
///   (application, interview, test, presentation) when its text says.
/// - The story bank is the only other source a rewrite may draw on.
///
/// Pure functions: no database and no network.
library;

import 'package:interview_engine/interview_engine.dart' as ie;

import '../db/database.dart';
import 'dossier.dart';
import 'interview.dart';

/// [cards] as the engine reads them, stale ones flagged as of [today].
List<ie.EvidenceCard> evidenceCards(Iterable<FactCard> cards, {required String today}) => [
  for (final c in cards)
    ie.EvidenceCard(
      id: c.id,
      claim: c.claim,
      quote: c.quote,
      kind: c.kind,
      status: ie.CardStatus.of(c.status),
      sourceTitle: c.sourceTitle,
      sourceDate: c.sourceDate,
      stale: isStale(c.staleAfter, today),
    ),
];

// "(A/I)", "[A, I]", "(I)", "(Application, Interview)", "Assessed by: interview".
final _codes = RegExp(r'[(\[]\s*([AITP](?:\s*[/,&]\s*[AITP])*)\s*[)\]]');
final _named = RegExp(
  r'\b(?:assessed(?: by| at)?|assessment|means of assessment|how assessed)\s*:?\s*'
  r'((?:application|interview|test|presentation)(?:\s*(?:,|/|and|&)\s*(?:application|interview|test|presentation))*)',
  caseSensitive: false,
);

/// How [text] says a criterion is assessed, as engine codes (A, I, T, P);
/// empty when it does not say. Person specifications write it as "(A/I)"
/// or "Assessed by: application, interview".
List<String> assessByIn(String text) {
  final out = <String>[];
  for (final m in _codes.allMatches(text)) {
    for (final c in RegExp('[AITP]').allMatches(m[1]!)) {
      if (!out.contains(c[0])) out.add(c[0]!);
    }
  }
  for (final m in _named.allMatches(text)) {
    for (final w in RegExp(
      'application|interview|test|presentation',
      caseSensitive: false,
    ).allMatches(m[1]!)) {
      final c = w[0]!.substring(0, 1).toUpperCase();
      if (!out.contains(c)) out.add(c);
    }
  }
  return out;
}

/// [text] without its assessment marks, for showing and wording questions.
String withoutAssessBy(String text) =>
    text.replaceAll(_codes, '').replaceAll(_named, '').replaceAll(RegExp(r'\s+'), ' ').trim();

ie.CriterionKind _kind(String k) => switch (k.toLowerCase()) {
  'value' || 'values' => ie.CriterionKind.value,
  'knowledge' => ie.CriterionKind.knowledge,
  'qualification' || 'qualifications' => ie.CriterionKind.qualification,
  'skill' || 'skills' => ie.CriterionKind.skill,
  'behaviour' || 'behaviours' || 'behavior' => ie.CriterionKind.behaviour,
  _ => ie.CriterionKind.experience,
};

/// The program's [criteria] as engine criteria (row id as the id).
List<ie.Criterion> engineCriteria(Iterable<Criterion> criteria) => [
  for (final c in criteria)
    ie.Criterion(
      id: c.id,
      text: withoutAssessBy(c.body).isEmpty ? c.body : withoutAssessBy(c.body),
      essential: c.essential,
      kind: _kind(c.kind),
      assessBy: assessByIn('${c.body} ${c.kind}'),
    ),
];

/// Likely questions for the program, ranked by evidence (see
/// [ie.rankQuestions]).
List<ie.PredictedQuestion> likelyQuestions(
  Iterable<Criterion> criteria,
  Iterable<FactCard> cards, {
  required String today,
  int max = 10,
}) => ie.rankQuestions(
  criteria: engineCriteria(criteria),
  cards: evidenceCards(cards, today: today),
  max: max,
);

/// The story bank as text a rewrite may draw on: each story's parts.
List<String> storyTexts(Iterable<Story> stories) => [
  for (final s in stories)
    [s.title, s.situation, s.task, s.action, s.result].where((p) => p.trim().isNotEmpty).join('. '),
];
