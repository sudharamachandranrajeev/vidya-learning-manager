/// The job journey (plan format 3): one journey per job, from deciding to
/// apply to growing in the post, in fixed stages. Each stage teaches
/// (lines with a dated source, or labelled general advice), lists what to
/// produce, says how it is checked and gives heads-ups. A plan's `journey`
/// carries the job's own data (employer, role, sector, advert, closing
/// date) and may carry stages of its own; the generic, dated templates in
/// journey_templates.dart fill in the rest (see [mergeJourney]). Nothing
/// here touches the database; see journey_book.dart.
library;

import 'package:brahma_core/brahma_core.dart';

import 'curriculum.dart' show PlanCriterion, parseQuizQuestions;

/// The stages, in order, with their plain titles. A stage id outside this
/// set is not read.
const journeyStages = {
  'decide': 'Decide',
  'research': 'Research the job',
  'contact': 'Contact the manager',
  'apply': 'Apply',
  'follow-up': 'Wait and follow up',
  'prepare': 'Prepare',
  'interview-day': 'Interview day',
  'after': 'After the interview',
  'offer': 'Offer',
  'checks': 'Checks',
  'joining': 'Joining',
  'first-90-days': 'First 90 days',
  'grow': 'Grow',
};

/// Kinds of employer a template is written for.
const journeySectors = {
  'nhs': 'NHS',
  'university': 'University',
  'private': 'Private company',
  'civil-service': 'Civil Service',
  'other': 'Other',
};

/// How a stage is checked: a quiz, a round with the interviewer, a
/// checklist, the coverage of a pasted draft against the essential
/// criteria, or the learner's own word.
const journeyCheckKinds = {
  'quiz': 'Quiz',
  'interviewer': 'Practice with the interviewer',
  'checklist': 'Checklist',
  'coverage': 'Criteria check',
  'self': 'Your own check',
};

// Limits keep a runaway or hostile file from flooding the database.
const _maxStages = 20, _maxLines = 30, _maxProduce = 60, _maxChecklist = 40;
const _maxTitle = 200, _maxText = 2000, _maxUrl = 500;

/// Where a line comes from, and the day it was last checked against it.
class JourneySource {
  const JourneySource({required this.url, this.title = '', this.date = ''});
  final String url, title;

  /// yyyy-MM-dd, '' when not known.
  final String date;

  Map<String, Object> toJson() => {
    'url': url,
    if (title.isNotEmpty) 'title': title,
    if (date.isNotEmpty) 'date': date,
  };
}

/// One thing a stage teaches, or one heads-up. A line with a [source] is
/// shown as a fact with its source and date; one without is labelled
/// general advice, never shown as fact.
class JourneyLine {
  const JourneyLine(this.text, {this.source, this.staleAfter = ''});
  final String text;
  final JourneySource? source;

  /// yyyy-MM-dd from which the line may be out of date (pay figures each
  /// April), '' when it does not date.
  final String staleAfter;

  bool get sourced => source != null;

  /// Whether, on [today], the line should be checked again.
  bool staleOn(String today) => staleAfter.isNotEmpty && today.compareTo(staleAfter) >= 0;

  Map<String, Object> toJson() => {
    'text': text,
    if (source != null) 'source': source!.toJson(),
    if (staleAfter.isNotEmpty) 'staleAfter': staleAfter,
  };
}

/// An artefact a stage produces: the learner ticks it, or keeps a note on it.
class JourneyProduce {
  const JourneyProduce(this.title, {this.kind = 'note'});
  final String title;

  /// note | document | table | email | plan | list | evidence | log
  final String kind;

  Map<String, Object> toJson() => {'title': title, 'kind': kind};
}

class JourneyCheck {
  const JourneyCheck({
    this.kind = 'self',
    this.prompt = '',
    this.items = const [],
    this.questions = const [],
  });

  /// One of [journeyCheckKinds].
  final String kind;

  /// What the check asks of the learner, in a sentence.
  final String prompt;

  /// A checklist's items.
  final List<String> items;

  /// A quiz's questions, as plan quizzes keep them.
  final List<Map<String, Object>> questions;

  Map<String, Object> toJson() => {
    'kind': kind,
    if (prompt.isNotEmpty) 'prompt': prompt,
    if (items.isNotEmpty) 'items': items,
    if (questions.isNotEmpty) 'questions': questions,
  };
}

