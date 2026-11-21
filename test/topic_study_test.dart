import 'dart:convert';
import 'dart:io';

import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/db/database.dart';
import 'package:vidya/domain/book.dart';
import 'package:vidya/domain/curriculum.dart';
import 'package:vidya/domain/study_items.dart';

import 'support.dart';

const today = '2026-11-21';

/// A made-up format 2 plan: one course, two topics, criteria.
Map<String, Object?> v2Plan() => {
  'format': 'vidya-curriculum',
  'version': 2,
  'program': {'title': 'Pottery teacher', 'goal': 'Teach a beginners class'},
  'role': 'Pottery tutor',
  'criteria': [
    {'id': 'c1', 'text': 'Explain centering to a beginner', 'essential': true, 'source': 'advert'},
    {'id': 'c2', 'text': 'Kiln safety', 'essential': false, 'shown': true},
    {'text': 'No id here'},
  ],
  'courses': [
    {
      'title': 'Wheel basics',
      'topics': [
        {
          'title': 'Centering',
          'minutes': 40,
          'details': 'Brace your arms.',
          'criteria': ['c1'],
          'items': [
            {
              'type': 'video',
              'title': 'Centering in five minutes',
              'url': 'https://www.youtube.com/watch?v=example',
              'source': 'Example channel',
              'licence': 'Standard YouTube',
              'minutes': 5,
              'required': true,
            },
            {
              'type': 'practice',
              'title': 'Center 1 kg of clay three times',
              'instructions': 'Use a timer.',
              'doneWhen': 'The clay runs true',
              'required': true,
            },
            {'type': 'docs', 'title': 'Wheel guide', 'url': 'https://example.org/wheel'},
          ],
          'quiz': [
            {
              'question': 'Which hand braces?',
              'options': ['Left', 'Right'],
              'answer': 1,
            },
            {'question': 'What runs true?', 'answer': 'The clay', 'kind': 'short'},
            {'question': 'Skipped: no answer'},
          ],
          'drills': [
            {'question': 'How would you teach centering?', 'criterion': 'c1', 'rubric': 'Steps in order'},
          ],
        },
        {
          'title': 'Trimming',
          'resources': ['Trimming tools — https://example.org/trim'],
        },
      ],
    },
  ],
};

