/// The stage packs' reads and writes (J8). Each pack keeps its data in its
/// stage's progress (`StageProgress.pack`), so a plan sent again never
/// loses it and no table changes. Flashcards for people and acronyms go to
/// the ordinary card decks, wins to the story bank, and a next role to its
/// own program with readiness; email drafts handed to Udyoga go in a
/// progress row of their own ([emailDraftsId]).
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'interview.dart';
import 'journey.dart';
import 'journey_book.dart';
import 'offer_checker.dart';
import 'readiness.dart';
import 'stage_packs.dart';

/// The progress row Vidya writes with email drafts for Udyoga's
/// Conversations. Udyoga never sends them: the learner picks one in a
/// thread's composer, reads it and sends it themselves.
const emailDraftsId = 'vidya.email-drafts';

/// The `format` of [emailDraftsId]'s JSON.
const emailDraftsFormat = 'vidya-email-drafts';

/// At most this many drafts are kept for Udyoga, newest first.
const maxEmailDrafts = 20;

/// The most entries a pack list keeps (people, acronyms, wins, training).
const maxPackRows = 200;

/// An email draft handed to Udyoga.
typedef EmailDraft = ({
  String id,
  String template,
  String title,
  String subject,
  String body,
  String employer,
  String role,
  String at,
});

String _day(String now) => switch (DateTime.tryParse(now)) {
  final t? => isoDate(t.toLocal()),
  null => today(),
};

String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

List<Map<String, Object?>> _rows(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map) {for (final e in r.entries) '${e.key}': e.value},
];

extension StagePacks on LearningBook {
  // ---- fill-ins and offer ----

  /// Saves the offer's facts on the offer stage.
  Future<void> setOfferFacts(String programId, OfferFacts facts, {required String now}) =>
      setStagePack(programId, 'offer', (p) => {...p, 'facts': facts.toJson()}, now: now);

  /// Saves the evidence table's rows (each keyed by [evidenceColumns]).
  Future<void> setEvidenceRows(String programId, List<Map<String, String>> rows, {required String now}) =>
      setStagePack(
        programId,
        'offer',
        (p) => {
          ...p,
          'evidence': [
            for (final r in rows.take(30))
              {
                for (final k in evidenceColumns)
                  if ((r[k] ?? '').trim().isNotEmpty) k: _clip(r[k]!.trim(), 300),
              },
          ],
        },
        now: now,
      );

  // ---- checks ----

  /// Sets one of Vidya's own checks (used when Udyoga sends none): its
  /// status and due date ('' clears it). A done check records the day.
  Future<void> setOwnCheck(
    String programId,
    String kind, {
    String? status,
    String? due,
    required String now,
  }) => setStagePack(programId, 'checks', (p) {
    final old = p[kind] is Map ? {...(p[kind] as Map)} : <Object?, Object?>{};
    if (status != null && checkStatuses.containsKey(status)) {
      old['status'] = status;
      if (status == 'done') {
        old['done'] = old['done'] ?? _day(now);
      } else {
        old.remove('done');
      }
    }
    if (due != null) due.isEmpty || !isValidIsoDate(due) ? old.remove('due') : old['due'] = due;
    return {...p, kind: old};
  }, now: now);

  // ---- joining: people and acronyms as flashcards ----

  /// Adds (or changes) a person (`people`) or an acronym or system
  /// (`acronyms`) on the joining stage and as a flashcard in its deck, due
  /// today, so it comes up in spaced review. A card with the same front in
  /// that deck is changed in place and keeps its schedule.
  Future<void> addPackCard(
    String programId,
    String list, {
    required String front,
    required String back,
    required String today,
    required String now,
  }) => db.transaction(() async {
    assert(list == 'people' || list == 'acronyms');
    final f = _clip(front.trim(), 200), b = _clip(back.trim(), 500);
    if (f.isEmpty || b.isEmpty) return;
    final view = await journeyView(programId);
    if (view == null) return;
    final deck = list == 'people' ? peopleDeck(view.journey) : acronymDeck(view.journey);
    await setStagePack(programId, 'joining', (p) {
      final rows = [
        for (final r in packCards(p[list]))
          if (r.front.toLowerCase() != f.toLowerCase()) {'front': r.front, 'back': r.back},
        {'front': f, 'back': b},
      ];
      return {...p, list: rows.skip(rows.length > maxPackRows ? rows.length - maxPackRows : 0).toList()};
    }, now: now);
    final existing = (await (db.select(
      db.learnCards,
    )..where((c) => c.deck.equals(deck) & c.front.equals(f) & c.deleted.not())).get()).firstOrNull;
    await saveCard(f, b, today: today, deck: deck, existing: existing);
  });

  /// Removes a person or acronym from the list (its flashcard stays, with
  /// its reviews; delete it from the deck to drop it).
  Future<void> removePackCard(String programId, String list, String front, {required String now}) =>
      setStagePack(
        programId,
        'joining',
        (p) => {
          ...p,
          list: [
            for (final r in packCards(p[list]))
              if (r.front != front) {'front': r.front, 'back': r.back},
          ],
        },
        now: now,
      );