class JourneyStage {
  const JourneyStage({
    required this.id,
    required this.title,
    required this.order,
    this.teach = const [],
    this.produce = const [],
    this.check,
    this.headsUp = const [],
    this.due,
  });
  final String id, title;
  final int order;
  final List<JourneyLine> teach, headsUp;
  final List<JourneyProduce> produce;
  final JourneyCheck? check;

  /// yyyy-MM-dd, or null.
  final String? due;

  JourneyStage copyWith({
    List<JourneyLine>? teach,
    List<JourneyLine>? headsUp,
    List<JourneyProduce>? produce,
    JourneyCheck? check,
    String? due,
  }) => JourneyStage(
    id: id,
    title: title,
    order: order,
    teach: teach ?? this.teach,
    produce: produce ?? this.produce,
    check: check ?? this.check,
    headsUp: headsUp ?? this.headsUp,
    due: due ?? this.due,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'order': order,
    if (teach.isNotEmpty) 'teach': [for (final l in teach) l.toJson()],
    if (produce.isNotEmpty) 'produce': [for (final p in produce) p.toJson()],
    'check': ?check?.toJson(),
    if (headsUp.isNotEmpty) 'headsUp': [for (final l in headsUp) l.toJson()],
    'due': ?due,
  };
}

/// A job's journey: the job's own data and any stages it brings.
class Journey {
  const Journey({
    this.employer = '',
    this.role = '',
    this.sector = 'other',
    this.advertUrl = '',
    this.closes,
    this.applicationStage = '',
    this.stages = const [],
    this.template = '',
    this.checked = '',
  });
  final String employer, role, sector, advertUrl;

  /// The advert's closing date (yyyy-MM-dd), or null.
  final String? closes;

  /// Where Udyoga's application stands (its stage id: `applied`,
  /// `interview` …), '' when it has none. It suggests a stage; the learner
  /// moves stages.
  final String applicationStage;
  final List<JourneyStage> stages;

  /// After [mergeJourney]: the template's name and the day its sources were
  /// checked. '' on a journey as sent.
  final String template, checked;

  JourneyStage? stage(String id) => stages.where((s) => s.id == id).firstOrNull;

  /// What a plan carries (no template fields).
  Map<String, Object> toJson() => {
    if (employer.isNotEmpty) 'employer': employer,
    if (role.isNotEmpty) 'role': role,
    'sector': sector,
    if (advertUrl.isNotEmpty) 'advertUrl': advertUrl,
    'closes': ?closes,
    if (applicationStage.isNotEmpty) 'applicationStage': applicationStage,
    if (stages.isNotEmpty) 'stages': [for (final s in stages) s.toJson()],
  };
}

/// Reads a plan's `journey` object. Throws a [FormatException] fit for the
/// learner when it is too big; drops what it cannot read.
Journey parseJourney(Object? j) {
  if (j is! Map) throw const FormatException('The plan\'s journey is not readable.');
  final sector = _str(j['sector'], 20).toLowerCase();
  final closes = _str(j['closes'], 10);
  final stages = <JourneyStage>[];
  final seen = <String>{};
  for (final s in _list(j['stages'], _maxStages, 'journey stages')) {
    if (s is! Map) continue;
    final id = _str(s['id'], 30).toLowerCase();
    if (!journeyStages.containsKey(id) || !seen.add(id)) continue;
    final title = _str(s['title'], _maxTitle);
    final due = _str(s['due'], 10);
    final check = s['check'] is Map ? _check(s['check'] as Map, id) : null;
    stages.add(
      JourneyStage(
        id: id,
        title: title.isNotEmpty ? title : journeyStages[id]!,
        order: s['order'] is num
            ? (s['order'] as num).round().clamp(0, 99)
            : journeyStages.keys.toList().indexOf(id),
        teach: _lines(s['teach'], 'lines to learn in “$id”'),
        produce: [
          for (final p in _list(s['produce'], _maxProduce, 'things to produce in “$id”')) ?_produce(p),
        ],
        check: check,
        headsUp: _lines(s['headsUp'], 'heads-ups in “$id”'),
        due: isValidIsoDate(due) ? due : null,
      ),
    );
  }
  stages.sort((a, b) => a.order.compareTo(b.order));
  return Journey(
    employer: _str(j['employer'], _maxTitle),
    role: _str(j['role'], _maxTitle),
    sector: journeySectors.containsKey(sector) ? sector : 'other',
    advertUrl: _url(j['advertUrl']),
    closes: isValidIsoDate(closes) ? closes : null,
    applicationStage: _str(j['applicationStage'], 30),
    stages: stages,
  );
}

