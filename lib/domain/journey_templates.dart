/// The generic journey templates that ship with Vidya: NHS, university and
/// private-company variants of every stage. They hold no employer or
/// candidate details. Each line that states a fact carries its source and
/// the day it was checked against it; a line without a source is general
/// advice and is labelled so. Pay figures are for one financial year and
/// are flagged for a fresh check each April ([JourneyLine.staleAfter]).
///
/// Sources were checked on [templatesChecked] for the Vidya journey
/// research (November 2026). Re-check every source, and the pay figures
/// each April, before changing the date.
library;

import 'journey.dart';

/// The day every template source was last checked.
const templatesChecked = '2026-11-21';

/// The day the 2026/27 pay figures may go out of date.
const _payStale = '2027-04-01';

const _d = templatesChecked;

// ---- sources ----

const _rcnApply = JourneySource(
  url: 'https://rcn.org.uk/Professional-Development/Your-career/Job-applications',
  title: 'RCN: job applications',
  date: _d,
);
const _reading = JourneySource(
  url: 'https://www.reading.ac.uk/essentials/Careers/Applications-and-interviews/Applications/Supporting-statements',
  title: 'University of Reading careers: supporting statements',
  date: _d,
);
const _shu = JourneySource(
  url: 'https://www.shu.ac.uk/careers/application-tips/supporting-statements',
  title: 'Sheffield Hallam careers: supporting statements',
  date: _d,
);
const _rcnVisits = JourneySource(
  url: 'https://www.rcn.org.uk/Professional-Development/Your-career/Informal-Visits',
  title: 'RCN: informal visits',
  date: _d,
);
const _mumsnetChat = JourneySource(
  url: 'https://www.mumsnet.com/talk/work/5360451-pre-application-informal-chat',
  title: 'Mumsnet thread: pre-application informal chat (personal accounts)',
  date: _d,
);
const _panelScoring = JourneySource(
  url: 'https://www.reddit.com/comments/1xcjb6c/_/19rkwniiouvgl',
  title: 'r/NHS: an interviewer on how panels score (personal account)',
  date: _d,
);
const _payPromotion = JourneySource(
  url: 'https://nhsemployers.org/articles/pay-promotion-scenarios-faqs',
  title: 'NHS Employers: pay on promotion FAQs (Agenda for Change Annex 23)',
  date: _d,
);
const _startingSalary = JourneySource(
  url: 'https://foi.ghc.nhs.uk/wp-content/uploads/2026/05/4.3-Starting-Salary.pdf',
  title: 'An NHS trust starting salary policy (2026)',
  date: _d,
);
const _startingSalaryScotland = JourneySource(
  url: 'https://www.lanarkshirehr.nhs.scot/wp-content/uploads/Starting-Salaries-Guidance-January-2026.pdf',
  title: 'NHS Lanarkshire: starting salaries guidance (January 2026)',
  date: _d,
);
const _payScales = JourneySource(
  url: 'https://www.nhsemployers.org/articles/pay-scales-202627',
  title: 'NHS Employers: pay scales 2026/27',
  date: _d,
);
const _references = JourneySource(
  url: 'https://nhsemployers.org/system/files/2024-09/employment-history-and-reference-checks-standard-1843.pdf',
  title: 'NHS Employers: employment history and reference checks standard',
  date: _d,
);
const _iat = JourneySource(
  url: 'https://www.nhsbsa.nhs.uk/sites/default/files/2023-02/5.%20NHS%20Jobs%20and%20ESR%20integration%20-%20Check%20an%20Inter%20Authority%20Transfer%20%28IAT%29%20consent.pdf',
  title: 'NHSBSA: check an Inter Authority Transfer (IAT) consent',
  date: _d,
);
const _iatGuide = JourneySource(
  url: 'https://leademployer.merseywestlancs.nhs.uk/media/Documents/Host%20Best%20Practice%20Guide.pdf',
  title: 'Mersey West Lancashire lead employer: host best practice guide',
  date: _d,
);
const _feedback = JourneySource(
  url: 'https://www.mumsnet.com/talk/work/4517463-nhs-interview-scoring',
  title: 'Mumsnet thread: NHS interview scoring (personal accounts)',
  date: _d,
);
const _thankYou = JourneySource(
  url: 'https://uk.finance.yahoo.com/news/divisive-problem-employers-obsessed-thank-letters-post-interview-142929514.html',
  title: 'Yahoo Finance UK: employers and thank-you letters',
  date: _d,
);
const _nhsProbation = JourneySource(
  url: 'https://www.tewv.nhs.uk/about/publications/probationary-period/',
  title: 'An NHS trust probationary period policy',
  date: _d,
);
const _universityProbation = JourneySource(
  url: 'https://hr.leeds.ac.uk/download/downloads/id/155/probationary-procedures',
  title: 'A university\'s probation procedure for support staff',
  date: _d,
);
const _employmentRights = JourneySource(
  url: 'https://www.nhsemployers.org/articles/more-work-you-may-think',
  title: 'NHS Employers: the Employment Rights Act 2025 and probation',
  date: _d,
);

