import 'package:brahma_core/brahma_core.dart';
import 'package:drift/drift.dart';

// Table names are unique across the Brahma suite: every app on an account
// reads the same change log and applies only its own tables. Vidya's all
// start with `learn_`. Dates are yyyy-MM-dd.

/// A curriculum: a goal made of courses (ERPNext's Program).
@DataClassName('Program')
class LearnPrograms extends Table with SyncedRow {
  TextColumn get title => text()();
  TextColumn get goal => text().withDefault(const Constant(''))();

  /// active | paused | done
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get started => text()();
  TextColumn get target => text().nullable()();

  /// The job role a plan from Udyoga is for ("IT Trainer"), '' otherwise.
  TextColumn get role => text().withDefault(const Constant(''))();
}

/// One course, book, certification or project inside a program.
@DataClassName('Course')
class LearnCourses extends Table with SyncedRow {
  TextColumn get programId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get provider => text().withDefault(const Constant(''))();
  TextColumn get url => text().withDefault(const Constant(''))();

  /// course | book | certification | degree | project | practice
  TextColumn get kind => text().withDefault(const Constant('course'))();

  /// planned | doing | done | dropped
  TextColumn get status => text().withDefault(const Constant('planned'))();

  /// Estimated hours to finish.
  IntColumn get hours => integer().withDefault(const Constant(0))();
  TextColumn get due => text().nullable()();
  TextColumn get finished => text().nullable()();
  TextColumn get added => text()();
}

/// A lesson or task inside a course (ERPNext's Topic).
@DataClassName('Topic')
class LearnTopics extends Table with SyncedRow {
  TextColumn get courseId => text()();
  TextColumn get title => text()();

  /// Estimated minutes.
  IntColumn get minutes => integer().withDefault(const Constant(30))();
  IntColumn get ord => integer().withDefault(const Constant(0))();

  /// The day it was finished, null while open. Stats and achievements
  /// count a topic as finished by this alone.
  TextColumn get done => text().nullable()();

  /// What the learner says about an open topic: '' (worked out from its
  /// items, see `topicStatus`), `studying` or `review`. A ticked topic is
  /// done whatever this says.
  TextColumn get status => text().withDefault(const Constant(''))();

  /// The topic's own Markdown note (a row of [LearnNotes]), '' until made.
  TextColumn get noteId => text().withDefault(const Constant(''))();

  /// Comma-separated ids of the program's criteria ([LearnCriteria.ref])
  /// this topic works towards: the "why it matters".
  TextColumn get criteria => text().withDefault(const Constant(''))();

  /// The short note given when the topic was ticked before its required
  /// items were done, '' otherwise.
  TextColumn get tickNote => text().withDefault(const Constant(''))();
}

/// One thing to study or do for a topic: a course, video, article, book,
/// practice task, quiz, interview drill or note (see study_items.dart).
/// Only links and the learner's own words are kept, never course text.
@DataClassName('StudyItem')
class LearnItems extends Table with SyncedRow {
  TextColumn get topicId => text()();

  /// course | video | article | book | practice task | quiz |
  /// interview drill | note
  TextColumn get type => text().withDefault(const Constant('article'))();
  TextColumn get title => text()();
  TextColumn get url => text().withDefault(const Constant(''))();

  /// Where it comes from: a site, channel, publisher, or "AI".
  TextColumn get source => text().withDefault(const Constant(''))();
  TextColumn get licence => text().withDefault(const Constant(''))();

  /// Estimated minutes, 0 when not known.
  IntColumn get minutes => integer().withDefault(const Constant(0))();

  /// Whether the topic is earned only once this is done.
  BoolColumn get required => boolean().withDefault(const Constant(false))();
  IntColumn get ord => integer().withDefault(const Constant(0))();

  /// The day it was done, null while open.
  TextColumn get done => text().nullable()();

  /// Where the learner stopped in a video or book ("12:30", "page 84").
  TextColumn get stoppedAt => text().withDefault(const Constant(''))();

  /// One line in the learner's words after an article or book; the text of
  /// a note item.
  TextColumn get takeaway => text().withDefault(const Constant(''))();

  /// A link to what a practice task produced.
  TextColumn get evidence => text().withDefault(const Constant(''))();

  /// The plan's stable id for the item, '' for the learner's own. A plan
  /// sent again updates the item with the same ref in place.
  TextColumn get ref => text().withDefault(const Constant(''))();

  /// More, as JSON, by type: a quiz's `questions`, a drill's `question`,
  /// `criterion`, `rubric` and `story`, a task's `instructions` and
  /// `doneWhen`. '' when there is nothing more.
  TextColumn get content => text().withDefault(const Constant(''))();
}

/// What a job (or any goal) asks for, from a plan: one row per essential or
/// desirable criterion, so each can later show its own evidence.
@DataClassName('Criterion')
class LearnCriteria extends Table with SyncedRow {
  TextColumn get programId => text()();

  /// The plan's id for it ("e1"), which topics list in their criteria.
  TextColumn get ref => text()();
  TextColumn get body => text()();
  BoolColumn get essential => boolean().withDefault(const Constant(false))();

  /// skill | requirement | value | knowledge … as the sender names it.
  TextColumn get kind => text().withDefault(const Constant(''))();

