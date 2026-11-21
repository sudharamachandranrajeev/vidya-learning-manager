<h1 align="center">
  <br>
  <a href="https://github.com/sudharamachandranrajeev/vidya-learning-manager"><img src="branding/vidya-512.png" alt="Vidya" width="140"></a>
  <br>
  Vidya
  <br>
</h1>

<h4 align="center">Plan what you want to learn, study a little every day, remember it, and show what you can do.</h4>

<p align="center">
  <a href="https://github.com/sudharamachandranrajeev/vidya-learning-manager/releases"><img src="https://img.shields.io/github/v/release/sudharamachandranrajeev/vidya-learning-manager?include_prereleases&color=4f7c68&label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/works%20on-Linux%20%7C%20Windows%20%7C%20Android-555" alt="Works on Linux, Windows and Android">
  <img src="https://img.shields.io/badge/your%20data-encrypted-2e7d32" alt="Your data is encrypted">
  <a href="https://github.com/sudharamachandranrajeev/brahma-life-suite"><img src="https://img.shields.io/badge/part%20of-Brahma-8a5cf6" alt="Part of Brahma"></a>
</p>

<p align="center">
  <a href="#-what-it-does">What it does</a> •
  <a href="#-get-started">Get started</a> •
  <a href="#-how-it-works">How it works</a> •
  <a href="#-faq-and-troubleshooting">FAQ</a> •
  <a href="#%EF%B8%8F-for-developers">For developers</a>
</p>

<p align="center">
  <img src="docs/screenshots/hero.png" alt="Vidya on a desktop window and phones" width="100%">
</p>

Vidya is a calm study companion for self-learners: a new career, a certification, a degree or a
pile of books. It turns a big goal into small steps, keeps a gentle daily habit, and shows real
progress. Status: **early test releases**. It needs no internet and no account.

## ✨ What it does

- 🗺️ **A plan for any goal** – a goal holds courses, and each course holds topics. Start from a
  template (software engineer, data analyst, cloud and DevOps) or write your own.
- 🤖 **Plans drafted by AI** – describe your goal or exam and let the AI you set up for
  **Ask AI** write the plan, or copy Vidya's prompt into any AI chat and paste the reply back.
  Courses with due dates, topics, study notes, skills and flashcards arrive in one go.
- ▶️ **Next up** – Home and each course show the one thing to study next, with one tap to start
  it (a video picks up where you stopped, "Resume at 12:30").
- 📖 **Topic pages** – each topic holds its videos, articles, books, practice tasks and your own
  notes. Take its quiz: missed questions become flashcards by themselves. A practice task needs
  an evidence link (or a note) to be done, and goes into your portfolio in one tap.
- 🔎 **Find free resources** – search Microsoft Learn, MIT Learn and Open Library at once for
  a topic or a role (OpenLearn opens in your browser). Free results come first, each with its length, level, a free /
  audit / paid badge and its licence; one tap adds it to a topic. Paste any other link (Coursera,
  YouTube, NHS e-LfH…) and Vidya reads its title for you.
- ⏱️ **Focus timer and study log** – run a quiet 15 to 60 minute timer, or log time by hand, on a
  course or a topic. Set a weekly time target if you like: Home shows how far you are since
  Monday, and a quiet week costs nothing. Record test scores as you go.
- 🃏 **Flashcards that stick** – cards come back just before you would forget them (spaced
  repetition). See what is due today and this week.
- 📈 **Skills and gaps** – rate each skill 0 to 5 and set a target. The gap is your to-do list.
- 🏆 **A portfolio** – projects, certificates, talks and degrees, each linked to the skills it
  proves. Copy it all as text for a CV.
- 📝 **Notes** – a searchable knowledge base with tags. Notes a plan made sit behind **From plans**
  so your own come first.
- 📤 **Your history, yours** – export everything you studied as Markdown or JSON from Settings.
- 📊 **Progress you did not type in** – study time, streaks, scores, retention and a weekly chart,
  all worked out from what you record.
