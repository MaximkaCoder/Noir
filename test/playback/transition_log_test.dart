import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/playback/application/transition_log.dart';

void main() {
  test('keeps the newest lines in memory and on disk, size-capped', () async {
    final dir = Directory.systemTemp.createTempSync('noir_log');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/logs/transitions.log');
    final log = TransitionLog(file: file, capacity: 5, maxBytes: 2000);
    for (var i = 0; i < 100; i++) {
      log.add('line $i ${'x' * 40}');
    }
    await log.flush();
    expect(log.lines, hasLength(5));
    expect(log.lines.last, contains('line 99'));
    final text = file.readAsStringSync();
    expect(text.length, lessThan(2000 + 200));
    expect(text, contains('line 99'));
    expect(text, isNot(contains('line 0 ')));
    // Whole lines only after trimming.
    expect(text.split('\n').first, matches(RegExp(r'^\d{4}-')));
  });

  test('works without a file', () {
    final log = TransitionLog()..add('hello');
    expect(log.lines.single, endsWith('hello'));
  });
}
