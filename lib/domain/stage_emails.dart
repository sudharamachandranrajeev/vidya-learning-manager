/// Email and contact templates for the later journey stages (J8): asking
/// for an informal call and planning it, a polite chase after the closing
/// date, asking for feedback by criterion, an optional thank-you, replies
/// to an offer and a notice letter. UK English, short, and editable: the
/// app fills in what the journey knows (employer, role, closing date) and
/// what the learner typed (the manager's name only when they entered it);
/// anything still missing stays in [square brackets] for them to fill.
///
/// Each template carries the heads-ups that apply to it, each line with its
/// dated source or labelled general advice. Nothing here is ever sent: the
/// learner copies a filled template, or hands it to Udyoga's Conversations.
library;

import 'journey.dart';
import 'journey_templates.dart' show templatesChecked;

/// The day the sources added for the stage packs were checked.
const packsChecked = '2026-11-22';

// ---- sources (checked on [templatesChecked] or [packsChecked]) ----

const rcnVisitsSource = JourneySource(
  url: 'https://www.rcn.org.uk/Professional-Development/Your-career/Informal-Visits',
  title: 'RCN: informal visits',
  date: templatesChecked,
);
const informalChatSource = JourneySource(
  url: 'https://www.mumsnet.com/talk/work/5360451-pre-application-informal-chat',
  title: 'Mumsnet thread: pre-application informal chat (personal accounts)',
  date: templatesChecked,
);
const feedbackSource = JourneySource(
  url: 'https://www.mumsnet.com/talk/work/4517463-nhs-interview-scoring',
  title: 'Mumsnet thread: NHS interview scoring (personal accounts)',
  date: templatesChecked,
);
const thankYouSource = JourneySource(
  url: 'https://uk.finance.yahoo.com/news/divisive-problem-employers-obsessed-thank-letters-post-interview-142929514.html',
  title: 'Yahoo Finance UK: employers and thank-you letters',
  date: templatesChecked,
);
const startingSalarySource = JourneySource(
  url: 'https://foi.ghc.nhs.uk/wp-content/uploads/2026/05/4.3-Starting-Salary.pdf',
  title: 'An NHS trust starting salary policy (2026)',
  date: templatesChecked,
);
const acasNoticeSource = JourneySource(
  url: 'https://www.acas.org.uk/notice-periods/notice-when-resigning',
  title: 'Acas: notice when resigning',
  date: packsChecked,
);

// ---- heads-ups ----

const _noPay = JourneyLine('Do not ask about pay on an informal call: keep it about the team and the work.');
const _invited = JourneyLine(
  'Many adverts invite an informal chat, and nursing guidance says managers are impressed by approaches made '
  'before applying.',
  source: rcnVisitsSource,
);
const _backfires = JourneyLine(
  'It can backfire: people report callers who did not get through. Keep it short and about the job.',
  source: informalChatSource,
);
const _oneChase = JourneyLine(
  'Chase once, politely, after the shortlisting date or about two weeks after the closing date.',
);
const _askByCriterion = JourneyLine(
  'Feedback is patchy. Ask for it criterion by criterion, ask what a higher score would have needed, and take '
  'a phone call if one is offered.',
  source: feedbackSource,
);
const _withinAWeek = JourneyLine('Ask within a week, while the panel still remembers you.');
const _thankYouOptional = JourneyLine(
  'Optional: a thank-you email is not expected by many UK employers. Send one only if you want to.',
  source: thankYouSource,
);
const _stepBeforeAccepting = JourneyLine(
  'A higher starting point for experience is discretionary, often counts completed years only, and must be '
  'agreed before you accept. Ask once, in writing, before you accept.',
  source: startingSalarySource,
);
const _acceptInWriting = JourneyLine(
  'Accept in writing and keep a copy. If the offer is conditional, do not resign until the checks are done.',
);
const _withdrawPolitely = JourneyLine(
  'Withdraw from other applications politely and promptly: you may apply to the same employers again.',
);
const _noticeMinimum = JourneyLine(
  'After one month in a job you must give at least one week\'s notice, but your contract or staff policy may '
  'ask for more: check it before you set a last day.',
  source: acasNoticeSource,
);
const _noticeInWriting = JourneyLine(
  'Put any agreement about your notice or last day in writing.',
  source: acasNoticeSource,
);