- 🌱 **Quietly game-like** – three small quests a day, levels from Seed to Sage and 34
  achievements. No noise, no nagging.
- 🔒 **Private by design** – data is encrypted on the device. Sync is optional, and one account
  works in every Brahma app.

<details>
<summary>How experience and levels work</summary>

Experience comes from topics, study time (capped per day), tests, courses, programs (goals),
skill levels, portfolio items, notes, cards and reviews (capped per day) and achievements. Level
*n* starts at 50·n·(n−1) experience. Achievements unlock once and stay. Flashcards use a
day-by-day SM-2 schedule: **Again** brings a card back today; **Good** and **Easy** push it
further out each time.
</details>

## 📸 Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home-light.png" alt="Home" width="220"><br><sub>Home</sub></td>
    <td align="center"><img src="docs/screenshots/review-light.png" alt="Flashcard review" width="220"><br><sub>Review</sub></td>
    <td align="center"><img src="docs/screenshots/progress-light.png" alt="Progress" width="220"><br><sub>Progress</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/achievements-light.png" alt="Achievements" width="220"><br><sub>Achievements</sub></td>
    <td align="center"><img src="docs/screenshots/home-dark.png" alt="Home in dark mode" width="220"><br><sub>Home (dark)</sub></td>
    <td align="center"><img src="docs/screenshots/home-desktop.png" alt="Home on a desktop window" width="220"><br><sub>Home on a desktop</sub></td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/progress-desktop.png" alt="Progress on a desktop window" width="80%"><br>
  <sub>Progress on a desktop window</sub>
</p>

<sub>All screenshots show a made-up learner, rendered from the app's code.</sub>

## 🚀 Get started

### Step 1 – Download

