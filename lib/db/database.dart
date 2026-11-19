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
    LearnSessions,
    LearnAssessments,
    LearnSkills,
    LearnPortfolio,
    LearnNotes,
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
    'learn_sessions',
    'learn_assessments',
    'learn_skills',
    'learn_portfolio',
    'learn_notes',
    'learn_unlocks',
    'learn_cards',
    'learn_reviews',
    'bridge_study_plans',
    'bridge_study_progress',
    'prefs',
  ];

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      for (final sql in _indexes) {
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
    },
  );

  static const _indexes = [
    'CREATE INDEX learn_courses_program ON learn_courses (program_id)',
    'CREATE INDEX learn_topics_course ON learn_topics (course_id)',
    'CREATE INDEX learn_sessions_day ON learn_sessions (day)',
    // Added in version 2; onUpgrade creates these from the fourth on.
    'CREATE INDEX learn_cards_due ON learn_cards (due)',
    'CREATE INDEX learn_reviews_day ON learn_reviews (day)',
  ];
}