// ---- lines shared by the variants ----

const _scoredOnWhatYouSay = JourneyLine(
  'Panels score only what you say, against criteria fixed before the interview. Missing one essential '
  'criterion can sink an otherwise good interview.',
  source: _panelScoring,
);
const _eachCriterion = JourneyLine(
  'Write the statement criterion by criterion, addressing each and every criterion in the person '
  'specification.',
  source: _rcnApply,
);
const _specWording = JourneyLine(
  'Use the specification\'s own wording, so the shortlister can see each criterion is met.',
  source: _shu,
);
const _wordBudget = JourneyLine(
  'Budget your words: for example, 1,500 words over 10 criteria is about 150 words each.',
  source: _reading,
);
const _oneExample = JourneyLine(
  'Give one real example per criterion: the situation, what you did and what changed (STAR or CAR).',
);
const _contactInvited = JourneyLine(
  'Many adverts invite an informal chat with the manager, and nursing guidance says managers are impressed '
  'by approaches made before applying.',
  source: _rcnVisits,
);
const _contactBackfires = JourneyLine(
  'It can backfire both ways: people report managers sifting out those who did not call, and callers who '
  'did not get through. Keep it short and about the job.',
  source: _mumsnetChat,
);
const _contactWhat = JourneyLine(
  'Ask about the team, its current work and what a good first year looks like, and say in one sentence '
  'what you would bring.',
);
const _thankYouOptional = JourneyLine(
  'A thank-you email is optional in the UK; many employers do not expect one. Send one only if you want to.',
  source: _thankYou,
);
const _askFeedback = JourneyLine(
  'Feedback after an interview is patchy. Ask for it criterion by criterion, ask what a higher score would '
  'have needed, and take a phone call if one is offered.',
  source: _feedback,
);
const _employmentRightsLine = JourneyLine(
  'The Employment Rights Act 2025 pushes employers towards measurable objectives and structured probation '
  'reviews.',
  source: _employmentRights,
);
const _nhsPay = JourneyLine(
  'Agenda for Change pay in England for 2026/27 (a 3.3% rise from 1 April 2026): Band 3 £25,760 to £27,476; '
  'Band 4 £28,392 to £31,157; Band 5 £32,073 to £39,043. Check the current year\'s figures each April.',
  source: _payScales,
  staleAfter: _payStale,
);
const _bottomOfBand = JourneyLine(
  'Moving up a band normally starts you on the bottom pay point of the new band (Agenda for Change Annex 23, '
  'paragraph 11).',
  source: _payPromotion,
);
const _experienceCredit = JourneyLine(
  'Starting above the bottom pay point for your experience is at the employer\'s discretion, is often '
  'counted in completed years only, and must be agreed before you accept the offer.',
  source: _startingSalary,
);
const _experienceCreditScotland = JourneyLine(
  'Policies in Scotland say the same: a higher starting point is agreed before the offer, not after.',
  source: _startingSalaryScotland,
);

// ---- stages shared by the variants ----

const _decideProduce = [
  JourneyProduce('Criteria table: each criterion, how it is assessed, my example, my gap', kind: 'table'),
];
const _decideHeadsUp = [
  JourneyLine('Adverts can close early when they get many applications. Apply well before the closing date.'),
  JourneyLine('If you need a visa, check whether the employer can sponsor before you spend time applying.'),
];
const _decideCheck = JourneyCheck(
  kind: 'self',
  prompt:
      'Look at each essential criterion on the Readiness page. If one is a real blocker, decide whether to '
      'apply anyway and write down why.',
);