// ---- the templates ----

/// The fill-ins a template can use, with what the learner is asked for.
/// `employer`, `role` and `closes` come from the journey; the rest the
/// learner types once on the Journey page.
const emailFills = {
  'manager': 'Hiring manager\'s name (only if you know it)',
  'myName': 'Your name',
  'currentEmployer': 'Your current employer',
  'currentRole': 'Your current job title',
  'currentManager': 'Your current manager\'s name',
  'interviewDate': 'Interview date',
  'startDate': 'Start date',
  'lastDay': 'Your last working day',
  'otherEmployer': 'The other employer you are withdrawing from',
  'otherRole': 'The other post you are withdrawing from',
};

class EmailTemplate {
  const EmailTemplate({
    required this.id,
    required this.stage,
    required this.title,
    required this.body,
    this.subject = '',
    this.kind = 'email',
    this.headsUp = const [],
    this.optional = false,
  });

  final String id;

  /// The journey stage it belongs to.
  final String stage;
  final String title, subject, body;

  /// `email`, or `plan` for notes the learner keeps (the call plan).
  final String kind;
  final List<JourneyLine> headsUp;

  /// Shown as optional (the UK thank-you).
  final bool optional;
}

const emailTemplates = [
  EmailTemplate(
    id: 'informal-call',
    stage: 'contact',
    title: 'Ask for an informal call',
    subject: 'Informal chat about the {role} post',
    body:
        '{greeting}\n\n'
        'I am interested in the {role} post at {employer} and would value a short informal chat before I apply, '
        'to learn more about the team and its current work.\n\n'
        'Would you have 15 minutes in the next few days? I can fit around you.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_noPay, _invited, _backfires],
  ),
  EmailTemplate(
    id: 'call-plan',
    stage: 'contact',
    title: 'Call plan',
    kind: 'plan',
    body:
        'Call plan: {role} at {employer}\n\n'
        'Three questions about the team:\n'
        '1. What is the team working on this year?\n'
        '2. What would a good first six months in this post look like?\n'
        '3. What does the team find hardest at the moment?\n\n'
        'What I would bring (one sentence):\n'
        '[one sentence on the experience that fits the post best]\n\n'
        'Close: thank them, and ask whether there is anything they would like to see covered in an application.',
    headsUp: [_noPay, _backfires],
  ),
  EmailTemplate(
    id: 'chase',
    stage: 'follow-up',
    title: 'Polite chase after the closing date',
    subject: 'Application for {role}',
    body:
        '{greeting}\n\n'
        'I applied for the {role} post at {employer}, which closed on {closes}. I would be grateful to know '
        'whether shortlisting has taken place, or when I might hear.\n\n'
        'Thank you for your time.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_oneChase],
  ),
  EmailTemplate(
    id: 'feedback',
    stage: 'after',
    title: 'Ask for feedback by criterion',
    subject: 'Feedback on my interview for {role}',
    body:
        '{greeting}\n\n'
        'Thank you for interviewing me for the {role} post on {interviewDate}. I would be grateful for '
        'feedback so I can improve.\n\n'
        'If possible, could you tell me:\n'
        '- the score I got for each question or criterion, and the scale used;\n'
        '- for my lowest scores, what a higher score would have needed;\n'
        '- anything I did well that I should keep doing.\n\n'
        'I am happy to take this by phone if that is easier.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_askByCriterion, _withinAWeek],
  ),
  EmailTemplate(
    id: 'thank-you',
    stage: 'after',
    title: 'Thank-you email (optional)',
    subject: 'Thank you: {role} interview',
    optional: true,
    body:
        '{greeting}\n\n'
        'Thank you for your time on {interviewDate}. I enjoyed hearing about the team\'s work, and the interview '
        'made me more keen on the {role} post.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_thankYouOptional],
  ),
  EmailTemplate(
    id: 'step-query',
    stage: 'offer',
    title: 'Ask about the starting pay point (before accepting)',
    subject: 'Starting pay point for the {role} post',
    body:
        '{greeting}\n\n'
        'Thank you for the offer of the {role} post. Before I accept, could you confirm the pay point I would '
        'start on?\n\n'
        'I have [number] completed years of relevant experience, set out in the table below, and would like '
        'this considered for a starting point above the minimum. I can send evidence such as contracts or '
        'payslips.\n\n'
        '[paste your evidence table here]\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_stepBeforeAccepting],
  ),
  EmailTemplate(
    id: 'accept',
    stage: 'offer',
    title: 'Accept the offer',
    subject: 'Acceptance: {role}',
    body:
        '{greeting}\n\n'
        'Thank you for offering me the {role} post at {employer}. I am pleased to accept, subject to the '
        'pre-employment checks.\n\n'
        'I will return the forms promptly. My current notice period means I could start on {startDate}.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_acceptInWriting, _stepBeforeAccepting],
  ),
  EmailTemplate(
    id: 'decline',
    stage: 'offer',
    title: 'Decline the offer',
    subject: '{role} offer',
    body:
        '{greeting}\n\n'
        'Thank you for offering me the {role} post at {employer}, and for your time during the process. After '
        'careful thought I have decided not to accept.\n\n'
        'I hope our paths cross again.\n\n'
        'Kind regards,\n{myName}',
  ),
  EmailTemplate(
    id: 'withdraw',
    stage: 'offer',
    title: 'Withdraw another application',
    subject: 'Withdrawing my application: {otherRole}',
    body:
        'Dear Recruitment Team,\n\n'
        'I would like to withdraw my application for the {otherRole} post at {otherEmployer}, as I have accepted '
        'another offer.\n\n'
        'Thank you for considering me.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_withdrawPolitely],
  ),
  EmailTemplate(
    id: 'notice',
    stage: 'offer',
    title: 'Notice letter to your current employer',
    subject: 'Resignation: {myName}',
    body:
        'Dear {currentManager},\n\n'
        'Please accept this letter as notice of my resignation from my post as {currentRole} at '
        '{currentEmployer}. In line with my contract, my last working day will be {lastDay}.\n\n'
        'Thank you for your support during my time here. I will do all I can to hand over my work smoothly.\n\n'
        'Kind regards,\n{myName}',
    headsUp: [_noticeMinimum, _noticeInWriting],
  ),
];