  /// Where it comes from: "ESCO", "advert", "AI".
  TextColumn get source => text().withDefault(const Constant(''))();

  /// Whether the learner's CV already shows it; null when not known.
  BoolColumn get shown => boolean().nullable()();
  IntColumn get ord => integer().withDefault(const Constant(0))();
}

/// Time spent studying.
@DataClassName('StudySession')
class LearnSessions extends Table with SyncedRow {
  TextColumn get courseId => text().nullable()();
  TextColumn get day => text()();
  IntColumn get minutes => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

/// A quiz, exam or self-test result.
@DataClassName('Assessment')
class LearnAssessments extends Table with SyncedRow {
  TextColumn get courseId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get day => text()();
  RealColumn get score => real()();
  RealColumn get max => real().withDefault(const Constant(100))();
}

/// A skill and how far it has come against where it should be.
@DataClassName('Skill')
class LearnSkills extends Table with SyncedRow {
  TextColumn get name => text()();
  TextColumn get category => text().withDefault(const Constant('General'))();

  /// 0 (none) to 5 (expert).
  IntColumn get level => integer().withDefault(const Constant(0))();
  IntColumn get target => integer().withDefault(const Constant(3))();
  TextColumn get updated => text()();
}

/// Evidence for the candidate's portfolio.
@DataClassName('PortfolioItem')
class LearnPortfolio extends Table with SyncedRow {
  TextColumn get title => text()();

  /// project | certificate | publication | talk | contribution | degree
  TextColumn get kind => text().withDefault(const Constant('project'))();
  TextColumn get url => text().withDefault(const Constant(''))();
  TextColumn get day => text()();

  /// Comma-separated skill names it shows.
  TextColumn get skills => text().withDefault(const Constant(''))();
  TextColumn get summary => text().withDefault(const Constant(''))();
}

/// Knowledge notes.
@DataClassName('Note')
class LearnNotes extends Table with SyncedRow {
  TextColumn get title => text()();
  TextColumn get body => text().withDefault(const Constant(''))();

  /// Comma-separated.
  TextColumn get tags => text().withDefault(const Constant(''))();
  TextColumn get created => text()();
  TextColumn get updated => text()();
}

/// A flashcard, reviewed on a spaced-repetition schedule (see review.dart).
@DataClassName('Flashcard')
class LearnCards extends Table with SyncedRow {
  TextColumn get front => text()();
  TextColumn get back => text()();
  TextColumn get deck => text().withDefault(const Constant('General'))();
  TextColumn get courseId => text().nullable()();

  /// Optional media, each a web address or a file path on this device. A
  /// cloze card hides `{{c1::answer}}` spans in [front] instead of using [back].
  TextColumn get image => text().withDefault(const Constant(''))();
  TextColumn get audio => text().withDefault(const Constant(''))();

  /// The day it is next shown.
  TextColumn get due => text()();

  /// Days between the last review and [due]; 0 while new or relearning.
  IntColumn get interval => integer().withDefault(const Constant(0))();
  RealColumn get ease => real().withDefault(const Constant(2.5))();

  /// Recalls in a row since it was last forgotten.
  IntColumn get reps => integer().withDefault(const Constant(0))();
  IntColumn get lapses => integer().withDefault(const Constant(0))();
  TextColumn get created => text()();

  /// The sending app's stable id for a card that came in a study plan
  /// (for example `udyoga.story.<id>`), '' otherwise. When the plan comes
  /// again, the card with the same ref is updated in place and keeps its
  /// schedule and reviews.
  TextColumn get ref => text().withDefault(const Constant(''))();

  /// The plan a [ref] card came from (its title in lower case), '' for the
  /// user's own cards.
  TextColumn get plan => text().withDefault(const Constant(''))();

  /// The day the card's plan came again without it (the story was deleted
  /// in the sending app), '' while it is in use. A retired card is kept
  /// with its reviews but no longer shown for review.
  TextColumn get retired => text().withDefault(const Constant(''))();
}

/// One review of a flashcard.
@DataClassName('CardReview')
class LearnReviews extends Table with SyncedRow {
  TextColumn get cardId => text()();
  TextColumn get day => text()();

  /// 0 again, 1 hard, 2 good, 3 easy.
  IntColumn get grade => integer()();
}

/// An achievement earned; the row id is the achievement's key.
@DataClassName('Unlock')
class LearnUnlocks extends Table with SyncedRow {
  TextColumn get day => text()();
}

/// Shared with Udyoga (see brahma_core's bridges.dart): Udyoga writes the
/// study plan, Vidya writes what was finished.
@DataClassName('StudyPlan')
class BridgeStudyPlans extends Table with SyncedRow, StudyPlanColumns {}

@DataClassName('StudyProgressRow')
class BridgeStudyProgress extends Table with SyncedRow, StudyProgressColumns {}

@DataClassName('Pref')
class Prefs extends Table with SyncedRow, PrefColumns {}

@DataClassName('OutboxItem')
class Outbox extends Table with OutboxColumns {}

@DataClassName('SyncCursor')
class SyncCursors extends Table with SyncCursorColumns {}

@DataClassName('LocalSetting')
class LocalSettings extends Table with LocalSettingColumns {}