const _research = JourneyStage(
  id: 'research',
  title: 'Research the job',
  order: 1,
  teach: [
    JourneyLine(
      'Build a short dossier: what the organisation does, its strategy, recent inspection or annual reports, '
      'staff views, and the team\'s current projects and systems.',
    ),
  ],
  produce: [
    JourneyProduce('Fact notes: each claim with its link and date', kind: 'note'),
    JourneyProduce('Three "why here" points, each with its source', kind: 'list'),
    JourneyProduce('Three questions to ask the panel', kind: 'list'),
  ],
  check: JourneyCheck(
    kind: 'checklist',
    items: [
      'Every fact I would quote has a link and a date',
      'I can say what the organisation is working on this year',
      'I know the main systems the team uses',
    ],
  ),
  headsUp: [
    JourneyLine('Only quote facts you have found in the source itself, and say which year they are from.'),
  ],
);

const _contact = JourneyStage(
  id: 'contact',
  title: 'Contact the manager',
  order: 2,
  teach: [_contactInvited, _contactBackfires, _contactWhat],
  produce: [
    JourneyProduce('Call plan: three questions about the team and what I would bring', kind: 'plan'),
    JourneyProduce('Notes from the call', kind: 'note'),
  ],
  check: JourneyCheck(
    kind: 'interviewer',
    prompt: 'A short, friendly practice round to rehearse saying what you would bring.',
  ),
  headsUp: [
    JourneyLine('Do not ask about pay on an informal call.'),
    JourneyLine('Log the call as a contact in Udyoga, so you can follow it up.'),
  ],
);

const _followUp = JourneyStage(
  id: 'follow-up',
  title: 'Wait and follow up',
  order: 4,
  teach: [
    JourneyLine('Shortlisting often takes one to two weeks after the closing date; employers vary.'),
    JourneyLine('If a shortlisting date has passed with no word, one polite email to ask is fine.'),
  ],
  produce: [
    JourneyProduce('One chase email, ready to send', kind: 'email'),
    JourneyProduce('Calendar note for the shortlisting date', kind: 'note'),
  ],
  check: JourneyCheck(
    kind: 'checklist',
    items: [
      'I know the shortlisting date, or when to ask',
      'My chase email is written',
      'I kept a copy of the advert and of what I sent',
    ],
  ),
  headsUp: [
    JourneyLine(
      'Silence is common and is not a judgement on you. Keep applying for other posts while you wait.',
    ),
  ],
);

const _prepareProduce = [
  JourneyProduce('Story bank: one story for each criterion', kind: 'list'),
  JourneyProduce('Three-bullet cards for each story', kind: 'list'),
  JourneyProduce('Presentation, if the invite asks for one', kind: 'document'),
];
const _prepareCheck = JourneyCheck(
  kind: 'interviewer',
  prompt:
      'Spoken rounds on the job\'s criteria, scored only on lines quoted from your answers. Cover every '
      'criterion before polishing any one answer.',
);
const _prepareHeadsUp = [
  JourneyLine('Panels are trained to look neutral. A still face does not mean it is going badly.'),
  JourneyLine('A few "ums" are fine. Do not learn scripts word for word: it sounds rehearsed.'),
];

const _interviewDay = JourneyStage(
  id: 'interview-day',
  title: 'Interview day',
  order: 6,
  teach: [
    JourneyLine('Plan the journey, or test the video link, the day before.'),
    JourneyLine('Have a recovery line ready, such as "Can I take a moment to think about that?"'),
  ],
  produce: [
    JourneyProduce('One-page day sheet: time, place, names, three stories, two questions', kind: 'plan'),
  ],
  check: JourneyCheck(
    kind: 'checklist',
    items: [
      'Route or video link tested',
      'Day sheet printed or on my phone',
      'Documents the invite asked for are ready',
    ],
  ),
  headsUp: [JourneyLine('Vidya is for practice only. Do not use any AI helper during a real interview.')],
);

const _after = JourneyStage(
  id: 'after',
  title: 'After the interview',
  order: 7,
  teach: [_askFeedback, _thankYouOptional],
  produce: [
    JourneyProduce('Feedback request email', kind: 'email'),
    JourneyProduce('Feedback log: the score or comment for each question', kind: 'log'),
  ],
  check: JourneyCheck(kind: 'self', prompt: 'Turn each weak criterion from the feedback into a drill.'),
  headsUp: [JourneyLine('Ask within a week, while the panel still remembers you.')],
);