JourneyCheck? _check(Map c, String stage) {
  final kind = _str(c['kind'], 20).toLowerCase();
  if (!journeyCheckKinds.containsKey(kind)) return null;
  return JourneyCheck(
    kind: kind,
    prompt: _str(c['prompt'], _maxText),
    items: [
      for (final i in _list(c['items'], _maxChecklist, 'checklist items in “$stage”'))
        if (_str(i is Map ? i['text'] : i, _maxTitle) case final t when t.isNotEmpty) t,
    ],
    questions: kind == 'quiz' ? parseQuizQuestions(c['questions'], 'quiz questions in “$stage”') : const [],
  );
}

JourneyProduce? _produce(Object? p) {
  final m = p is Map ? p : {'title': p};
  final title = _str(m['title'], _maxTitle);
  if (title.isEmpty) return null;
  final kind = _str(m['kind'], 20).toLowerCase();
  return JourneyProduce(title, kind: kind.isEmpty ? 'note' : kind);
}

List<JourneyLine> _lines(Object? v, String what) => [for (final l in _list(v, _maxLines, what)) ?_line(l)];

JourneyLine? _line(Object? l) {
  final m = l is Map ? l : {'text': l};
  final text = _str(m['text'], _maxText);
  if (text.isEmpty) return null;
  final s = m['source'];
  JourneySource? source;
  final url = s is Map ? _url(s['url']) : '';
  if (s is Map && url.isNotEmpty) {
    final date = _str(s['date'], 10);
    source = JourneySource(
      url: url,
      title: _str(s['title'], _maxTitle),
      date: isValidIsoDate(date) ? date : '',
    );
  }
  final stale = _str(m['staleAfter'], 10);
  return JourneyLine(text, source: source, staleAfter: isValidIsoDate(stale) ? stale : '');
}

/// Only web addresses: a source must be something the learner can open.
String _url(Object? v) {
  final u = _str(v, _maxUrl);
  return u.startsWith('https://') || u.startsWith('http://') ? u : '';
}

String _str(Object? v, int max) {
  if (v is! String && v is! num) return '';
  final s = '$v'.trim();
  return s.length > max ? s.substring(0, max) : s;
}

List<Object?> _list(Object? v, int max, String what) {
  if (v is! List) return const [];
  if (v.length > max) throw FormatException('Too many $what (${v.length}); the most is $max.');
  return v;
}

// ---- merging with a template ----

/// [job] filled in from [template] and the job's [criteria]: every stage in
/// order. A stage the job brings keeps its own lines, adding the
/// template's where it has none; the job's essential criteria become what
/// to produce for the application, and its closing date sets the due dates
/// up to applying.
Journey mergeJourney(Journey job, Journey template, {List<PlanCriterion> criteria = const []}) {
  final essentials = [
    for (final c in criteria)
      if (c.essential) c.text,
  ];
  final out = <JourneyStage>[];
  for (final (k, id) in journeyStages.keys.indexed) {
    final own = job.stage(id), base = template.stage(id);
    var s = switch ((own, base)) {
      (final o?, final b?) => o.copyWith(
        teach: o.teach.isEmpty ? b.teach : null,
        headsUp: o.headsUp.isEmpty ? b.headsUp : null,
        produce: o.produce.isEmpty ? b.produce : null,
        check: o.check ?? b.check,
      ),
      (final o?, null) => o,
      (null, final b?) => b,
      (null, null) => JourneyStage(id: id, title: journeyStages[id]!, order: k),
    };
    if (id == 'decide' && essentials.isNotEmpty) {
      s = s.copyWith(
        teach: [
          JourneyLine(
            'This job lists ${essentials.length} essential '
            '${essentials.length == 1 ? 'criterion' : 'criteria'}: ${essentials.join('; ')}.',
            source: job.advertUrl.isEmpty ? null : JourneySource(url: job.advertUrl, title: 'The job advert'),
          ),
          ...s.teach,
        ],
      );
    }
    if (id == 'apply' && essentials.isNotEmpty) {
      s = s.copyWith(
        produce: [
          ...s.produce,
          for (final e in essentials) JourneyProduce('Evidence for: $e', kind: 'evidence'),
        ],
      );
    }
    final closes = job.closes;
    if (closes != null && s.due == null) {
      final due = switch (id) {
        'decide' || 'research' => addDays(closes, -10),
        'contact' => addDays(closes, -7),
        // Busy adverts can close early.
        'apply' => addDays(closes, -2),
        _ => null,
      };
      if (due != null) s = s.copyWith(due: due);
    }
    out.add(
      JourneyStage(
        id: s.id,
        title: s.title,
        order: k,
        teach: s.teach,
        produce: s.produce,
        check: s.check,
        headsUp: s.headsUp,
        due: s.due,
      ),
    );
  }
  return Journey(
    employer: job.employer,
    role: job.role,
    sector: job.sector,
    advertUrl: job.advertUrl,
    closes: job.closes,
    applicationStage: job.applicationStage,
    stages: out,
    template: template.template,
    checked: template.checked,
  );
}

