import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vidya/ui/zen.dart';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (max(x, y) + 0.05) / (min(x, y) + 0.05);
}

void main() {
  for (final b in Brightness.values) {
    test('toast text is readable in ${b.name} mode', () {
      final s = vidyaTheme(b).snackBarTheme;
      final bg = s.backgroundColor!;
      final fg = s.contentTextStyle!.color!;
      // WCAG AA for normal text.
      expect(_contrast(bg, fg), greaterThanOrEqualTo(4.5));
    });
  }
}
