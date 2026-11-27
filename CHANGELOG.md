# Changelog

## Unreleased

- Exam mode: a plan can make a topic's quiz a timed exam (format 3, optional `exam` block: `minutes` 1–300, `passPercent` 1–100, `retakeDays` 0–60, `shuffle`), and tag each question with the `topic` it tests. The timer never pauses and hands the exam in by itself at zero; no feedback until the end; questions shuffled when set. The report card gives the score, pass or fail against the exam's own pass mark, time taken, questions answered, a breakdown per topic, a "study these first" list and every answer with its explanation. Missed questions become review cards as before. A wait between attempts locks the next one until a date shown on the topic and course pages; **Practise anyway (not counted)** never counts as an attempt. A "seen before" warning when the pool is small or questions repeat from an earlier attempt. Exam scores are charted on the topic. The time left is announced to screen readers at set points; charts respect reduced motion. Attempts are kept as results with a detail (no database change). Quizzes without `exam` work exactly as before.
- Exams: an optional `count` (1–100) draws that many questions per attempt, unasked ones first, then those asked longest ago; the report card gives the share seen in an earlier attempt, and a warning shows before starting only when the pool is under twice the count. An exam's quiz may hold up to 100 questions (practice quizzes still 20). An attempt in progress is kept on the device (local settings, never synced, no database change), so closing or killing the app loses nothing: it resumes with the time still running from the start, or is handed in if time ran out.
- Large text: a progress meter's figure wraps instead of overflowing its row (seen on course pages at twice the text size).

- Linux: Vidya starts without mpv. libmpv is loaded only to play a video take; without it the playback screen says "Install mpv (libmpv) to play takes".
- Video takes: a camera clip moves into the private store in one rename and its temporary file is always deleted, also after a failed save; anything a crash left (half-moved clips, stale camera files in the temporary folder) is swept when Vidya next starts.
- Job journey stage packs: the later stages get tools. **Templates** (contact, follow-up, after, offer): informal-call request, call plan, polite chase, feedback request by criterion (the score per question and what a higher score needed), an optional UK thank-you, a starting-pay-point query, accept, decline, withdraw other applications and a notice letter. Short UK English, filled in from the journey and your details (the manager's name only if you entered it), each with its heads-ups; edit, then **Copy**, or **Open in Udyoga Conversations** when Udyoga is linked (a draft in Udyoga's message box; nothing is ever sent for you).
- **Offer checker**: band or grade, pay point, salary, hours, fixed term, probation, start date and notice, against dated Agenda for Change 2026/27 rule cards (promotion normally starts at the bottom of the new band; experience credit is discretionary, counts completed years and must be agreed in writing before you accept) and, for universities, a grade table where Vidya has one or the range you type. Says what is normal, what to ask and what to watch, flags the 2026/27 cards from 1 April 2027, and builds an evidence table for a higher starting point. Labelled "not legal advice".
- **Checks**: Udyoga's finalise checklist for the application when it has one (it now rides in the job journey), else Vidya's own list for the sector: ID, right to work, references (NHS to NHS covers 6 months, others 3 years), DBS and the Update Service, occupational health and an IAT note. Due dates and overdue warnings.
- **Joining, first 90 days and grow**: day-one list; who's who and acronyms as flashcards in spaced review; a mandatory training tracker; a 30/60/90 plan; probation review dates and prep; a weekly wins log whose entries go to the story bank in one tap; a monthly check-in (the review reminders include it when on); PDR prep; and next-role readiness, which makes a goal from the next band's criteria and opens Job readiness for it.
- Every factual line has its source and the day it was checked, or says "General advice". No database change: pack data lives in the journey's progress JSON.

