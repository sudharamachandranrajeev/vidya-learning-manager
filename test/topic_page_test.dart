import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/domain/curriculum.dart';

import 'app_harness.dart';

/// The topic page on a phone: opened from the course page, an item added
/// and marked done, and the topic ticked off with a note while a required
/// item is still open. Made-up plan.
void main() {
  testWidgets('a topic page on a phone: add an item, mark it done, tick off with a note', (tester) async {
    final app = AppHarness(tester)..phone();
    await app.open(
      seed: (b) => b.importCurriculum(
        parseCurriculum(
          jsonEncode({
            'format': 'vidya-curriculum',
            'version': 2,
            'program': {'title': 'Pottery teacher'},
            'criteria': [
              {'id': 'c1', 'text': 'Explain centering to a beginner', 'essential': true},
            ],
            'courses': [
              {
                'title': 'Wheel basics',
                'topics': [
                  {
                    'title': 'Centering',
                    'details': 'Brace your arms against your knees and keep the wheel fast.',
                    'criteria': ['c1'],
                    'items': [
                      {
                        'type': 'practice task',
                        'title': 'Center 1 kg of clay three times in a row without stopping',
                        'required': true,
                      },
                    ],
                    'quiz': [
                      {'question': 'Which hand braces?', 'answer': 'Left'},
                    ],
                    'drills': [
                      {'question': 'How would you teach centering?', 'criterion': 'c1'},
                    ],
                  },
                ],
              },
            ],
          }),
        ),
        today: '2026-11-21',
      ),
    );
    await app.run();
    await app.go('Learn');
    await app.tapText('Pottery teacher');
    await app.tapText('Wheel basics');
    expect(find.text('30 min · 0 of 3 items'), findsOneWidget);
    await app.tapText('Centering');

    expect(find.text('Why it matters'), findsOneWidget);
    expect(find.text('• Explain centering to a beginner (essential)'), findsOneWidget);
    expect(find.textContaining('Brace your arms'), findsOneWidget);
    expect(find.text('Quiz: Centering'), findsOneWidget);
    expect(find.textContaining('tests Explain centering'), findsOneWidget);

    await app.tap(find.byTooltip('Add item'));
    await app.enter('Title', 'Centering talk with a long title that has to wrap on a phone screen');
    await app.enter('Link', 'https://example.org/centering');
    await app.tapText('Save');
    final tile = find.ancestor(of: find.textContaining('Centering talk'), matching: find.byType(ListTile));
    expect(tile, findsOneWidget);

    await app.tap(find.descendant(of: tile, matching: find.byType(Checkbox)));
    expect(find.descendant(of: tile, matching: find.textContaining('Done today')), findsOneWidget);
    expect(find.text('Studying'), findsOneWidget);

    await app.tapText('Tick off topic');
    expect(find.text('Tick off anyway?'), findsOneWidget);
    await app.tapText('Tick off');
    expect(find.text('Write a short note first.'), findsOneWidget);
    await app.enter('Why it is done', 'I teach this already');
    await app.tapText('Tick off');
    expect(find.text('Ticked off because: I teach this already'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await app.close();
  });
}