void main() {
  late LearningBook book;
  late AppDatabase db;
  setUp(() async {
    db = memoryDatabase();
    book = LearningBook(await Store.open(db));
  });
  tearDown(() => db.close());

  Future<List<StudyItem>> itemsOf(String topicTitle) async {
    final t = await (db.select(db.learnTopics)..where((t) => t.title.equals(topicTitle))).getSingle();
    return (db.select(db.learnItems)
          ..where((i) => i.topicId.equals(t.id) & i.deleted.not())
          ..orderBy([(i) => OrderingTerm.asc(i.ord)]))
        .get();
  }

  Future<Topic> topic(String title) => (db.select(db.learnTopics)..where((t) => t.title.equals(title))).getSingle();

  group('format 2 plans', () {
    test('items, quiz, drills and criteria are read, with types tidied', () {
      final p = parseCurriculum(jsonEncode(v2Plan()));
      expect(p.role, 'Pottery tutor');
      expect(p.criteria.map((c) => (c.id, c.essential, c.shown)), [
        ('c1', true, null),
        ('c2', false, true),
        ('', false, null),
      ]);
      final t = p.courses.single.topics.first;
      expect(t.criteria, ['c1']);
      expect(t.items.map((i) => i.type), ['video', 'practice task', 'article', 'quiz', 'interview drill']);
      expect(t.items.first.required, isTrue);
      expect(t.items[2].required, isFalse);
      expect(jsonDecode(t.items[1].content), {'instructions': 'Use a timer.', 'doneWhen': 'The clay runs true'});
      final quiz = jsonDecode(t.items[3].content)['questions'] as List;
      expect(quiz, hasLength(2), reason: 'a question with no answer is left out');
      expect(quiz.first, {
        'question': 'Which hand braces?',
        'kind': 'choice',
        'options': ['Left', 'Right'],
        'answer': 'Right',
      });
      expect(jsonDecode(t.items[4].content)['criterion'], 'c1');
      expect(p.itemCount, 5);
    });

    test('limits hold: too many items in a topic, or a plan from a newer Vidya', () {
      final plan = v2Plan();
      final topic = ((plan['courses'] as List).first as Map)['topics'] as List;
      (topic.first as Map)['items'] = List.filled(51, {'type': 'note', 'title': 'x'});
      expect(
        () => parseCurriculum(jsonEncode(plan)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Too many items'))),
      );
      expect(
        () => parseCurriculum(jsonEncode({...v2Plan(), 'version': 3})),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('newer Vidya'))),
      );
    });

    test('import makes items, criteria, the role and a topic note; again changes nothing', () async {
      final p = parseCurriculum(jsonEncode(v2Plan()));
      final r = await book.importCurriculum(p, today: today);
      expect((r.topics, r.items, r.criteria), (2, 6, 3));
      final program = (await db.select(db.learnPrograms).get()).single;
      expect(program.role, 'Pottery tutor');
      final crit = await db.select(db.learnCriteria).get();
      expect(crit.map((c) => c.ref), ['c1', 'c2', 'text|no id here']);
      expect(crit.every((c) => c.programId == program.id), isTrue);

      final centering = await topic('Centering');
      expect(centering.criteria, 'c1');
      final items = await itemsOf('Centering');
      expect(items.map((i) => i.title).first, 'Centering in five minutes');
      expect(items.first.id, planItemId(centering.id, items.first.ref));
      expect(items.map((i) => i.ord), [0, 1, 2, 3, 4]);
      // v1 resources on a format 2 plan still become link items.
      final trim = await itemsOf('Trimming');
      expect(trim.single.type, 'article');
      expect(trim.single.url, 'https://example.org/trim');

      // Each topic with details or resources has its own note from the plan,
      // which earns nothing until the learner writes in it.
      final note = await (db.select(db.learnNotes)..where((n) => n.id.equals(centering.noteId))).getSingle();
      expect(note.body, 'Brace your arms.');
      expect(hasPlanNoteTag(note), isTrue);
      final s = await book.stats(today);
      expect(s.notes.map((n) => n.title), ['Wheel basics — study guide']);

      final again = await book.importCurriculum(p, today: today);
      expect((again.topics, again.items, again.criteria), (0, 0, 0));
      expect(await db.select(db.learnItems).get(), hasLength(6));
      expect(await db.select(db.learnNotes).get(), hasLength(3));
    });

    test('a re-sent plan updates items and criteria in place and keeps the learner\'s work', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(v2Plan())), today: today);
      var items = await itemsOf('Centering');
      final video = items.first;
      await book.saveItem(video.copyWith(stoppedAt: '2:10'));
      await book.setItemDone((await itemsOf('Centering')).first, true, today: today);
      await book.remove(db.learnItems, items[2].id); // the learner deletes the docs link

      final plan = jsonDecode(jsonEncode(v2Plan())) as Map<String, Object?>;
      final t = (((plan['courses'] as List).first as Map)['topics'] as List).first as Map;
      final list = t['items'] as List;
      list[0] = {...list[0] as Map, 'minutes': 7, 'title': 'Centering, five minutes'};
      list.add({'type': 'book', 'title': 'The potter\'s book', 'required': false});
      (plan['criteria'] as List)[0] = {'id': 'c1', 'text': 'Teach centering', 'essential': true};
      final r = await book.importCurriculum(parseCurriculum(jsonEncode(plan)), today: today);
      expect(r.items, 1);

      items = await itemsOf('Centering');
      final again = items.first;
      expect((again.id, again.title, again.minutes), (video.id, 'Centering, five minutes', 7));
      expect((again.done, again.stoppedAt), (today, '2:10'));
      expect(items.any((i) => i.title == 'Wheel guide'), isFalse, reason: 'deleted stays deleted');
      expect(items.last.title, 'The potter\'s book');
      final c1 = await (db.select(db.learnCriteria)..where((c) => c.ref.equals('c1'))).getSingle();
      expect(c1.body, 'Teach centering');
      expect(await db.select(db.learnCriteria).get(), hasLength(3));
    });
  });

  group('format 1 plans and Udyoga', () {
    test('a format 1 plan still imports; resources become typed link items', () async {
      final p = parseCurriculum(
        jsonEncode({
          'format': 'vidya-curriculum',
          'version': 1,
          'program': {'title': 'Old plan'},
          'courses': [
            {
              'title': 'A',
              'topics': [
                {
                  'title': 'One',
                  'details': 'Facts.',
                  'resources': [
                    {'title': 'Talk', 'url': 'https://youtu.be/abc'},
                    'https://example.org/page',
                    'A book on the shelf',
                  ],
                },
                'Two',
              ],
            },
          ],
        }),
      );
      final r = await book.importCurriculum(p, today: today);
      expect((r.courses, r.topics, r.items, r.notes), (1, 2, 3, 1));
      final items = await itemsOf('One');
      expect(items.map((i) => (i.type, i.title, i.url)), [
        ('video', 'Talk', 'https://youtu.be/abc'),
        ('article', 'https://example.org/page', 'https://example.org/page'),
        ('note', 'A book on the shelf', ''),
      ]);
      expect((await topic('Two')).noteId, '', reason: 'nothing to put in a note');
    });

    test('Udyoga\'s role plan imports with its criteria, role and items', () async {
      // Written by Udyoga's tests (test/fixtures/udyoga-role-plan.json there).
      final p = parseCurriculum(File('test/fixtures/udyoga-role-plan.json').readAsStringSync());
      expect(p.role, 'IT Trainer');
      expect(p.criteria, hasLength(4));
      expect(p.criteria.last.shown, isNull);
      final r = await book.importCurriculum(p, today: today);
      expect((r.courses, r.topics, r.items, r.criteria), (2, 5, 4, 4));
      final t = await topic('Formal teaching qualification');
      expect(criteriaRefs(t), ['a1']);
      final items = await itemsOf('Formal teaching qualification');
      expect((items.single.type, items.single.required, items.single.source), ('practice task', true, 'AI'));
      expect(tickNeedsNote(items), isTrue);
      expect(await itemsOf('online moderation techniques'), isEmpty);
      final a1 = await (db.select(db.learnCriteria)..where((c) => c.ref.equals('a1'))).getSingle();
      expect(
        (a1.body, a1.essential, a1.kind, a1.source, a1.shown),
        ('Teaching qualification', true, 'requirement', 'AI', null),
      );
    });
  });

  group('topics', () {
    test('status, earned tick and the tick note', () async {
      await book.importCurriculum(parseCurriculum(jsonEncode(v2Plan())), today: today);
      var t = await topic('Centering');
      var items = await itemsOf('Centering');
      expect(topicStatus(t, items), TopicStatus.notStarted);
      expect(topicEarned(items), isFalse);
      await book.setItemDone(items.first, true, today: today);
      items = await itemsOf('Centering');
      expect(topicStatus(t, items), TopicStatus.studying);
      await book.setTopicStatus(t, 'review');
      t = await topic('Centering');
      expect(topicStatus(t, items), TopicStatus.review);
      await book.setItemDone(items[1], true, today: today);
      items = await itemsOf('Centering');
      expect((topicEarned(items), tickNeedsNote(items)), (true, false));

      await book.setTopicDone(t, true, today: today, note: 'Did it at work');
      t = await topic('Centering');
      expect((t.done, t.tickNote, t.status), (today, 'Did it at work', 'review'));
      expect(topicStatus(t, items), TopicStatus.done);
      expect((await book.stats(today)).topicsDone, 1);
      await book.setTopicDone(t, false, today: today);
      t = await topic('Centering');
      expect((t.done, t.tickNote), (null, ''));
    });

    test('items are added, moved and deleted; a topic note drops the plan tag when saved', () async {
      final cid = await book.addCourse('C', today: today);
      final tid = await book.addTopic(cid, 'T');
      await book.addItem(tid, 'video', 'First');
      await book.addItem(tid, 'article', 'Second');
      final third = await book.addItem(tid, 'note', 'Third', takeaway: 'My words');
      var items = await itemsOf('T');
      expect(items.map((i) => i.title), ['First', 'Second', 'Third']);
      await book.moveItem(items.last, -2);
      items = await itemsOf('T');
      expect(items.map((i) => i.title), ['Third', 'First', 'Second']);
      expect(items.first.id, third);

      var t = await topic('T');
      final before = (await book.stats(today)).notes.length;
      await book.saveTopicNote(t, 'C', '# My notes', today: today);
      t = await topic('T');
      expect(t.noteId, topicNoteId(tid));
      final note = await (db.select(db.learnNotes)..where((n) => n.id.equals(t.noteId))).getSingle();
      expect((note.title, note.body, hasPlanNoteTag(note)), ('C — T', '# My notes', false));
      expect((await book.stats(today)).notes.length, before + 1);

      await book.removeTopic(tid);
      expect(await (db.select(db.learnItems)..where((i) => i.deleted.not())).get(), isEmpty);
    });
  });

  group('splitting old study guides', () {
    // A course as format 1 plans left it before topic pages: topics with
    // only a title, and one study-guide note holding the rest.
    Future<String> legacy() async {
      final pid = await book.addProgram('Old, plan', '', today: '2026-11-01');
      final cid = await book.addCourse('Glazes', today: '2026-11-01', programId: pid);
      await book.addTopic(cid, 'Mixing (dry)');
      await book.addTopic(cid, 'Firing');
      await book.addTopic(cid, 'Untouched');
      const course = PlanCourse(
        'Glazes',
        summary: 'All about glazes.',
        topics: [
          PlanTopic(
            'Mixing (dry)',
            minutes: 20,
            details: 'Wear a mask.\n\n- a bullet in the details',
            resources: ['Mixing video — https://www.youtube.com/watch?v=x', 'Plain title'],
          ),
          PlanTopic('Firing', minutes: 60, details: 'Cone 6.'),
          PlanTopic('Gone topic', details: 'No topic has this title any more.'),
        ],
      );
      await book.saveNote(
        'Glazes — study guide',
        courseGuideMarkdown(course),
        'Old  plan, study guide',
        today: '2026-11-01',
      );
      return cid;
    }

    test('each topic gets its section as a note and its links as items; the guide stays', () async {
      await legacy();
      final guide = (await db.select(db.learnNotes).get()).single;
      final xpBefore = (await book.stats(today)).xp;
      expect(await book.splitStudyGuides(today: today), 2);

      final mixing = await topic('Mixing (dry)');
      final note = await (db.select(db.learnNotes)..where((n) => n.id.equals(mixing.noteId))).getSingle();
      expect(note.title, 'Glazes — Mixing (dry)');
      expect(note.body, startsWith('Wear a mask.'));
      expect(note.body, contains('- Plain title'));
      expect(note.tags, 'Old  plan, topic note, from plan');
      final items = await itemsOf('Mixing (dry)');
      expect(items.map((i) => (i.type, i.title)), [('video', 'Mixing video'), ('note', 'Plain title')]);
      expect((await topic('Firing')).noteId, isNotEmpty);
      expect(await itemsOf('Firing'), isEmpty);
      expect((await topic('Untouched')).noteId, '');
      final after = await (db.select(db.learnNotes)..where((n) => n.id.equals(guide.id))).getSingle();
      expect((after.body, after.updated), (guide.body, guide.updated));
      expect((await book.stats(today)).xp, xpBefore, reason: 'plan text earns nothing');

      // Again, or on another device: nothing new.
      expect(await book.splitStudyGuides(today: today), 0);
      expect(await db.select(db.learnNotes).get(), hasLength(3));
      expect(await db.select(db.learnItems).get(), hasLength(2));
    });

    test('a topic note the learner deleted is not made again', () async {
      await legacy();
      await book.splitStudyGuides(today: today);
      final firing = await topic('Firing');
      await book.remove(db.learnNotes, firing.noteId);
      await book.save(db.learnTopics, firing.copyWith(noteId: ''), firing.id);
      expect(await book.splitStudyGuides(today: today), 0);
      final n = await (db.select(db.learnNotes)..where((n) => n.id.equals(topicNoteId(firing.id)))).getSingle();
      expect(n.deleted, isTrue);
    });

    test('guide sections read headings, text and the last block of links', () {
      final s = guideSections(
        '# C\n\nIntro\n\n## 1. A (30 min)\n\nText\n\n- r1\n- r2\n\n## 2. B (with brackets) (1.5 h)\n\n- only a list\n',
      );
      expect(s.map((x) => x.title), ['A', 'B (with brackets)']);
      expect(s.first.resources, ['r1', 'r2']);
      expect(s.first.text, 'Text\n\n- r1\n- r2');
      expect(s.last.resources, ['only a list']);
    });
  });

  test('a version 6 database gains topic pages and keeps every row', () async {
    final dir = await Directory.systemTemp.createTemp('vidya');
    final file = File('${dir.path}/v6.db');
    var db6 = AppDatabase(NativeDatabase(file));
    var b = LearningBook(await Store.open(db6));
    final pid = await b.addProgram('P', 'G', today: today);
    final cid = await b.addCourse('C', today: today, programId: pid);
    final tid = await b.addTopic(cid, 'T', minutes: 45);
    await b.setTopicDone((await db6.select(db6.learnTopics).get()).single, true, today: today);
    await b.saveCard('Q', 'A', today: today);
    await b.saveNote('N', 'Body', 'x', today: today);
    // Turn it back into version 6: no items, criteria or new columns.
    await db6.customStatement('DROP TABLE learn_items');
    await db6.customStatement('DROP TABLE learn_criteria');
    for (final c in ['status', 'note_id', 'criteria', 'tick_note']) {
      await db6.customStatement('ALTER TABLE learn_topics DROP COLUMN $c');
    }
    await db6.customStatement('ALTER TABLE learn_programs DROP COLUMN role');
    await db6.customStatement('PRAGMA user_version = 6');
    await db6.close();

    db6 = AppDatabase(NativeDatabase(file));
    b = LearningBook(await Store.open(db6));
    final s = await b.stats(today);
    expect((s.programs.single.title, s.programs.single.role), ('P', ''));
    expect(s.courses.single.status, 'done');
    final t = s.topics.single;
    expect(
      (t.id, t.title, t.minutes, t.done, t.status, t.noteId, t.criteria, t.tickNote),
      (tid, 'T', 45, today, '', '', '', ''),
    );
    expect((s.cards.single.front, s.notes.single.body), ('Q', 'Body'));
    await b.addItem(tid, 'video', 'Works');
    expect((await db6.select(db6.learnItems).get()).single.title, 'Works');
    await db6.close();
    await dir.delete(recursive: true);
  });
}