const _offerProduce = [
  JourneyProduce('Reply emails: accept, decline and withdraw', kind: 'email'),
  JourneyProduce('Notice letter to your current employer', kind: 'document'),
];
const _offerHeadsUp = [
  JourneyLine('Ask about your starting pay once, in writing, before you accept.'),
  JourneyLine('Once you accept, withdraw your other applications politely.'),
];

const _joiningProduce = [
  JourneyProduce('Day-one list', kind: 'list'),
  JourneyProduce('Names and roles of the people you work with', kind: 'list'),
  JourneyProduce('Training record', kind: 'log'),
];
const _joiningCheck = JourneyCheck(
  kind: 'self',
  prompt: 'Make flashcards for names, acronyms and systems, and review them through the first weeks.',
);

const _ninetyProduce = [
  JourneyProduce('30/60/90-day plan', kind: 'plan'),
  JourneyProduce('Weekly log of wins and evidence', kind: 'log'),
];
const _ninetyCheck = JourneyCheck(
  kind: 'self',
  prompt: 'A monthly check-in: what went well, what to fix, and what your manager said.',
);
const _ninetyHeadsUp = [
  JourneyLine('Own mistakes early, take notes, and learn the unwritten rules before changing things.'),
];

const _growCheck = JourneyCheck(
  kind: 'self',
  prompt: 'Check your readiness against the next role\'s criteria.',
);

// ---- the templates ----