/// The templates for [stage], in order.
List<EmailTemplate> emailTemplatesFor(String stage) => [
  for (final t in emailTemplates)
    if (t.stage == stage) t,
];

EmailTemplate? emailTemplate(String id) => emailTemplates.where((t) => t.id == id).firstOrNull;

/// A template with its fill-ins put in.
typedef FilledEmail = ({String subject, String body, List<String> missing});

final _slot = RegExp(r'\{(\w+)\}');

/// Fills [t] from the journey ([journey]: employer, role, closing date) and
/// the learner's [fills]. The greeting uses the manager's name only when
/// the learner entered it ("Dear Hiring Manager," otherwise). A fill-in
/// with no value becomes "[what it is]" and is listed in `missing`.
FilledEmail fillEmail(
  EmailTemplate t,
  Journey journey,
  Map<String, String> fills, {
  String Function(String)? date,
}) {
  final values = <String, String>{
    'employer': journey.employer,
    'role': journey.role,
    if (journey.closes != null) 'closes': date == null ? journey.closes! : date(journey.closes!),
    for (final e in fills.entries)
      if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
  };
  final manager = values['manager'];
  values['greeting'] = manager == null ? 'Dear Hiring Manager,' : 'Dear $manager,';
  final missing = <String>[];
  String fill(String text) => text.replaceAllMapped(_slot, (m) {
    final key = m[1]!;
    final v = values[key];
    if (v != null && v.isNotEmpty) return v;
    if (!missing.contains(key)) missing.add(key);
    return '[${_label(key)}]';
  });
  final subject = fill(t.subject), body = fill(t.body);
  return (subject: subject, body: body, missing: missing);
}

String _label(String key) => switch (key) {
  'employer' => 'employer',
  'role' => 'job title',
  'closes' => 'closing date',
  _ => (emailFills[key] ?? key).replaceAll(RegExp(r'\s*\(.*\)$'), '').toLowerCase(),
};

/// A filled email as one text to copy: the subject line, then the body.
String emailText(FilledEmail e) => e.subject.isEmpty ? e.body : 'Subject: ${e.subject}\n\n${e.body}';
