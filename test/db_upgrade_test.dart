// Every schema upgrade keeps every row (J10 whole-system check). For each
// older version from 1 on, a synthetic database is made: today's schema
// with the tables and columns added after that version taken away, three
// rows in every table, then opened with today's code. Row counts and every
// value in the old columns must be the same afterwards. No real database is
// read.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';

/// What each version added, read from AppDatabase.migration's onUpgrade.
({Map<int, List<String>> tables, Map<int, Map<String, List<String>>> columns}) added(AppDatabase db) => (
  tables: {
    2: [db.learnCards.actualTableName, db.learnReviews.actualTableName],
    4: [db.bridgeStudyPlans.actualTableName, db.bridgeStudyProgress.actualTableName],
    7: [db.learnItems.actualTableName, db.learnCriteria.actualTableName],
    9: [db.learnStories.actualTableName],
    10: [db.learnRounds.actualTableName],
    11: [db.learnJourneys.actualTableName],
    12: [db.learnFactSources.actualTableName, db.learnFacts.actualTableName],
  },
  columns: {
    3: {
      'learn_cards': [db.learnCards.image.name, db.learnCards.audio.name],
    },
    5: {
      'learn_cards': [db.learnCards.ref.name],
    },
    6: {
      'learn_cards': [db.learnCards.plan.name, db.learnCards.retired.name],
    },
    7: {
      'learn_programs': [db.learnPrograms.role.name],
      'learn_topics': [
        db.learnTopics.status.name,
        db.learnTopics.noteId.name,
        db.learnTopics.criteria.name,
        db.learnTopics.tickNote.name,
      ],
    },
    8: {
      'learn_sessions': [db.learnSessions.topicId.name],
      'learn_assessments': [db.learnAssessments.topicId.name],
      'learn_items': [db.learnItems.retired.name],
    },
    9: {
      'learn_assessments': [db.learnAssessments.itemId.name, db.learnAssessments.detail.name],
    },
  },
);

Future<List<String>> _tables(AppDatabase db) async => [
  for (final r
      in await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
          .get())
    r.read<String>('name'),
];

Future<List<String>> _cols(AppDatabase db, String table) async => [
  for (final r in await db.customSelect('PRAGMA table_info("$table")').get()) r.read<String>('name'),
];

/// Three rows in every table, each value made from table, column and row.
Future<void> _fill(AppDatabase db) async {
  for (final t in await _tables(db)) {
    final sql =
        (await db
                .customSelect("SELECT sql FROM sqlite_master WHERE name = ?", variables: [Variable(t)])
                .getSingle())
            .read<String>('sql');
    final info = await db.customSelect('PRAGMA table_info("$t")').get();
    for (var i = 1; i <= 3; i++) {
      final names = <String>[], values = <Variable>[];
      for (final c in info) {
        final name = c.read<String>('name'), type = c.read<String>('type').toUpperCase();
        names.add('"$name"');
        if (RegExp('"$name" IN \\(0, 1\\)').hasMatch(sql)) {
          values.add(Variable<int>(i % 2));
        } else if (type.contains('INT')) {
          values.add(Variable<int>(i * 7));
        } else if (type.contains('REAL')) {
          values.add(Variable<double>(i + 0.5));
        } else if (type.contains('BLOB')) {
          values.add(Variable<Uint8List>(Uint8List.fromList([i, 9])));
        } else {
          values.add(Variable<String>('$t.$name.$i'));
        }
      }
      await db.customInsert(
        'INSERT INTO "$t" (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})',
        variables: values,
      );
    }
  }
}

/// Every row of every table, old columns only, in rowid order.
Future<Map<String, List<String>>> _snapshot(AppDatabase db, Map<String, List<String>> columns) async => {
  for (final e in columns.entries)
    e.key: [
      for (final r
          in await db
              .customSelect('SELECT ${e.value.map((c) => '"$c"').join(', ')} FROM "${e.key}" ORDER BY rowid')
              .get())
        e.value.map((c) => '${r.data[c]}').join('|'),
    ],
};

void main() {
  // A fresh in-memory database is opened beside the upgraded one to compare schemas.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('vidya-upgrade-'));
  tearDown(() => dir.delete(recursive: true));

  test('today\'s schema is version 12', () {
    final db = AppDatabase(NativeDatabase.memory());
    expect(db.schemaVersion, 12);
    addTearDown(db.close);
  });

  for (var from = 1; from < 12; from++) {
    test('version $from upgrades to 12 and keeps every row', () async {
      final file = File('${dir.path}/v$from.db');
      var db = AppDatabase(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      final a = added(db);
      // Back to version [from]: drop indexes, later tables and later columns.
      final indexes = [
        for (final r
            in await db
                .customSelect("SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
                .get())
          r.read<String>('sql'),
      ];
      for (final r
          in await db
              .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
              .get()) {
        await db.customStatement('DROP INDEX "${r.read<String>('name')}"');
      }
      for (var v = 12; v > from; v--) {
        for (final t in a.tables[v] ?? const <String>[]) {
          await db.customStatement('DROP TABLE "$t"');
        }
        for (final e in (a.columns[v] ?? const <String, List<String>>{}).entries) {
          if (!(await _tables(db)).contains(e.key)) continue;
          for (final c in e.value) {
            await db.customStatement('ALTER TABLE "${e.key}" DROP COLUMN "$c"');
          }
        }
      }
      for (final sql in indexes) {
        try {
          await db.customStatement(sql);
        } on Object {
          // Its table or column came later.
        }
      }
      await _fill(db);
      final columns = {for (final t in await _tables(db)) t: await _cols(db, t)};
      final before = await _snapshot(db, columns);
      await db.customStatement('PRAGMA user_version = $from');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      expect((await db.customSelect('PRAGMA user_version').getSingle()).data.values.single, 12);
      final after = await _snapshot(db, columns);
      for (final t in columns.keys) {
        expect(after[t]!.length, 3, reason: '$t row count');
        expect(after[t], before[t], reason: '$t values');
      }
      // Today's tables and columns are all there.
      final fresh = AppDatabase(NativeDatabase.memory());
      await fresh.customSelect('SELECT 1').get();
      for (final t in await _tables(fresh)) {
        expect((await _cols(db, t)).toSet(), (await _cols(fresh, t)).toSet(), reason: t);
      }
      await fresh.close();
      // ignore: avoid_print
      print('v$from -> 12: ${columns.length} tables, ${columns.length * 3} rows kept');
      await db.close();
    });
  }
}