/// NHS posts (Agenda for Change). Pay figures are for England.
const nhsTemplate = Journey(
  sector: 'nhs',
  template: 'NHS',
  checked: templatesChecked,
  stages: [
    JourneyStage(
      id: 'decide',
      title: 'Decide',
      order: 0,
      teach: [
        JourneyLine(
          'Read the advert, job description and person specification together. Every later stage hangs off '
          'the specification\'s criteria.',
        ),
        _scoredOnWhatYouSay,
        _nhsPay,
        _bottomOfBand,
      ],
      produce: _decideProduce,
      check: _decideCheck,
      headsUp: _decideHeadsUp,
    ),
    _research,
    _contact,
    JourneyStage(
      id: 'apply',
      title: 'Apply',
      order: 3,
      teach: [_eachCriterion, _specWording, _wordBudget, _oneExample],
      produce: [
        JourneyProduce('Supporting statement draft', kind: 'document'),
        JourneyProduce('Evidence map: one example for each criterion', kind: 'table'),
      ],
      check: JourneyCheck(
        kind: 'coverage',
        prompt:
            'Paste your draft statement. Vidya checks that each essential criterion\'s words appear in it.',
      ),
      headsUp: [
        JourneyLine(
          'Keep your own copy of the advert, the specification and what you sent: adverts come down.',
        ),
      ],
    ),
    _followUp,
    JourneyStage(
      id: 'prepare',
      title: 'Prepare',
      order: 5,
      teach: [
        _scoredOnWhatYouSay,
        JourneyLine(
          'Predict questions from the specification first, then the organisation\'s values, then questions '
          'other candidates report.',
        ),
        JourneyLine('Have an example ready for each of the organisation\'s values.'),
        JourneyLine('Practise aloud with an interviewer who keeps asking "why?", not from a script.'),
      ],
      produce: _prepareProduce,
      check: _prepareCheck,
      headsUp: _prepareHeadsUp,
    ),
    _interviewDay,
    _after,
    JourneyStage(
      id: 'offer',
      title: 'Offer',
      order: 8,
      teach: [
        JourneyLine(
          'A conditional offer depends on checks such as references, DBS and health; it becomes unconditional '
          'when they are done.',
        ),
        _bottomOfBand,
        _experienceCredit,
        _experienceCreditScotland,
        _nhsPay,
      ],
      produce: [
        JourneyProduce(
          'Evidence table for the pay point: each role, its dates, completed years',
          kind: 'table',
        ),
        ..._offerProduce,
      ],
      check: JourneyCheck(
        kind: 'quiz',
        questions: [
          {
            'question': 'You move from Band 4 to Band 5. Where does your pay normally start?',
            'kind': 'choice',
            'options': ['The bottom pay point of Band 5', 'Your old pay plus one step', 'The top of Band 5'],
            'answer': 'The bottom pay point of Band 5',
            'explain': 'Pay on promotion is normally the minimum of the new band (Annex 23, paragraph 11).',
          },
          {
            'question': 'When should you ask about starting higher up the band for your experience?',
            'kind': 'choice',
            'options': [
              'Before accepting the offer, in writing',
              'On your first day',
              'At your first appraisal',
            ],
            'answer': 'Before accepting the offer, in writing',
            'explain': 'Policies say a higher starting point must be agreed before the offer is accepted.',
          },
          {
            'question': 'Is a higher starting point for experience a right?',
            'kind': 'choice',
            'options': ['No, it is at the employer\'s discretion', 'Yes, always'],
            'answer': 'No, it is at the employer\'s discretion',
            'explain': 'It is discretionary and often counts completed years only.',
          },
        ],
      ),
      headsUp: _offerHeadsUp,
    ),
    JourneyStage(
      id: 'checks',
      title: 'Checks',
      order: 9,
      teach: [
        JourneyLine(
          'References: if you work in the NHS now, they cover the 6 months before the offer letter; otherwise '
          'they cover 3 years.',
          source: _references,
        ),
        JourneyLine(
          'Moving from one NHS employer to another, say yes to the Inter Authority Transfer (IAT) when you '
          'accept the conditional offer.',
          source: _iat,
        ),
        JourneyLine(
          'The IAT moves your mandatory training record, continuous service and leave details, if your old '
          'employer acts on it.',
          source: _iatGuide,
        ),
        JourneyLine('Expect a DBS check at the level the post needs and an occupational health form.'),
      ],
      produce: [
        JourneyProduce(
          'Checks list with due dates: ID, right to work, references, DBS, health, payroll',
          kind: 'list',
        ),
      ],
      check: JourneyCheck(
        kind: 'checklist',
        items: [
          'ID and right to work sent',
          'Referees told, and their details are right',
          'DBS form done',
          'Health questionnaire done',
          'IAT consent given (NHS to NHS only)',
        ],
      ),
      headsUp: [
        JourneyLine('Slow replies delay your start date: remind your referees.'),
        JourneyLine('Keep copies of your training certificates.'),
      ],
    ),
    JourneyStage(
      id: 'joining',
      title: 'Joining',
      order: 10,
      teach: [
        JourneyLine(
          'Induction covers mandatory training, access to systems (smartcard, records systems) and who\'s who.',
        ),
      ],
      produce: _joiningProduce,
      check: _joiningCheck,
      headsUp: [
        JourneyLine('Transferred training records may not show on day one, so keep your certificates.'),
      ],
    ),
    JourneyStage(
      id: 'first-90-days',
      title: 'First 90 days',
      order: 11,
      teach: [
        JourneyLine(
          'NHS trusts usually set a probation period of about 6 months, and appraisal often starts after it.',
          source: _nhsProbation,
        ),
        _employmentRightsLine,
        JourneyLine(
          'Agree objectives early, ask for feedback each month and log the wins your manager cares about.',
        ),
      ],
      produce: _ninetyProduce,
      check: _ninetyCheck,
      headsUp: _ninetyHeadsUp,
    ),
    JourneyStage(
      id: 'grow',
      title: 'Grow',
      order: 12,
      teach: [
        JourneyLine(
          'Moving up the pay points in a band depends on appraisal and local policy (Agenda for Change '
          'Annex 23).',
          source: _payPromotion,
        ),
        JourneyLine('Read the next band\'s person specification and map your evidence to it.'),
      ],
      produce: [
        JourneyProduce('Appraisal (PDR) preparation', kind: 'document'),
        JourneyProduce('Evidence mapped to the next role\'s specification', kind: 'table'),
      ],
      check: _growCheck,
      headsUp: [JourneyLine('Stretch work and a good reputation count for more than time served.')],
    ),
  ],
);