Open the [releases page](https://github.com/sudharamachandranrajeev/vidya-learning-manager/releases) and, under
the newest release, pick the file for your device:

| Your device | File to download | Works on |
| --- | --- | --- |
| 🐧 Linux computer | `Vidya-<version>-linux-x64.tar.gz` | Ubuntu 24.04, Fedora, Arch and similar (64-bit x86) |
| 🪟 Windows computer | `Vidya-<version>-windows-x64-setup.exe` | Windows 10 and 11 |
| 🤖 Android phone | `Vidya-<version>-android.apk` | Android 7 and newer |

Each release also has `SHA256SUMS.txt`, a list of fingerprints to check the files are genuine.

### Step 2 – Install

<details>
<summary><b>🐧 Linux</b></summary>

1. Open a terminal in the folder where the download landed.
2. Unpack it and run the installer as your normal user (not `sudo`):
   ```sh
   tar -xzf Vidya-*-linux-x64.tar.gz
   cd vidya-*-linux-x64 && ./install.sh
   ```
3. Open **Vidya** from your app menu.

It installs for your user only. It needs GTK 3, libsecret and the desktop keyring (the app that
stores passwords) running. To remove it later: `./install.sh --uninstall`. Your data stays.

</details>

<details>
<summary><b>🪟 Windows</b></summary>

1. Double-click `Vidya-<version>-windows-x64-setup.exe`. No admin rights needed.
2. Windows may say *"Windows protected your PC"*. This appears because the app isn't paid-signed
   yet, not because it is harmful. Click **More info → Run anyway**.
3. Follow the installer, then open **Vidya** from the Start menu.

Prefer no installer? Download `…-windows-x64-portable.zip`, unzip it anywhere and run `vidya.exe`.

</details>

<details>
<summary><b>🤖 Android</b></summary>

1. Open the downloaded `.apk` on your phone.
2. If Android asks, allow installs from your browser or file manager. This is normal for apps
   from outside an app store.
3. Tap **Install**, then **Open**.

Newer versions install over the top and keep your data.

</details>

### Step 3 – First launch

Vidya opens on **Home**, with today's quests. Every screen works empty.

1. **Make a plan**: open **Learn** and tap **Use a template**, or **New program** to write your
   own goal. A single course without a goal? Tap **Course outside a program**.
2. **Study**: tap **Focus** at the top of **Home** and pick a length. The time is logged when it
   ends. Or open a course and tap **Log time**.
3. **Tick off topics** on the course page. The course and the goal move on by themselves.
   Tap a topic to open its page: what to watch, read and do (add your own items, mark them
   done, note where you stopped in a video or book), why it matters for the job, and your
   own notes. A topic whose required items are all done is earned; ticking it before then
   asks for a short note on why.
4. **Add flashcards**: on **Review**, tap **Card**. Come back daily and tap **Begin review**.

#### Import a whole study plan

1. On **Learn**, tap **Import a study plan** (the list icon at the top).
2. Get the plan one of two ways:
   - **Make it with AI**: type your goal or exam, and optionally the syllabus or notice, your
     weekly hours and the deadline, then tap **Write the plan**. The AI you chose for **Ask AI**
     (a key, a local model or a coding-plan CLI; **Change** picks one) writes it, part after
     part for a long plan. Only what you type there is sent.
   - **Copy AI prompt**: paste it into any AI chat and fill in the brackets. Copy the whole
     reply into the **AI reply** box; for a long plan, paste every part one after another. Or
     tap **Open a file** for a saved `.json` plan.
3. Check the summary (courses, topics, cards, and any missing parts), then tap **Import**.

Each course's topic details land in a study-guide note, and each topic also gets them as its
own note, with its links as items on the topic page. Due dates count from the day you import.
Importing the same plan again, or a part you left out, adds only what is new; items the plan
sends again are updated in place and keep what you marked done.

Plans made before topic pages (format 1) still import. Format 2 adds, all optional:

- per topic, `items`: `{ "type", "title", "url", "source", "licence", "minutes", "required" }`.
  The type is one of course, video, article, book, practice task, quiz, interview drill or note.
  A practice task may add `instructions` and `doneWhen`. An `id` keeps an item the same when
  the plan comes again.
- per topic, `quiz`: `{ "question", "kind": "choice" | "short" | "card", "options", "answer",
  "explain" }`, and `drills`: `{ "question", "criterion", "rubric", "story" }`. They are under
  **Check yourself** on the topic page.
- for the plan, `criteria`: `{ "id", "text", "essential", "kind", "source", "shown" }`, and a
  `role`; each topic lists the criteria it works towards in its own `criteria` (ids).

An item the plan stops sending is set aside on its topic page (**No longer in the plan**), not
deleted, and no longer counts; items you had done stay as they are. Quiz questions you add or
change are kept when the plan comes again.

#### Topics, quizzes and practice tasks

1. Tap a topic on a course page to open it. Tick items as you go; a video or book keeps where
   you stopped.
2. Under **Check yourself**, tap **Take the quiz**. Tap an option, type a short answer (a close
   match is marked right by itself; otherwise compare with the answer and mark yourself), or
   recall a card and mark yourself. Each missed question becomes a flashcard in the course's
   deck, once, however often you retake it.
3. **Edit questions** adds your own. If you connected an AI for **Ask AI**, **Write questions
   with AI** adds a few, labelled AI and editable; only the topic and item titles are sent.
4. A topic is earned when its required items are done and, if it has a quiz, your last score was
   70% or more. You can still tick it off earlier with a short note.
5. A practice task shows its instructions and "done when" line. Marking it done asks for an
   evidence link, or a note when there is nothing to link to; then **Add to portfolio** makes it
   a portfolio project in one tap.

#### Find free resources

1. On a topic page, tap **Find free resources** (or the 🔍 button on a course or a goal, which
   searches for that course or role). The topic's name is already filled in; change it and tap
   **Search**.
2. Microsoft Learn, MIT Learn and Open Library are asked at the same time. Each has its own
   line ("MIT Learn: 20 found"); if one is down, the others still answer. OpenLearn blocks apps,
   so it is link only: tap **Search OpenLearn** to open its own search for the same words in
   your browser. Vidya never fetches anything from OpenLearn.
3. Free results come first. Each shows its source, length, level, a **Free**, **Free to audit**,
   **Free to borrow** or **Paid** badge, and its licence. Tap **Add** to put it on the topic.
4. "Free" changes. If a course turns out to be paid, open the item, tap **Edit** and change
   **Free or paid**.
5. Anything else: tap **+** on a topic, paste the link and tap the **T** button. Vidya reads the
   title from that one page (YouTube and Vimeo through their oEmbed service). If it cannot, type
   the title yourself.
6. Optional: add your own YouTube Data API key in **Settings → Data sources** to search YouTube
   too (about 100 searches a day on the free quota). The key stays in this device's keychain and
   is never synced. Settings also lists each catalogue with its licence or terms.

Vidya keeps links and titles only, never a course's text. Study-guide notes from older plans
are split into topic notes and link items once, when Vidya opens; the guide itself is kept.
See [`docs/examples/2026-11-08-car-inspector-7612.json`](docs/examples/2026-11-08-car-inspector-7612.json)
for a full example: a plan for NYC Transit's Car Inspector exam 7612.

### Step 4 (optional) – Use it on more than one device

Turn on sync in **Settings → Sync**. You need a sync server you own; the
[Brahma sync server guide](https://github.com/sudharamachandranrajeev/brahma-life-suite/tree/main/server)
walks you through it. **Write down the recovery key** it shows and keep it safe.

### Using Vidya with Udyoga

Udyoga, the career app (see [Related](#related)),
turns the gaps it finds between you and the jobs you want into a Vidya study plan, with your
interview stories as rehearsal cards. Both apps work on their own; together they share only
the plan and your progress.

1. **With sync** (both apps signed in to the same sync server): in Udyoga, open
   **Prepare → Coach**, find **Learn and rehearse in Vidya** and press **Send to Vidya**.
   Vidya's Home then shows **A study plan from Udyoga**. Add it with one tap.
2. **Without sync**: press **Save plan** in Udyoga instead. In Vidya, go to
   **Learn → Import a study plan → Open a file** and choose the saved file.
3. **Sending it again** updates the same program. Your progress stays. A card the new plan
   no longer has (for example a story you deleted in Udyoga) is set aside, not deleted: its
   reviews are kept, it is never due, and it comes back if the plan sends it again. Review
   shows how many are set aside.
4. **What goes back to Udyoga** (with sync only): topics you finish, the skills you rate, and
   your rehearsal results. They are sent when a review session ends and when Vidya opens, at
   most once every ten minutes.
5. **Home → Interview readiness** shows each interview competency against its target. Press
   **Rehearse** to practise only your interview stories that are due.

## 🧭 How it works

```mermaid
flowchart LR
    G["🎯 Your goal"] --> C["📚 Courses"] --> T["✅ Topics"]
    T -->|"time, tests, cards"| X["🌱 Progress, quests<br/>and achievements"]
    X -.->|"optional, locked first"| S[("🏠 Your sync server")]
```

- **Everything is built from what you record.** Finish topics and the course moves on; finish
  every course and the goal is done.
- **On each device**, Vidya keeps your data in an encrypted database. Without your key it is
  unreadable.
- **Vidya goes online only when you ask it to.** It searches the free catalogues when you tap
  **Search**, reads a pasted link's title when you tap the **T** button, and talks to your sync
  server only if you sign in. The Microsoft Learn catalogue is kept on the device for a
  day, so a second search does not ask again. The next release also asks
  GitHub once a day for a newer version (you can switch this off).

> [!IMPORTANT]
> Your password and recovery key are the only ways to unlock synced data. If you lose both, nobody
> can recover it. On Android, uninstalling the app deletes its data, so sync first.

## ❓ FAQ and troubleshooting

<details>
<summary><b>Do I need an account or the internet?</b></summary>

No. Vidya works fully offline on one device. You only need a server if you want sync.
</details>

<details>
<summary><b>Windows says the app might be unsafe</b></summary>

The build isn't code-signed (a paid certificate). Click **More info → Run anyway**. Check the file
against `SHA256SUMS.txt` on the release if you want to be sure it is genuine.
</details>

<details>
<summary><b>Linux: Vidya stops at start and talks about a missing key</b></summary>

The key that unlocks your data lives in the desktop keyring. Make sure your keyring app is
running and unlocked, then start Vidya again.
</details>

<details>
<summary><b>I missed a day. Is my streak gone?</b></summary>

The streak restarts, but your longest streak, experience, level and achievements stay. Quests are
small on purpose: one short focus session is enough to start again.
</details>

<details>
<summary><b>Where is my data stored?</b></summary>

Linux: `~/.local/share/dev.brahma.vidya`. Windows: in your user's AppData folder. Android: inside
the app. Uninstalling on Linux or Windows leaves it in place.
</details>

## 🛠️ For developers

<details>
<summary>Build from source, test and release</summary>

You need [Git](https://git-scm.com) and [Flutter](https://flutter.dev) 3.47.

```bash
git clone https://github.com/sudharamachandranrajeev/vidya-learning-manager
cd vidya
flutter pub get
dart run build_runner build -d   # generate the database code
flutter run -d linux             # or windows, or an Android device

flutter test && dart format -l 110 lib test                       # test and format
VIDYA_SHOTS=/tmp/shots flutter test test/screenshots_test.dart    # render the screenshots
scripts/make-icons.sh                                             # app icons from branding/
```

- `brahma_core` comes from the [brahma](https://github.com/sudharamachandranrajeev/brahma-life-suite) repo.
  To work on both at once, add a `pubspec_overrides.yaml` (ignored by git) pointing at
  `../brahma/core`.
- The plan structure (program, course, topic, assessment) follows the ERPNext education module.
- CI runs on each push. A `v*` tag builds, smoke-tests and publishes the Android, Windows and
  Linux builds (`.github/workflows/release.yml`).
- Changes per version: [CHANGELOG.md](CHANGELOG.md).

</details>

<details>
<summary>Credits</summary>

- [Flutter](https://flutter.dev) and [Riverpod](https://riverpod.dev)
- [drift](https://drift.simonbinder.eu) over [SQLite3MultipleCiphers](https://utelle.github.io/SQLite3MultipleCiphers/)
  for the encrypted database
- [url_launcher](https://pub.dev/packages/url_launcher) and [intl](https://pub.dev/packages/intl)
- The [ERPNext](https://erpnext.com) education module, as the model for programs, courses and topics
- Fonts [Inter](https://rsms.me/inter/) and [Plus Jakarta Sans](https://github.com/tokotype/PlusJakartaSans),
  bundled under the SIL Open Font License

</details>

## Related

Vidya is one app in the **Brahma** family. They share one sign-in and one sync server.

| App | What it does |
| --- | --- |
| [brahma](https://github.com/sudharamachandranrajeev/brahma-life-suite) | The shared core and the all-in-one app |
| [artha](https://github.com/sudharamachandranrajeev/artha-personal-finance) | Money: accounts, spending, bills and investments |
| [graha-anveshana](https://github.com/sudharamachandranrajeev/graha-anveshana-property-search) | Find a home to rent or buy |
| [vahana-anveshana](https://github.com/sudharamachandranrajeev/vahana-anveshana-car-manager) | Find a car |
| [udyoga](https://github.com/sudharamachandranrajeev/udyoga-career-manager) | Career and job hunting |

## License

No licence has been chosen yet; all rights reserved.

---

> GitHub [@sudharamachandranrajeev](https://github.com/sudharamachandranrajeev)
