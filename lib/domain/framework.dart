/// Framework self-assessment (assess plan A6): a plan may carry a
/// leadership or competency framework (the NHS Leadership and Management
/// Framework, the Healthcare Leadership Model, the NHS values …) with its
/// stages, areas and standards. The learner rates each standard at their
/// target stage on a 0–4 scale, with a note, as often as they like; each
/// rating is dated so the page shows a trend per standard.
///
/// Evidence is the learner's interview stories from Udyoga whose `tags`
/// name the standard (Udyoga's evidence bank, plan A4). Tags are matched by
/// framework id and standard id; ids compare in lower case with `-` and `_`
/// the same, so `nhs-lmf` matches Udyoga's `nhs_lmf`.
///
/// A standard is a **gap** when its latest rating is 1 or less, or when no
/// story evidences it. Gaps are listed as "Work on next" with the topics
/// the standard names, and reach job readiness through the standard's
/// `criteria` as weak evidence. A self-rating never covers a criterion:
/// it is the learner's own view, not checked work.
///
/// No 360 and no sharing: ratings are the learner's own and stay in their
/// account.
///
/// Storage needs no database change. The framework a plan sent is a synced
/// pref per program ([frameworkKey]); each rating is an assessment with no
/// course or topic whose detail is [FrameworkRating.encode] (kind
/// "framework-rating"); the target stage the learner picks is a synced pref
/// ([frameworkStageKey]).
library;

import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import '../db/database.dart';
import 'book.dart';
import 'readiness.dart';

// Limits keep a runaway plan small.
const maxStandards = 40, maxStages = 6, maxAreas = 20, maxDescriptor = 1000;
const _maxTitle = 200, _maxLinks = 20, _maxNote = 1000;

/// The rating scale, 0–4, in the words the page shows.
const ratingLabels = ['Not yet', 'Starting', 'Developing', 'Secure', 'Strong'];

/// What each rating means, for the scale's help text.
const ratingMeanings = [
  'I have not done this yet at this stage.',
  'I have tried it once or twice, with help.',
  'I do it sometimes, not yet reliably.',
  'I do it reliably and can give examples.',
  'I do it well and help others do it.',
];

/// The highest rating.
const ratingMax = 4;

/// A rating at or below this is a gap.
const gapAtOrBelow = 1;

/// Lower case, `-` read as `_`: how framework and standard ids compare.
String normId(String id) => id.trim().toLowerCase().replaceAll('-', '_');

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

typedef FrameworkStage = ({String id, String name});
typedef FrameworkArea = ({String id, String title});

/// One standard: its descriptor per stage, the plan criteria it feeds and
/// the topics (titles or ids) that teach it.
class FrameworkStandard {
  const FrameworkStandard({
    required this.id,
    required this.title,
    this.area = '',
    this.descriptors = const {},
    this.criteria = const [],
    this.topics = const [],
  });
  final String id, title, area;

  /// Stage id to what the standard looks like at that stage.
  final Map<String, String> descriptors;

  /// Plan criterion ids ("c1") a gap here makes weak.
  final List<String> criteria;

  /// Topic titles or ids that teach it.
  final List<String> topics;

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    if (area.isNotEmpty) 'area': area,
    if (descriptors.isNotEmpty) 'descriptors': descriptors,
    if (criteria.isNotEmpty) 'criteria': criteria,
    if (topics.isNotEmpty) 'topics': topics,
  };
}

/// A framework as a plan sends it (format 3, `framework`).
class Framework {
  const Framework({
    required this.id,
    required this.name,
    required this.stages,
    required this.targetStage,
    required this.standards,
    this.status = 'draft',
    this.areas = const [],
  });
  final String id, name;

  /// `draft` (the wording may change: shown with a banner) or `final`.
  final String status;
  final List<FrameworkStage> stages;
  final String targetStage;
  final List<FrameworkArea> areas;
  final List<FrameworkStandard> standards;

