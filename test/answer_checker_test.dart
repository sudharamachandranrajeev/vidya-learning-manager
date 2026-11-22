// The answer checker's Vidya side (J6): fact cards and program criteria
// mapped to the interview engine, likely questions with and without cards,
// the story bank as the only other source of a rewrite, and the same rules
// for a local model as for a cloud one. Made-up employer and answers.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:interview_engine/interview_engine.dart' as ie;
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/answer_checker.dart';
import 'package:vidya/domain/interview.dart';
import 'package:vidya/domain/spoken_interview.dart';

Criterion _criterion(String id, String body, {bool essential = true, String kind = ''}) => Criterion(
  id: id,
  hlc: '',
  deleted: false,
  programId: 'p1',
  ref: id,
  body: body,
  essential: essential,
  kind: kind,
  source: 'advert',
  ord: 0,
);

FactCard _card(
  String id,
  String claim, {
  String quote = '',
  String kind = 'other',
  String status = 'verified',
}) => FactCard(
  id: id,
  hlc: '',
  deleted: false,
  programId: 'p1',
  employer: 'Example Health',
  claim: claim,
  sourceId: '',
  sourceUrl: '',
  sourceTitle: 'Example source',
  sourceDate: '2025-01-01',
  fetchedAt: '',
  quote: quote,
  status: status,
  kind: kind,
  staleAfter: '2026-01-01',
  origin: 'you',
  created: '2026-11-22',
  updated: '2026-11-22',
);

void main() {
  test('how a criterion is assessed is read from its text', () {
    expect(assessByIn('Experience of rota planning (A/I)'), ['A', 'I']);
    expect(assessByIn('Typing speed [T]'), ['T']);
    expect(assessByIn('Good IT skills. Assessed by: application and interview'), ['A', 'I']);
    expect(assessByIn('Works well in a team'), isEmpty);
    expect(withoutAssessBy('Experience of rota planning (A/I)'), 'Experience of rota planning');
    final c = engineCriteria([_criterion('r1', 'Experience of rota planning (A/I)', kind: 'skill')]).single;
    expect((c.id, c.text, c.kind), ('r1', 'Experience of rota planning', ie.CriterionKind.skill));
    expect(c.assessBy, ['A', 'I']);
  });

  test('cards map with their status and a stale flag; inference never feeds a question', () {
    final cards = evidenceCards([
      _card(
        'f1',
        'Our values are compassion and respect.',
        quote: 'Our values are compassion and respect.',
        kind: 'values',
      ),
      _card('f2', 'The trust may close a ward.', kind: 'strategy', status: 'inference'),
    ], today: '2026-11-22');
    expect(cards[0].status, ie.CardStatus.verified);
    expect(cards[0].stale, isTrue);
    expect(cards[1].usable, isFalse);
    final qs = likelyQuestions(
      [_criterion('r1', 'Experience of rota planning (I)')],
      [
        _card(
          'f1',
          'Our values are compassion and respect.',
          quote: 'Our values are compassion and respect.',
          kind: 'values',
        ),
        _card('f2', 'The trust may close a ward.', kind: 'strategy', status: 'inference'),
      ],
      today: '2026-11-22',
    );
    expect(qs.first.tier, ie.EvidenceTier.personSpec);
    expect(qs.where((q) => q.cardId == 'f1'), isNotEmpty);
    expect(qs.where((q) => q.cardId == 'f1').first.why, contains('may be out of date'));
    expect(qs.where((q) => q.cardId == 'f2'), isEmpty);
  });

  test('with no cards, likely questions come from the criteria and common ones only', () {
    final qs = likelyQuestions(
      [_criterion('r1', 'Experience of rota planning')],
      const [],
      today: '2026-11-22',
    );
    expect(qs.where((q) => q.tier == ie.EvidenceTier.organisation), isEmpty);
    expect(qs.first.criterionId, 'r1');
    expect(qs.first.tier, ie.EvidenceTier.generic);
    expect(ie.organisationTierNote(const []), ie.notInSourcesNote);
  });

  test('the story bank is text a rewrite may use', () {
    const s = Story(
      id: 's1',
      title: 'Rota cover',
      situation: 'Two clerks were off.',
      action: 'I rang the bank.',
    );
    expect(storyTexts([s]).single, 'Rota cover. Two clerks were off.. I rang the bank.');
    expect(
      ie.inventedTokens('I covered rota gaps for Two weeks.', answer: '', storyBank: storyTexts([s])),
      isEmpty,
    );
  });

  test('rule 12: quote-less praise from Vidya\'s text-only AI scores N/O, as from any model', () async {
    const said =
        'Last spring I trained twelve new starters on the booking system. I wrote a one-page guide and ran '
        'short practice sessions.';
    const q = ie.EngineQuestion({
      'question': 'Tell me about a time you taught a new system.',
      'category': 'Behavioural',
      'criteria': ['e1'],
    });
    const profile = ie.RoleProfile(
      id: 'p',
      title: 'Trainer',
      frameworkId: 'nhs_values',
      criteria: [ie.Criterion(id: 'e1', text: 'Explain a new system to beginners')],
    );
    final round = ie.DebriefRound.of(questions: const [q], answers: {0: said}, profile: profile);
    final brain = VidyaInterviewBrain(
      (system, text) async =>
          'Of course! ${jsonEncode({
            'answers': [
              {
                'question': 1,
                'scores': [
                  {'criterion': 'e1', 'level': '4', 'quote': ''},
                ],
                'strength': 'Superb!',
                'strengthQuote': '',
                'fix': 'None.',
              },
            ],
          })}',
    );
    final runs = await ie.scoreTwice(
      brain: brain,
      role: 'Trainer',
      framework: profile.framework,
      round: round,
      random: math.Random(1),
    );
    final v = ie.verifyRuns(runs, profile.framework.scale, round);
    expect(v.scores.single.level.code, 'N/O');
    expect(v.answers[0]!.strength, '');
  });
}