  /// Ticks a day-one item, or adds one when [add].
  Future<void> setDayOne(String programId, String item, bool on, {bool add = false, required String now}) =>
      setStagePack(programId, 'joining', (p) {
        final items = [
          for (final i in (p['dayOne'] is List ? p['dayOne'] as List : dayOneStarter))
            if (i is String) i,
        ];
        final t = _clip(item.trim(), 200);
        if (add && t.isNotEmpty && !items.contains(t)) items.add(t);
        final ticked = {
          for (final i in (p['dayOneTicked'] is List ? p['dayOneTicked'] as List : const []))
            if (i is String) i,
        };
        if (!add) on ? ticked.add(t) : ticked.remove(t);
        return {...p, 'dayOne': items, 'dayOneTicked': ticked.toList()..sort()};
      }, now: now);

  /// Sets the training tracker's rows.
  Future<void> setTraining(String programId, List<TrainingRow> rows, {required String now}) => setStagePack(
    programId,
    'joining',
    (p) => {
      ...p,
      'training': [
        for (final r in rows.take(maxPackRows))
          {
            'name': _clip(r.name, 200),
            if (r.due.isNotEmpty) 'due': r.due,
            if (r.done.isNotEmpty) 'done': r.done,
          },
      ],
    },
    now: now,
  );

  // ---- first 90 days ----

  /// Saves the 30/60/90 plan's text ([plan90Parts] keys), the probation
  /// start and length.
  Future<void> setPlan90(String programId, Map<String, String> fields, {required String now}) => setStagePack(
    programId,
    'first-90-days',
    (p) => {...p, for (final e in fields.entries) e.key: _clip(e.value.trim(), maxDraft)},
    now: now,
  );

  /// Logs a win for the week.
  Future<void> addWin(String programId, String text, {required String now}) {
    final t = _clip(text.trim(), 2000);
    if (t.isEmpty) return Future.value();
    return setStagePack(
      programId,
      'first-90-days',
      (p) => {
        ...p,
        'wins': [
          for (final w in wins(p['wins'])) {'id': w.id, 'day': w.day, 'text': w.text, 'story': w.story},
          {'id': newId(), 'day': _day(now), 'text': t, 'story': ''},
        ].reversed.take(maxPackRows).toList().reversed.toList(),
      },
      now: now,
    );
  }

  /// Turns a logged win into a story in the story bank (its text as the
  /// action, to be shaped into STAR later) and links the win to it.
  /// Returns the story id; a win already turned keeps its story.
  Future<String?> winToStory(
    String programId,
    String winId, {
    required String today,
    required String now,
  }) => db.transaction(() async {
    final view = await journeyView(programId);
    final w = wins(view?.of('first-90-days').pack['wins']).where((x) => x.id == winId).firstOrNull;
    if (w == null) return null;
    if (w.story.isNotEmpty) return w.story;
    final title = w.text.split(RegExp(r'[.\n]')).first.trim();
    final id = await saveStory(
      title: _clip(title.isEmpty ? w.text : title, 120),
      situation:
          'Logged as a win on ${w.day}${view!.journey.employer.isEmpty ? '' : ' at ${view.journey.employer}'}.',
      action: w.text,
      today: today,
    );
    await setStagePack(
      programId,
      'first-90-days',
      (p) => {
        ...p,
        'wins': [
          for (final x in wins(p['wins']))
            {'id': x.id, 'day': x.day, 'text': x.text, 'story': x.id == winId ? id : x.story},
        ],
      },
      now: now,
    );
    return id;
  });

  /// Records a monthly check-in on [day] with the answers to
  /// [checkInPrompts]; the next one falls a month later.
  Future<void> doCheckIn(
    String programId,
    Map<String, String> answers, {
    required String day,
    required String now,
  }) => setStagePack(programId, 'first-90-days', (p) {
    final log = _rows(p['checkIns']);
    return {
      ...p,
      'lastCheckIn': day,
      'checkIns': [
        ...log.skip(log.length >= 24 ? log.length - 23 : 0),
        {
          'day': day,
          for (final e in answers.entries)
            if (e.value.trim().isNotEmpty) e.key: _clip(e.value.trim(), 2000),
        },
      ],
    };
  }, now: now);

  /// The day each started journey's next monthly check-in falls, once the
  /// learner has a start date (the offer's) or has done one.
  Future<List<({String programId, String day})>> checkInsDue() async {
    final rows = await (db.select(db.learnJourneys)..where((j) => j.deleted.not())).get();
    final out = <({String programId, String day})>[];
    for (final r in rows) {
      final v = await journeyView(r.programId);
      if (v == null) continue;
      final ninety = v.of('first-90-days').pack;
      final start = OfferFacts.fromJson(
        v.of('offer').pack['facts'] is Map
            ? {for (final e in (v.of('offer').pack['facts'] as Map).entries) '${e.key}': e.value}
            : const {},
      ).startDate;
      final last = ninety['lastCheckIn'] is String ? ninety['lastCheckIn'] as String : '';
      final next = nextCheckIn(last: last, start: start);
      if (next != null) out.add((programId: r.programId, day: next));
    }
    return out;
  }