  bool get isDraft => status != 'final';

  FrameworkStage? stage(String id) => stages.where((s) => s.id == id).firstOrNull;

  String areaTitle(String id) => areas.where((a) => a.id == id).firstOrNull?.title ?? id;

  FrameworkStandard? standard(String id) => standards.where((s) => normId(s.id) == normId(id)).firstOrNull;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'status': status,
    'stages': [
      for (final s in stages) {'id': s.id, 'name': s.name},
    ],
    'targetStage': targetStage,
    if (areas.isNotEmpty)
      'areas': [
        for (final a in areas) {'id': a.id, 'title': a.title},
      ],
    'standards': [for (final s in standards) s.toJson()],
  };

  String encode() => jsonEncode(toJson());

  /// Reads a plan's `framework` block. Unknown or empty fields are dropped,
  /// text is clipped; null when it has no id, name or standard. Throws a
  /// [FormatException] when a list is over its limit.
  static Framework? fromJson(Object? v) {
    if (v is! Map) return null;
    final id = _str(v['id'], 60);
    final name = _str(v['name'] ?? v['title'], _maxTitle);
    if (id.isEmpty || name.isEmpty) return null;

    final stages = <FrameworkStage>[];
    for (final s in _list(v['stages'], maxStages, 'framework stages')) {
      final m = s is Map ? s : {'id': s, 'name': s};
      final sid = _str(m['id'], 40);
      if (sid.isEmpty || stages.any((x) => x.id == sid)) continue;
      final sname = _str(m['name'], _maxTitle);
      stages.add((id: sid, name: sname.isNotEmpty ? sname : 'Stage $sid'));
    }

    final areas = <FrameworkArea>[];
    for (final a in _list(v['areas'], maxAreas, 'framework areas')) {
      if (a is! Map) continue;
      final aid = _str(a['id'], 60), title = _str(a['title'] ?? a['name'], _maxTitle);
      if (aid.isEmpty || areas.any((x) => x.id == aid)) continue;
      areas.add((id: aid, title: title.isNotEmpty ? title : aid));
    }

    final standards = <FrameworkStandard>[];
    final seen = <String>{};
    for (final s in _list(v['standards'], maxStandards, 'framework standards')) {
      if (s is! Map) continue;
      final sid = _str(s['id'], 60).replaceAll(',', ' ');
      final title = _str(s['title'], _maxTitle);
      if (sid.isEmpty || title.isEmpty || !seen.add(normId(sid))) continue;
      final raw = s['descriptors'];
      final descriptors = <String, String>{
        if (raw is Map)
          for (final MapEntry(:key, :value) in raw.entries)
            if (_str(key, 40) case final k when k.isNotEmpty)
              if (_str(value, maxDescriptor) case final d when d.isNotEmpty) k: d,
      };
      standards.add(
        FrameworkStandard(
          id: sid,
          title: title,
          area: _str(s['area'], 60),
          descriptors: descriptors,
          criteria: [
            for (final c in _list(s['criteria'], _maxLinks, 'criteria in “$title”'))
              if (_str(c, 60).replaceAll(',', ' ') case final r when r.isNotEmpty) r,
          ],
          topics: [
            for (final t in _list(s['topics'], _maxLinks, 'topics in “$title”'))
              if (_str(t, _maxTitle) case final r when r.isNotEmpty) r,
          ],
        ),
      );
    }
    if (standards.isEmpty) return null;

    // No stages given: the stages the descriptors name, else one stage.
    if (stages.isEmpty) {
      final keys = {for (final s in standards) ...s.descriptors.keys}.toList()..sort();
      for (final k in keys.take(maxStages)) {
        stages.add((id: k, name: 'Stage $k'));
      }
      if (stages.isEmpty) stages.add((id: '1', name: 'Stage 1'));
    }
    // Descriptors for stages the framework does not have are dropped.
    final stageIds = {for (final s in stages) s.id};
    final kept = [
      for (final s in standards)
        FrameworkStandard(
          id: s.id,
          title: s.title,
          area: s.area,
          criteria: s.criteria,
          topics: s.topics,
          descriptors: {
            for (final e in s.descriptors.entries)
              if (stageIds.contains(e.key)) e.key: e.value,
          },
        ),
    ];
    final target = _str(v['targetStage'], 40);
    return Framework(
      id: id,
      name: name,
      status: _str(v['status'], 10).toLowerCase() == 'final' ? 'final' : 'draft',
      stages: stages,
      targetStage: stageIds.contains(target) ? target : stages.first.id,
      areas: areas,
      standards: kept,
    );
  }

  static Framework? decode(String s) {
    if (s.isEmpty) return null;
    try {
      return fromJson(jsonDecode(s));
    } on FormatException {
      return null;
    }
  }
}