- Video takes (optional): turn on **Record video for this round** (off every time, needs the camera on) and each kept answer is saved as a video with your own recording of it, with a red "Recording video" sign while it records. On this device only, in the app's private folder: never synced, backed up or sent to an AI (only the transcript is). Deleted after 14 days by default; **Settings → Interview video takes** changes the days, shows the space used and deletes them all. The debrief's **Watch this answer** opens the video beside your transcript and the criteria; tap a quoted line to jump to it. Linux now needs mpv's library (libmpv) to run.
- Job readiness: each goal has a **Job readiness** page (on the goal page, and as a card on Home for the goal with the nearest interview, else the latest role plan). One row per essential or desirable criterion, each with its evidence: topics linked to it (done or open), the latest quiz score on them, practice tasks, drill scores (yours and Udyoga's), linked stories, portfolio items and skills with matching words. Each row is covered, weak or missing. Covered needs one strong piece of your own work from the last 60 days: a done topic with a quiz of 70% or more, a task done with evidence, a drill of 5/8 or more, or a linked story with a done topic. Older work, a quiz under 70%, a drill under 5/8, or only planned items count as weak; no evidence at all is missing. AI never marks a row covered: a criterion's AI source, the "your CV shows this" flag and any status a plan sends are ignored.
- Readiness is shown as counts, not one percentage: "9 of 12 essential covered, 2 weak, 1 missing · desirable 3 of 5 · interview in 6 days". A **Next** button gives one step for the weakest essential row (take or retake a quiz, practise a drill, finish a task, write a story); each row opens to its evidence, and each piece opens its topic, drill, story, portfolio item or skill.
- Criteria typed in by hand: for a goal without criteria from Udyoga, add the rows of a person specification (essential or desirable) and pick the topics that work towards each. A plan sent again keeps those links.
- Weak and missing rows go back to Udyoga as a `readiness` list on the plan's progress report (format in the README), so Udyoga can turn them into drill cards. The other progress fields are unchanged. No database change.
- Before the interview now uses Job readiness's status rules, so both pages always agree on which criteria are weak or missing and in what order; each weak criterion shows its reason (only planned, low quiz, low drill and so on).
- The readiness report to Udyoga judges "recent" on your own calendar day, not the UTC day of the report time (a morning report in New Zealand no longer counts as the day before).

- Interview training: tap an interview drill on a topic page to practise it. It shows the question and the criterion it tests, a timer (2 minutes by default, ±30 seconds) and asks you to answer out loud. Vidya does not record sound (no recording package is in the app) and says so. Then rate yourself on four checks, 0–2 each: situation clear, own actions, result or impact, linked back to the criterion. The score (out of 8) is saved as a result on the topic and the drill; under 5 flags the drill as weak. Past attempts can be deleted. **Add drill** writes your own, tagged with a criterion.
- Scenario questions ("What would you do if…") get a guided frame, saved with the attempt: what I'd check first, staying within my role's scope, when I'd escalate, how I'd document or hand over.
- Practise in Udyoga: hands a drill to Udyoga's voice simulator by adding it to a `vidya.practise-requests` row in the shared progress table (format in the README). Udyoga lists it and runs it as a one-question voice round. A score Udyoga writes back in a `udyoga-practise-results` row shows on the drill.
- Story bank: Udyoga's story cards and your own stories, each stored once and shown as STAR or CAR (Context is the situation and task together), linked to criteria and drills.
- Before the interview: per goal, the weak criteria first (no drill or quiz evidence, then low scores; essential first), then the stories linked to them, then the drills (weak ones first), with an optional interview date and countdown (synced).
- After a real interview: a feedback log (date, employer and role, criteria and questions that went badly, notes) saved as a note, and each weak spot becomes a drill on a topic linked to that criterion, or on an "Interview follow-ups" topic.
- Database version 9: results gain the drill they are for and an attempt's detail; a new story table. The upgrade adds columns and a table only, so every row is kept.

- Find free resources: on a topic page (or from a course or a goal, for that course or role), one search asks Microsoft Learn, MIT Learn and Open Library at the same time. OpenLearn is link only: its feeds block apps, so a *Search OpenLearn* row opens OpenLearn's own search for the same words in your browser, and Vidya never fetches anything from open.edu. Each catalogue has its own progress line, and one that is down does not stop the others. Free results come first, each with its source, length, level, a free / free to audit / free to borrow / paid badge and its licence; one tap adds it as an item of the right type. Vidya keeps the link and those facts only, never the lesson text. The Microsoft Learn catalogue is kept on the device for a day; Open Library is asked at most 3 times a second and backs off when told to slow down.
- Paste any link when adding an item and tap the title button: Vidya reads the title from that one page (og:title or its title; YouTube and Vimeo through oEmbed) and guesses the type. If it cannot, you type the title.
- Each course, video, article or book item has a *Free or paid* badge you can correct, because "free" changes.
- Optional YouTube search with your own API key (Settings, *Data sources*), kept in this device's keychain and never synced. Settings lists every catalogue with its licence or terms.
- New direct dependency: `http` (BSD-3-Clause), already in the app through Brahma core.

- Quizzes: take a topic's quiz one question at a time (pick an option, type a short answer that is marked leniently or by you, or recall a card), with the explanation after each. The score is saved on the topic ("Last quiz: 80%") and each missed question becomes a review card in the course's deck, once, however often you retake. Add and edit questions by hand; with an AI connected for Ask AI, it can write a few, labelled AI and editable. Retaking a quiz earns experience once per topic.
- A topic is earned when its required items are done and, if it has a quiz, the last score is 70% or more. Ticking earlier still works with a short note.
- Practice tasks show their instructions and "done when" line, need an evidence link or a note to be done, and become a portfolio project in one tap.
- Next up: Home and each course show the next unfinished required item (then an unpassed quiz), skipping paused programs and dropped courses, with one tap to open it; a video or book shows "Resume at …". Calm when nothing is waiting.
- Weekly time target (Settings or Home): progress since Monday, no streaks, nothing lost for a quiet week. Time can be logged on a topic, and the topic page shows it.
- Settings, *Your history*: export programs, courses, topics with status, items done with takeaways, quiz and test scores, time and your own notes as Markdown or JSON.
- Notes made from plans (topic notes and study guides) are behind a *From plans* filter on Notes, so your own come first.
- An item a re-sent plan no longer has is set aside on its topic page, not deleted, and no longer counts; items you had done are never set aside; it comes back if the plan sends it again.
- Database version 8: sessions and tests can name a topic; items can be set aside. The upgrade keeps every row.

- Topic pages: tap a topic to open it. Each has its status (not started, studying, review, done), why it matters (the job criteria a plan links to it), its study items (course, video, article, book, practice task, quiz, interview drill or note, each with its own fields: where you stopped, a one-line takeaway, an evidence link), your own Markdown note, and a "Check yourself" list of its quiz and drills. The tick box stays on the course page. A topic whose required items are all done is earned; ticking it earlier asks for a short note.
- Study plans format 2: per-topic `items`, `quiz` and `drills`, plan `criteria` and `role`. Udyoga's role plans arrive with their criteria and items. Format 1 plans still import. A plan sent again updates its items in place and keeps what you marked done. The AI prompt asks for items, quizzes and drills.
- Study-guide notes from earlier plans are split into one note per topic, with their links as items, the first time this version opens. The guide notes are kept. Notes made from a plan earn no experience until you write in them.

- Study plans from your career file (the `settings/vidya-*.json` files Udyoga syncs) are offered on Home as "A study plan from your career file", one tap to add. Settings, *Plans from your career file*, can add them, and update them when the file changes, without asking; Udyoga's own plans still wait for a tap.
- A study plan Udyoga sends through sync is offered on Home and added in one tap; adding a re-sent plan updates the same program. What you finish and the skills you rate go back to Udyoga by themselves. Importing a plan file still works without sync.
- A plan card the re-sent plan no longer has (a story deleted in Udyoga) is set aside, not deleted: its reviews are kept, it is never due, and it comes back as it was if the plan sends it again. Review shows how many are set aside.
- Rehearsal results go back to Udyoga when a review session ends and when Vidya opens or comes back to the front, at most once every ten minutes, instead of after every grade.
- Sync: *Change server address* follows your sync server to another computer without signing in again; edits that clashed with another device's are kept for you to bring back; the Sync card shows changes waiting to send.

## 0.4.0 (2026-11-15)

- Interview readiness: import the study plan Udyoga (the career app) makes from your gaps, and Home shows each interview competency against its target, with a button to rehearse only your own interview stories when they are due.
- Review sessions can be limited to one deck.

## 0.3.1 (2026-11-10)

- Windows: the installer has its own id. Before, it shared one with other Brahma apps, so Windows could install it into another app's folder and replace its Start menu shortcut. Install this version to move it to its own folder; your data is not touched.

## 0.3.0 (2026-11-08)

- Learn: import a whole study plan. Copy the in-app prompt into any AI chat, paste the reply (or
  open a `.json` plan), check the summary and import. Courses arrive with due dates, topics with
  minutes, topic details and resources as one study-guide note per course, plus skills,
  flashcards linked to their course, and notes. Plans merge by title, so a second import or the
  next part of a long plan adds only what is new. Example: `docs/examples/` holds a plan for NYC
  Transit's Car Inspector exam 7612.
- "Make it with AI" writes the plan in the app, through the AI chosen for Ask AI. Type the goal
  and, if you like, the syllabus, level, weekly hours and deadline; a long plan arrives part
  after part. A chat website cannot answer in the app, so then it copies the filled-in prompt.
  Several parts pasted one after another import together, and the summary names missing parts.
- A short welcome on first start asks where your data lives: on this device only, or synced
  through a home or cloud server, with guided steps. Vidya says when a newer release is out.
- App lock: a PIN or the device's own unlock over the app.
- Ask AI for help on any screen, and Report a problem or suggest a feature from the app.
- Review pace in Settings: Light (longer gaps, fewer reviews), Standard or Intensive (shorter
  gaps before an exam). The buttons show the next gap for the pace you chose. During a review,
  "Why now?" explains in plain words why a card is due.
- Review: typed answers are graded leniently. Case, spacing, punctuation, a leading article and
  bracketed text do not matter, and any synonym listed on the back ("car / automobile") counts.
- Day streaks are hidden until switched on in Settings. Achievements are unchanged.
- Optional review reminders on Android for days with cards due, at a time and weekly limit you
  set. No server involved.
- Flashcards can carry an image and audio, and cloze cards hide `{{c1::…}}` spans.
- Export cards to a share file; import cards from CSV, tab-separated text or a Vidya file.
- The database moves to version 3 (card image and audio); existing data is kept.

## 0.2.1 (2026-10-25)

- Phones get new navigation: a floating dock that scrolls through every screen (the "More"
  sheet is gone) and a side panel listing them all with what each is for. Swipe right on any
  page, or tap the dock's menu button, to open it; Back closes it.

## 0.2.0 (2026-10-24)

- Review: flashcards in decks with spaced repetition, a due queue, a week-ahead forecast and
  retention. A daily quest to clear the queue, experience for cards and reviews, and six new
  achievements (Deep focus, Memory seeds, First recall, A hundred recalls, Still water, Long memory).
- Focus timer from Home or a course; logs the session when it ends.
- Portfolio: copy skills, work and finished courses as Markdown.
- Progress: retention and longest focus.
- Quest experience labels now use the app font.
- The database moves to version 2; existing data is kept.

## 0.1.1 (2026-10-24)

- Sync setup and pairing links (vidya://) now open and work in Vidya.

## 0.1.0 (2026-10-24)

First release.

- Programs, courses and topics with templates; study log; tests.
- Skills with levels and targets; portfolio with a strength score; tagged notes.
- Progress metrics and charts; experience, levels, streak, daily quests, 28 achievements.
- Zen light and dark theme. Encrypted local database, optional end-to-end encrypted sync.