  // ---- grow ----

  Future<void> setPdr(String programId, Map<String, String> fields, {required String now}) => setStagePack(
    programId,
    'grow',
    (p) => {
      ...p,
      'pdr': {
        for (final e in fields.entries)
          if (e.value.trim().isNotEmpty) e.key: _clip(e.value.trim(), maxDraft),
      },
    },
    now: now,
  );

  /// Starts a program for the next role up: its criteria pasted from that
  /// role's specification, so the Readiness page (V6) measures the learner
  /// against it with the same evidence (stories, drills, portfolio).
  /// Returns the new program's id, kept on the grow stage.
  Future<String?> startNextRole(
    String programId, {
    required String title,
    required String criteria,
    required String today,
    required String now,
  }) => db.transaction(() async {
    final parsed = parseNextCriteria(criteria).take(80).toList();
    final t = _clip(title.trim(), 200);
    if (t.isEmpty || parsed.isEmpty) return null;
    final id = await addProgram(
      'Next role: $t',
      'Readiness for $t, from its person specification.',
      today: today,
    );
    final row = await (db.select(db.learnPrograms)..where((p) => p.id.equals(id))).getSingle();
    await save(db.learnPrograms, row.copyWith(role: t), id);
    for (final c in parsed) {
      await saveOwnCriterion(id, body: _clip(c.text, 400), essential: c.essential);
    }
    await setStagePack(programId, 'grow', (p) => {...p, 'nextProgram': id, 'nextTitle': t}, now: now);
    return id;
  });

  // ---- drafts for Udyoga ----

  /// Whether Udyoga is linked: it has sent a plan through sync.
  Future<bool> udyogaLinked() async =>
      (await (db.select(db.bridgeStudyPlans)
                ..where((p) => p.deleted.not() & p.source.equals('udyoga'))
                ..limit(1))
              .get())
          .isNotEmpty;

  /// The drafts handed to Udyoga, newest first.
  Future<List<EmailDraft>> emailDrafts() async {
    final row = await (db.select(
      db.bridgeStudyProgress,
    )..where((p) => p.id.equals(emailDraftsId))).getSingleOrNull();
    return row == null || row.deleted ? const [] : parseEmailDrafts(row.progress);
  }

  /// Hands a filled template to Udyoga's Conversations: added at the top
  /// of the [emailDraftsId] row (replacing an older draft from the same
  /// template for the same job), which syncs like the rest of the
  /// progress. Nothing is sent.
  Future<EmailDraft> sendDraftToUdyoga({
    required String template,
    required String title,
    required String subject,
    required String body,
    required String employer,
    required String role,
    required String now,
  }) => db.transaction(() async {
    final draft = (
      id: newId(),
      template: template,
      title: _clip(title, 200),
      subject: _clip(subject, 300),
      body: _clip(body, 8000),
      employer: _clip(employer, 200),
      role: _clip(role, 200),
      at: now,
    );
    final rest = [
      for (final d in await emailDrafts())
        if (!(d.template == template && d.employer == draft.employer && d.role == draft.role)) d,
    ];
    await save(
      db.bridgeStudyProgress,
      BridgeStudyProgressCompanion.insert(
        id: emailDraftsId,
        progress: Value(emailDraftsJson([draft, ...rest].take(maxEmailDrafts).toList())),
        updated: now,
        deleted: const Value(false),
      ),
      emailDraftsId,
    );
    return draft;
  });
}

/// The progress JSON of [emailDraftsId].
String emailDraftsJson(List<EmailDraft> drafts) => jsonEncode({
  'format': emailDraftsFormat,
  'version': 1,
  'drafts': [
    for (final d in drafts)
      {
        'id': d.id,
        'template': d.template,
        'title': d.title,
        if (d.subject.isNotEmpty) 'subject': d.subject,
        'body': d.body,
        if (d.employer.isNotEmpty) 'employer': d.employer,
        if (d.role.isNotEmpty) 'role': d.role,
        'at': d.at,
      },
  ],
});

/// The drafts in an [emailDraftsJson] text; unreadable ones are left out.
List<EmailDraft> parseEmailDrafts(String json) {
  Object? j;
  try {
    j = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (j is! Map || j['format'] != emailDraftsFormat || j['drafts'] is! List) return const [];
  String s(Map d, String k) => d[k] is String ? d[k] as String : '';
  return [
    for (final d in j['drafts'] as List)
      if (d is Map && s(d, 'id').isNotEmpty && s(d, 'body').isNotEmpty)
        (
          id: s(d, 'id'),
          template: s(d, 'template'),
          title: s(d, 'title'),
          subject: s(d, 'subject'),
          body: s(d, 'body'),
          employer: s(d, 'employer'),
          role: s(d, 'role'),
          at: s(d, 'at'),
        ),
  ];
}