/// The journey stage an application at Udyoga's [stage] is in, or null
/// when it does not suggest one (no application, or withdrawn).
String? stageForApplication(String stage) => switch (stage) {
  'preparing' => 'apply',
  'applied' || 'screening' => 'follow-up',
  'interview' => 'prepare',
  'waitingList' || 'rejected' || 'noReply' => 'after',
  'offer' => 'offer',
  'checks' => 'checks',
  'accepted' => 'joining',
  _ => null,
};

/// Udyoga's application stages in plain words.
String applicationStageLabel(String stage) => switch (stage) {
  'preparing' => 'Preparing',
  'applied' => 'Applied',
  'screening' => 'Screening',
  'interview' => 'Interview',
  'waitingList' => 'Waiting list',
  'offer' => 'Offer',
  'checks' => 'Checks',
  'accepted' => 'Accepted',
  'rejected' => 'Rejected',
  'withdrawn' => 'Withdrawn',
  'noReply' => 'No reply',
  _ => stage,
};

// ---- the coverage check ----

enum Coverage {
  /// The criterion's own words appear in the draft.
  exact('Uses the criterion\'s words'),

  /// At least half of its key words appear, not in order.
  partly('Some of its words'),
  missing('Not found');

  const Coverage(this.label);
  final String label;
}

typedef CoverageRow = ({String criterion, Coverage coverage, List<String> missingWords});

/// Words too common to show that a criterion is covered.
const _stopWords = {
  'the',
  'and',
  'for',
  'with',
  'from',
  'that',
  'this',
  'into',
  'onto',
  'your',
  'their',
  'have',
  'has',
  'are',
  'was',
  'were',
  'will',
  'can',
  'able',
  'ability',
  'within',
  'across',
  'using',
  'use',
  'other',
  'others',
  'all',
  'any',
  'how',
  'who',
  'its',
  'our',
  'out',
  'not',
  'but',
  'also',
  'such',
  'well',
  'good',
  'including',
  'demonstrable',
  'demonstrated',
  'evidence',
  'experience',
  'knowledge',
  'skills',
  'skill',
  'understanding',
};

String _normal(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// A rough stem, so "training" finds "trained" and "diaries" finds "diary".
String _stem(String w) {
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  for (final end in ['ing', 'ed', 'es', 's']) {
    if (w.length > end.length + 3 && w.endsWith(end)) return w.substring(0, w.length - end.length);
  }
  return w;
}

List<String> _keyWords(String s) => [
  for (final w in _normal(s).split(' '))
    if (w.length >= 3 && !_stopWords.contains(w)) w,
];

/// A plain string check of [draft] against each of [criteria]: whether it
/// uses the criterion's own words (what panels look for when they score a
/// statement criterion by criterion), some of its key words, or none. It
/// does not judge the quality of the evidence.
List<CoverageRow> coverageCheck(String draft, List<String> criteria) {
  final text = ' ${_normal(draft)} ';
  final stems = {
    for (final w in text.split(' '))
      if (w.isNotEmpty) _stem(w),
  };
  return [
    for (final c in criteria)
      () {
        final phrase = _normal(c);
        if (phrase.isNotEmpty && text.contains(' $phrase ')) {
          return (criterion: c, coverage: Coverage.exact, missingWords: const <String>[]);
        }
        final words = _keyWords(c).toSet().toList();
        final missing = [
          for (final w in words)
            if (!stems.contains(_stem(w))) w,
        ];
        final found = words.length - missing.length;
        final coverage = words.isNotEmpty && found * 2 >= words.length && found > 0
            ? Coverage.partly
            : Coverage.missing;
        return (criterion: c, coverage: coverage, missingWords: missing);
      }(),
  ];
}

/// Words in [text], for the word budget.
int wordCount(String text) => text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