// ---- ratings ----

/// The detail kind of a self-rating.
const frameworkRatingKind = 'framework-rating';

/// One dated self-rating of a standard, kept as an assessment's detail.
class FrameworkRating {
  const FrameworkRating({
    required this.framework,
    required this.standard,
    required this.stage,
    required this.rating,
    this.note = '',
  });
  final String framework, standard, stage;

  /// 0–4 (see [ratingLabels]).
  final int rating;
  final String note;

  String get label => ratingLabels[rating];

  String encode() => jsonEncode({
    'kind': frameworkRatingKind,
    'framework': framework,
    'standard': standard,
    'stage': stage,
    'rating': rating,
    if (note.isNotEmpty) 'note': note,
  });

  static FrameworkRating? parse(String detail) {
    if (detail.isEmpty) return null;
    try {
      final j = jsonDecode(detail);
      if (j is! Map || j['kind'] != frameworkRatingKind) return null;
      final r = j['rating'];
      if (r is! num) return null;
      return FrameworkRating(
        framework: _str(j['framework'], 60),
        standard: _str(j['standard'], 60),
        stage: _str(j['stage'], 40),
        rating: r.round().clamp(0, ratingMax),
        note: _str(j['note'], _maxNote),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Whether [a] is a framework self-rating (not a quiz or test result).
bool isFrameworkRating(Assessment a) => FrameworkRating.parse(a.detail) != null;

/// A rating with its day, oldest first in a history.
typedef DatedRating = ({String day, FrameworkRating rating});

/// The change from the previous rating to the latest: positive up, negative
/// down, 0 the same; null with fewer than two ratings.
int? ratingTrend(List<DatedRating> history) =>
    history.length < 2 ? null : history.last.rating.rating - history[history.length - 2].rating.rating;

/// The ratings a trend chart shows: the last [trendPoints], oldest first.
const trendPoints = 12;
List<DatedRating> trendWindow(List<DatedRating> history) =>
    history.length <= trendPoints ? history : history.sublist(history.length - trendPoints);

/// The trend in words, '' with fewer than two ratings.
String trendText(List<DatedRating> history) => switch (ratingTrend(history)) {
  null => '',
  0 => 'Same as last time',
  final d when d > 0 => 'Up $d since ${niceDate(history[history.length - 2].day)}',
  final d => 'Down ${-d} since ${niceDate(history[history.length - 2].day)}',
};

// ---- evidence ----

/// One framework item a story is tagged with (Udyoga's `StoryTag`).
typedef StoryTagRef = ({String framework, String item, String title});

/// An interview story from Udyoga's plan cards, with its tags.
typedef TaggedStory = ({String ref, String title, String happened, List<StoryTagRef> tags});

/// The tagged stories in a plan's JSON: its `cards` that carry `tags`
/// (Udyoga adds them, and `happened`, to its story cards). Cards without
/// tags, and anything unreadable, are skipped.
List<TaggedStory> taggedStoriesInPlan(String planJson) {
  Object? j;
  try {
    j = jsonDecode(planJson);
  } on FormatException {
    return const [];
  }
  return j is Map ? taggedStoriesInCards(j['cards']) : const [];
}

/// The tagged stories among a plan's `cards` (see [taggedStoriesInPlan]).
/// With [titleAsIs] the `front` is the title as written (cards Vidya kept
/// itself, see [encodeTaggedStories]).
List<TaggedStory> taggedStoriesInCards(Object? cards, {bool titleAsIs = false}) {
  if (cards is! List) return const [];
  final out = <TaggedStory>[];
  for (final c in cards.take(5000)) {
    if (c is! Map || c['tags'] is! List) continue;
    final tags = <StoryTagRef>[
      for (final t in (c['tags'] as List).take(100))
        if (t case {'framework': final String f, 'item': final String i} when f.isNotEmpty && i.isNotEmpty)
          (framework: f, item: i, title: _str(t['title'], _maxTitle)),
    ];
    if (tags.isEmpty) continue;
    final front = _str(c['front'], _maxTitle * 2);
    // "Tell your story: Title (competencies)" reads as the title.
    final title = titleAsIs
        ? front
        : front.replaceFirst(RegExp(r'^Tell your story:\s*'), '').replaceFirst(RegExp(r'\s*\([^)]*\)$'), '');
    final happened = _str(c['happened'], 10);
    out.add((
      ref: _str(c['id'], 200),
      title: title.isNotEmpty ? title : front,
      happened: isValidIsoDate(happened) ? happened : '',
      tags: tags,
    ));
  }
  return out;
}

/// Tagged stories as JSON in the plan's own card shape, so the same reader
/// takes them back ([decodeTaggedStories]).
String encodeTaggedStories(List<TaggedStory> stories) => jsonEncode({
  'cards': [
    for (final s in stories)
      {
        'id': s.ref,
        'front': s.title,
        if (s.happened.isNotEmpty) 'happened': s.happened,
        'tags': [
          for (final t in s.tags) {'framework': t.framework, 'item': t.item, 'title': t.title},
        ],
      },
  ],
});

List<TaggedStory> decodeTaggedStories(String json) {
  if (json.isEmpty) return const [];
  try {
    final j = jsonDecode(json);
    return j is Map ? taggedStoriesInCards(j['cards'], titleAsIs: true) : const [];
  } on FormatException {
    return const [];
  }
}

/// Whether [tag] names [s] of [f]: the same framework id, and the same
/// standard id (or, failing that, the same title).
bool tagMatches(StoryTagRef tag, Framework f, FrameworkStandard s) =>
    normId(tag.framework) == normId(f.id) &&
    (normId(tag.item) == normId(s.id) ||
        (tag.title.isNotEmpty && tag.title.trim().toLowerCase() == s.title.trim().toLowerCase()));

/// The stories that evidence [s], each once.
List<TaggedStory> evidenceFor(Framework f, FrameworkStandard s, List<TaggedStory> stories) {
  final seen = <String>{};
  return [
    for (final st in stories)
      if (st.tags.any((t) => tagMatches(t, f, s)) && seen.add(st.ref.isNotEmpty ? st.ref : st.title)) st,
  ];
}

// ---- the view ----

/// Why a standard is a gap.
enum GapReason {
  lowRating('Rated 1 or less'),
  noEvidence('No story evidences it yet');

  const GapReason(this.label);
  final String label;
}

/// One standard on the page.
class StandardView {
  const StandardView({required this.standard, required this.history, required this.evidence});
  final FrameworkStandard standard;

  /// Ratings at the target stage, oldest first.
  final List<DatedRating> history;
  final List<TaggedStory> evidence;

  DatedRating? get latest => history.lastOrNull;

  List<GapReason> get gapReasons => [
    if (latest case final l? when l.rating.rating <= gapAtOrBelow) GapReason.lowRating,
    if (evidence.isEmpty) GapReason.noEvidence,
  ];

  /// Rated 1 or less, or with no evidence.
  bool get isGap => gapReasons.isNotEmpty;
}

/// The framework page for one program at one stage.
class FrameworkView {
  const FrameworkView({required this.framework, required this.stage, required this.standards});
  final Framework framework;

  /// The target stage shown (the learner's pick, else the plan's).
  final String stage;
  final List<StandardView> standards;

  /// "Work on next": gaps, unrated-and-low first, in framework order.
  List<StandardView> get gaps => [
    for (final s in standards)
      if (s.isGap) s,
  ];
}

/// Builds the page from rows already read: [ratings] are the program's
/// framework rating rows (any order), [stories] the tagged stories.
FrameworkView buildFrameworkView(
  Framework f, {
  required String stage,
  required List<Assessment> ratings,
  required List<TaggedStory> stories,
}) {
  final rows =
      [
        for (final a in ratings)
          if (FrameworkRating.parse(a.detail) case final r?
              when !a.deleted && normId(r.framework) == normId(f.id) && r.stage == stage)
            (a, r),
      ]..sort((x, y) {
        final d = x.$1.day.compareTo(y.$1.day);
        return d != 0 ? d : x.$1.hlc.compareTo(y.$1.hlc);
      });
  return FrameworkView(
    framework: f,
    stage: stage,
    standards: [
      for (final s in f.standards)
        StandardView(
          standard: s,
          history: [
            for (final (a, r) in rows)
              if (normId(r.standard) == normId(s.id)) (day: a.day, rating: r),
          ],
          evidence: evidenceFor(f, s, stories),
        ),
    ],
  );
}

/// Readiness evidence from the framework, by plan criterion ref: one piece
/// per rated standard that names the criterion. A gap is [EvidenceWeight.low]
/// (it makes the row weak), any other rating [EvidenceWeight.unchecked]; a
/// self-rating is never strong, so it never covers a criterion on its own.
Map<String, List<Evidence>> frameworkReadiness(FrameworkView v) {
  final out = <String, List<Evidence>>{};
  for (final s in v.standards) {
    final l = s.latest;
    if (s.standard.criteria.isEmpty || l == null) continue;
    final e = Evidence(
      kind: EvidenceKind.framework,
      title: 'Self-rating: ${s.standard.title}',
      detail: [
        '${l.rating.label} (${l.rating.rating}/$ratingMax) on ${niceDate(l.day)}',
        if (s.isGap) 'gap: ${s.gapReasons.map((r) => r.label.toLowerCase()).join(', ')}',
      ].join(' · '),
      weight: s.isGap ? EvidenceWeight.low : EvidenceWeight.unchecked,
      day: l.day,
      id: s.standard.id,
    );
    for (final c in s.standard.criteria) {
      (out[c] ??= []).add(e);
    }
  }
  return out;
}

// ---- reads and writes ----

/// The synced pref holding the framework a plan sent for a program.
String frameworkKey(String programId) => 'vidya.framework.$programId';

/// The synced pref holding the stage the learner rates at.
String frameworkStageKey(String programId) => 'vidya.frameworkStage.$programId';

/// The synced pref holding the tagged story cards a plan imported for a
/// program carried (their `tags` and `happened`), so a plan imported from
/// a file keeps them as one shared by Udyoga does. No database change.
String storyTagsKey(String programId) => 'vidya.storyTags.$programId';

/// The rating's item id, so a standard's ratings can be read together.
String frameworkItemId(String programId, String standardId) => 'framework.$programId.${normId(standardId)}';

extension FrameworkBook on LearningBook {
  Future<String> _pref(String key) async {
    final row = await (db.select(db.prefs)..where((p) => p.id.equals(key))).getSingleOrNull();
    return row == null || row.deleted ? '' : row.value;
  }

  Future<void> _setPref(String key, String value) =>
      save(db.prefs, PrefsCompanion.insert(id: key, value: value, deleted: const Value(false)), key);

  /// The framework of [programId], or null when its plans sent none.
  Future<Framework?> framework(String programId) async =>
      Framework.decode(await _pref(frameworkKey(programId)));

  /// Saves the framework a plan sent; the learner's ratings stay.
  Future<void> saveFramework(String programId, Framework f) async {
    final json = f.encode();
    if (await _pref(frameworkKey(programId)) != json) await _setPref(frameworkKey(programId), json);
  }

  /// The stage shown: the learner's pick when the framework still has it,
  /// else the plan's target stage.
  Future<String> frameworkStage(String programId, Framework f) async {
    final picked = await _pref(frameworkStageKey(programId));
    return f.stage(picked) != null ? picked : f.targetStage;
  }

  Future<void> setFrameworkStage(String programId, String stage) =>
      _setPref(frameworkStageKey(programId), stage);

  /// Saves a dated self-rating of [standard] at [stage]. Returns its id.
  Future<String> rateStandard(
    String programId,
    Framework f,
    FrameworkStandard standard, {
    required String stage,
    required int rating,
    String note = '',
    required String today,
  }) async {
    final id = newId();
    final r = FrameworkRating(
      framework: f.id,
      standard: standard.id,
      stage: stage,
      rating: rating.clamp(0, ratingMax),
      note: note.trim().length > _maxNote ? note.trim().substring(0, _maxNote) : note.trim(),
    );
    await save(
      db.learnAssessments,
      LearnAssessmentsCompanion.insert(
        id: id,
        itemId: Value(frameworkItemId(programId, standard.id)),
        title: standard.title,
        day: today,
        score: r.rating.toDouble(),
        max: Value(ratingMax.toDouble()),
        detail: Value(r.encode()),
        deleted: const Value(false),
      ),
      id,
    );
    return id;
  }

  /// Keeps the tagged story cards an imported plan carried for
  /// [programId]. A whole plan replaces what an earlier one left; one part
  /// of a long plan adds to it (a story with the same id is replaced).
  Future<void> saveTaggedStories(String programId, List<TaggedStory> stories, {bool whole = true}) async {
    final key = storyTagsKey(programId);
    final before = whole ? const <TaggedStory>[] : decodeTaggedStories(await _pref(key));
    String id(TaggedStory s) => s.ref.isNotEmpty ? s.ref : s.title;
    final fresh = {for (final s in stories) id(s)};
    final next = [
      for (final s in before)
        if (!fresh.contains(id(s))) s,
      ...stories,
    ];
    final json = next.isEmpty ? '' : encodeTaggedStories(next);
    if (await _pref(key) != json) await _setPref(key, json);
  }

  /// The tagged stories: from every plan Udyoga shares, and from the plans
  /// imported here (from a file too). Each once, by its card id.
  Future<List<TaggedStory>> taggedStories() async {
    final plans = await (db.select(db.bridgeStudyPlans)..where((p) => p.deleted.not())).get();
    final kept = await (db.select(
      db.prefs,
    )..where((p) => p.deleted.not() & p.id.like('${storyTagsKey('')}%'))).get();
    final seen = <String>{};
    return [
      for (final p in plans)
        for (final s in taggedStoriesInPlan(p.plan))
          if (seen.add(s.ref.isNotEmpty ? s.ref : s.title)) s,
      for (final p in kept)
        for (final s in decodeTaggedStories(p.value))
          if (seen.add(s.ref.isNotEmpty ? s.ref : s.title)) s,
    ];
  }

  /// The framework page for [programId], null when it has no framework.
  Future<FrameworkView?> frameworkView(String programId) async {
    final f = await framework(programId);
    if (f == null) return null;
    final prefix = 'framework.$programId.';
    final ratings = await (db.select(
      db.learnAssessments,
    )..where((a) => a.deleted.not() & a.itemId.like('$prefix%'))).get();
    return buildFrameworkView(
      f,
      stage: await frameworkStage(programId, f),
      ratings: ratings,
      stories: await taggedStories(),
    );
  }
}