/// University posts: grades in place of bands.
const universityTemplate = Journey(
  sector: 'university',
  template: 'University',
  checked: templatesChecked,
  stages: [
    JourneyStage(
      id: 'decide',
      title: 'Decide',
      order: 0,
      teach: [
        JourneyLine(
          'Read the further particulars and person specification together. Universities often mark each '
          'criterion as assessed at application, at interview, or both.',
        ),
        _scoredOnWhatYouSay,
        JourneyLine(
          'Pay is set by grade and pay point. Check the grade\'s range on the university\'s own pay page.',
        ),
      ],
      produce: _decideProduce,
      check: _decideCheck,
      headsUp: _decideHeadsUp,
    ),
    _research,
    _contact,
    JourneyStage(
      id: 'apply',
      title: 'Apply',
      order: 3,
      teach: [_eachCriterion, _specWording, _wordBudget, _oneExample],
      produce: [
        JourneyProduce('Supporting statement draft', kind: 'document'),
        JourneyProduce('Evidence map: one example for each criterion marked "application"', kind: 'table'),
      ],
      check: JourneyCheck(
        kind: 'coverage',
        prompt:
            'Paste your draft statement. Vidya checks that each essential criterion\'s words appear in it.',
      ),
      headsUp: [JourneyLine('Keep your own copy of the further particulars and of what you sent.')],
    ),
    _followUp,
    JourneyStage(
      id: 'prepare',
      title: 'Prepare',
      order: 5,
      teach: [
        _scoredOnWhatYouSay,
        JourneyLine(
          'Predict questions from the criteria marked "interview" first, then the university\'s strategy.',
        ),
        JourneyLine('Practise aloud with an interviewer who keeps asking "why?", not from a script.'),
      ],
      produce: _prepareProduce,
      check: _prepareCheck,
      headsUp: _prepareHeadsUp,
    ),
    _interviewDay,
    _after,
    JourneyStage(
      id: 'offer',
      title: 'Offer',
      order: 8,
      teach: [
        JourneyLine(
          'Your starting pay point within the grade follows the university\'s own policy. Ask, in writing and '
          'before you accept, whether your experience can start you higher.',
        ),
      ],
      produce: [
        JourneyProduce('Evidence table for the pay point: each role and its dates', kind: 'table'),
        ..._offerProduce,
      ],
      check: JourneyCheck(
        kind: 'checklist',
        items: [
          'Grade and pay point confirmed in writing',
          'Hours, fixed term or permanent, and probation length checked',
          'Notice period at my current job known',
        ],
      ),
      headsUp: _offerHeadsUp,
    ),
    JourneyStage(
      id: 'checks',
      title: 'Checks',
      order: 9,
      teach: [JourneyLine('Expect references, a right-to-work check and, for some posts, a DBS check.')],
      produce: [JourneyProduce('Checks list with due dates: ID, right to work, references', kind: 'list')],
      check: JourneyCheck(
        kind: 'checklist',
        items: ['ID and right to work sent', 'Referees told, and their details are right'],
      ),
      headsUp: [JourneyLine('Slow replies delay your start date: remind your referees.')],
    ),
    JourneyStage(
      id: 'joining',
      title: 'Joining',
      order: 10,
      teach: [
        JourneyLine('Induction covers mandatory training, staff card and system access, and who\'s who.'),
      ],
      produce: _joiningProduce,
      check: _joiningCheck,
    ),
    JourneyStage(
      id: 'first-90-days',
      title: 'First 90 days',
      order: 11,
      teach: [
        JourneyLine(
          'Probation for university support staff is often 6 months and can be extended: one published '
          'procedure allows up to 9.',
          source: _universityProbation,
        ),
        _employmentRightsLine,
        JourneyLine(
          'Agree objectives early, ask for feedback each month and log the wins your manager cares about.',
        ),
      ],
      produce: _ninetyProduce,
      check: _ninetyCheck,
      headsUp: _ninetyHeadsUp,
    ),
    JourneyStage(
      id: 'grow',
      title: 'Grow',
      order: 12,
      teach: [JourneyLine('Read the next grade\'s person specification and map your evidence to it.')],
      produce: [
        JourneyProduce('Appraisal preparation', kind: 'document'),
        JourneyProduce('Evidence mapped to the next role\'s specification', kind: 'table'),
      ],
      check: _growCheck,
    ),
  ],
);

