import 'dart:convert';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    LearnPrograms,
    LearnCourses,
    LearnTopics,
    LearnItems,
    LearnCriteria,
    LearnSessions,
    LearnAssessments,
    LearnSkills,
    LearnPortfolio,
    LearnNotes,
    LearnStories,
    LearnRounds,
    LearnUnlocks,
    LearnCards,
    LearnReviews,
    BridgeStudyPlans,
    BridgeStudyProgress,
    Prefs,
    Outbox,
    SyncCursors,
    LocalSettings,
  ],
)
class AppDatabase extends _$AppDatabase with SyncedDatabase {
  AppDatabase(super.e);

  /// Opens Vidya's encrypted database (see [openEncryptedDatabase]).
  AppDatabase.open(String key) : this(openEncryptedDatabase('vidya', key));

  @override
  final syncedTables = const [
    'learn_programs',
    'learn_courses',
    'learn_topics',
    'learn_items',
    'learn_criteria',
    'learn_sessions',
    'learn_assessments',
    'learn_skills',
    'learn_portfolio',
    'learn_notes',
    'learn_stories',
    'learn_rounds',
    'learn_unlocks',
    'learn_cards',
    'learn_reviews',
    'bridge_study_plans',
    'bridge_study_progress',
    'prefs',
  ];

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      for (final sql in [..._indexes, ..._v7Indexes, ..._v8Indexes, ..._v9Indexes, ..._v10Indexes]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(learnCards);
        await m.createTable(learnReviews);
        for (final sql in _indexes.skip(3)) {
          await customStatement(sql);
        }
      } else if (from < 3) {
        // Version 2 cards predate media; a table made above already has them.
        await m.addColumn(learnCards, learnCards.image);
        await m.addColumn(learnCards, learnCards.audio);
      }
      if (from < 4) {
        await m.createTable(bridgeStudyPlans);
        await m.createTable(bridgeStudyProgress);
      }
      if (from < 5) {
        // A plan card's stable id. A cards table made above already has it.
        final have = await customSelect('PRAGMA table_info(learn_cards)').map((r) => r.read<String>('name')).get();
        if (!have.contains(learnCards.ref.name)) await m.addColumn(learnCards, learnCards.ref);
      }
      if (from < 6) {
        // Which plan a card came from, and whether it was retired from it.
        final have = await customSelect('PRAGMA table_info(learn_cards)').map((r) => r.read<String>('name')).get();
        if (!have.contains(learnCards.plan.name)) await m.addColumn(learnCards, learnCards.plan);
        if (!have.contains(learnCards.retired.name)) await m.addColumn(learnCards, learnCards.retired);
        await backfillCardPlans();
      }
      if (from < 7) {
        // Topic pages: a topic's status, note, criteria and tick note; its
        // study items; the program's role and criteria. Nothing is moved:
        // study guides are split into topic notes by the app (see
        // `splitStudyGuides`), so the new rows sync like any other write.
        final programs = await _columns('learn_programs');
        if (!programs.contains(learnPrograms.role.name)) await m.addColumn(learnPrograms, learnPrograms.role);
        final topics = await _columns('learn_topics');
        for (final c in [learnTopics.status, learnTopics.noteId, learnTopics.criteria, learnTopics.tickNote]) {
          if (!topics.contains(c.name)) await m.addColumn(learnTopics, c);
        }
        final tables = await customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map((r) => r.read<String>('name'))
            .get();
        if (!tables.contains(learnItems.actualTableName)) await m.createTable(learnItems);
        if (!tables.contains(learnCriteria.actualTableName)) await m.createTable(learnCriteria);
        for (final sql in _v7Indexes) {
          await customStatement(sql);
        }
      }
      if (from < 8) {
        // Quiz scores and study time per topic; items a plan stopped
        // sending. New columns only, each added once (a table made above
        // already has them).
        final sessions = await _columns('learn_sessions');
        if (!sessions.contains(learnSessions.topicId.name)) await m.addColumn(learnSessions, learnSessions.topicId);
        final tests = await _columns('learn_assessments');
        if (!tests.contains(learnAssessments.topicId.name)) {
          await m.addColumn(learnAssessments, learnAssessments.topicId);
        }
        final items = await _columns('learn_items');
        if (!items.contains(learnItems.retired.name)) await m.addColumn(learnItems, learnItems.retired);
        for (final sql in _v8Indexes) {
          await customStatement(sql);
        }
      }
      if (from < 9) {
        // Interview training: a drill attempt's item and detail on its
        // result, and the story bank. New columns and a new table only.
        final tests = await _columns('learn_assessments');
        for (final c in [learnAssessments.itemId, learnAssessments.detail]) {
          if (!tests.contains(c.name)) await m.addColumn(learnAssessments, c);
        }
        final tables = await customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ).map((r) => r.read<String>('name')).get();
        if (!tables.contains(learnStories.actualTableName)) await m.createTable(learnStories);
        for (final sql in _v9Indexes) {
          await customStatement(sql);
        }
      }
      if (from < 10) {
        // Spoken interview rounds. A new table only: no row is touched.
        final tables = await customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ).map((r) => r.read<String>('name')).get();
        if (!tables.contains(learnRounds.actualTableName)) await m.createTable(learnRounds);
        for (final sql in _v10Indexes) {
          await customStatement(sql);
        }
      }
    },
  );

  Future<List<String>> _columns(String table) =>
      customSelect('PRAGMA table_info($table)').map((r) => r.read<String>('name')).get();

  /// Marks each plan card with the plan it came from, read from the plans
  /// received through sync. Cards from a plan imported as a file get theirs
  /// the next time that plan is imported.
  Future<void> backfillCardPlans() async {
    final rows = await customSelect('SELECT plan FROM bridge_study_plans WHERE deleted = 0').get();
    for (final r in rows) {
      try {
        final j = jsonDecode(r.read<String>('plan'));
        if (j is! Map) continue;
        final program = j['program'] is Map ? j['program'] as Map : j;
        final title = program['title'];
        final cards = j['cards'];
        if (title is! String || cards is! List) continue;
        final ids = [
          for (final c in cards)
            if (c is Map && c['id'] is String && (c['id'] as String).isNotEmpty) c['id'] as String,
        ];
        if (ids.isEmpty) continue;
        await customUpdate(
          "UPDATE learn_cards SET plan = ? WHERE plan = '' AND ref IN (${List.filled(ids.length, '?').join(', ')})",
          variables: [Variable(title.trim().toLowerCase()), for (final id in ids) Variable(id)],
          updates: {learnCards},
        );
      } on FormatException {
        continue;
      }
    }
  }

  static const _indexes = [
    'CREATE INDEX IF NOT EXISTS learn_courses_program ON learn_courses (program_id)',
    'CREATE INDEX IF NOT EXISTS learn_topics_course ON learn_topics (course_id)',
    'CREATE INDEX IF NOT EXISTS learn_sessions_day ON learn_sessions (day)',
    // Added in version 2; onUpgrade creates these from the fourth on. IF NOT
    // EXISTS, so a version 1 upgrade that stopped half way can run again.
    'CREATE INDEX IF NOT EXISTS learn_cards_due ON learn_cards (due)',
    'CREATE INDEX IF NOT EXISTS learn_reviews_day ON learn_reviews (day)',
  ];

  // Added in version 7.
  static const _v7Indexes = [
    'CREATE INDEX IF NOT EXISTS learn_items_topic ON learn_items (topic_id)',
    'CREATE INDEX IF NOT EXISTS learn_criteria_program ON learn_criteria (program_id)',
  ];

  // Added in version 8.
  static const _v8Indexes = [
    'CREATE INDEX IF NOT EXISTS learn_sessions_topic ON learn_sessions (topic_id)',
    'CREATE INDEX IF NOT EXISTS learn_assessments_topic ON learn_assessments (topic_id)',
  ];

  // Added in version 9.
  static const _v9Indexes = [
    'CREATE INDEX IF NOT EXISTS learn_assessments_item ON learn_assessments (item_id)',
  ];

  // Added in version 10.
  static const _v10Indexes = [
    'CREATE INDEX IF NOT EXISTS learn_rounds_program ON learn_rounds (program_id)',
  ];
}