/// Private companies, and the general template for other employers.
const privateTemplate = Journey(
  sector: 'private',
  template: 'Private company',
  checked: templatesChecked,
  stages: [
    JourneyStage(
      id: 'decide',
      title: 'Decide',
      order: 0,
      teach: [
        JourneyLine(
          'Read the advert and job description closely and list what they ask for. Every later stage hangs off '
          'that list.',
        ),
        JourneyLine('Check the company: what it sells, its size, and recent news.'),
      ],
      produce: _decideProduce,
      check: _decideCheck,
      headsUp: _decideHeadsUp,
    ),
    _research,
    _contact,
    JourneyStage(
      id: 'apply',
      title: 'Apply',
      order: 3,
      teach: [
        JourneyLine(
          'Tailor your CV and cover letter to the advert: lead with what it asks for, in its words.',
        ),
        _specWording,
        _oneExample,
      ],
      produce: [
        JourneyProduce('Tailored CV', kind: 'document'),
        JourneyProduce('Cover letter draft', kind: 'document'),
      ],
      check: JourneyCheck(
        kind: 'coverage',
        prompt:
            'Paste your cover letter. Vidya checks that each essential requirement\'s words appear in it.',
      ),
      headsUp: [JourneyLine('Keep your own copy of the advert and of what you sent.')],
    ),
    _followUp,
    JourneyStage(
      id: 'prepare',
      title: 'Prepare',
      order: 5,
      teach: [
        JourneyLine('Interviewers often score against a list of what the role needs. Cover every item.'),
        JourneyLine(
          'Predict questions from the job description first, then the company\'s values and products.',
        ),
        JourneyLine('Practise aloud with an interviewer who keeps asking "why?", not from a script.'),
      ],
      produce: _prepareProduce,
      check: _prepareCheck,
      headsUp: _prepareHeadsUp,
    ),
    _interviewDay,
    _after,
    JourneyStage(
      id: 'offer',
      title: 'Offer',
      order: 8,
      teach: [
        JourneyLine(
          'Private employers often have more room on pay than the public sector. Ask once, with reasons.',
        ),
        JourneyLine('Read the contract: pay, hours, notice, probation and any restrictions after you leave.'),
      ],
      produce: [
        JourneyProduce('Reasons for the pay you ask for', kind: 'note'),
        ..._offerProduce,
      ],
      check: JourneyCheck(
        kind: 'checklist',
        items: [
          'Pay and benefits confirmed in writing',
          'Hours, notice and probation length checked',
          'Notice period at my current job known',
        ],
      ),
      headsUp: _offerHeadsUp,
    ),
    JourneyStage(
      id: 'checks',
      title: 'Checks',
      order: 9,
      teach: [JourneyLine('Expect references and a right-to-work check; some roles add background checks.')],
      produce: [JourneyProduce('Checks list with due dates: ID, right to work, references', kind: 'list')],
      check: JourneyCheck(
        kind: 'checklist',
        items: ['ID and right to work sent', 'Referees told, and their details are right'],
      ),
      headsUp: [JourneyLine('Slow replies delay your start date: remind your referees.')],
    ),
    JourneyStage(
      id: 'joining',
      title: 'Joining',
      order: 10,
      teach: [JourneyLine('Use the first weeks to learn the people, the products and the tools.')],
      produce: _joiningProduce,
      check: _joiningCheck,
    ),
    JourneyStage(
      id: 'first-90-days',
      title: 'First 90 days',
      order: 11,
      teach: [
        JourneyLine('Probation in private companies is commonly 3 to 6 months; your contract says which.'),
        _employmentRightsLine,
        JourneyLine(
          'Agree objectives early, ask for feedback each month and log the wins your manager cares about.',
        ),
      ],
      produce: _ninetyProduce,
      check: _ninetyCheck,
      headsUp: _ninetyHeadsUp,
    ),
    JourneyStage(
      id: 'grow',
      title: 'Grow',
      order: 12,
      teach: [
        JourneyLine('Find out how reviews and pay rises work, and map your evidence to the next role up.'),
      ],
      produce: [
        JourneyProduce('Review preparation', kind: 'document'),
        JourneyProduce('Evidence mapped to the next role', kind: 'table'),
      ],
      check: _growCheck,
    ),
  ],
);

/// The template for [sector]. The Civil Service and other employers get
/// the private-company stages, named as the general template.
Journey templateFor(String sector) => switch (sector) {
  'nhs' => nhsTemplate,
  'university' => universityTemplate,
  'private' => privateTemplate,
  _ => Journey(
    sector: sector,
    template: 'General',
    checked: templatesChecked,
    stages: privateTemplate.stages,
  ),
};
