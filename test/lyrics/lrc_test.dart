import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('parseLrc', () {
    test('reads timestamps in every precision', () {
      final lines = parseLrc(
        '[00:01] one\n[00:02.5] two\n[00:03.25] three\n[01:04.125] four',
      );
      expect(lines, [
        LyricLine(ms(1000), 'one'),
        LyricLine(ms(2500), 'two'),
        LyricLine(ms(3250), 'three'),
        LyricLine(ms(64125), 'four'),
      ]);
    });

    test('expands lines with several timestamps and sorts them', () {
      final lines = parseLrc('[00:10.00][00:30.00] chorus\n[00:20.00] verse');
      expect(lines.map((l) => (l.time.inSeconds, l.text)), [
        (10, 'chorus'),
        (20, 'verse'),
        (30, 'chorus'),
      ]);
    });

    test('ignores metadata tags and junk, keeps empty breaks', () {
      final lines = parseLrc(
        '[ar:Someone]\n[ti:Song]\n[length: 03:20]\nno timestamp\n'
        '[00:01.00] hi\r\n[00:02.00]\n',
      );
      expect(lines, [LyricLine(ms(1000), 'hi'), LyricLine(ms(2000), '')]);
    });

    test('applies the offset tag (positive shows earlier)', () {
      expect(parseLrc('[offset:+500]\n[00:02.00] a'), [
        LyricLine(ms(1500), 'a'),
      ]);
      expect(parseLrc('[offset:-250]\n[00:02.00] a'), [
        LyricLine(ms(2250), 'a'),
      ]);
      expect(parseLrc('[offset:900]\n[00:00.50] a'), [LyricLine(ms(0), 'a')]);
    });

    test('strips word-level timing marks', () {
      expect(parseLrc('[00:01.00] <00:01.00>Hello <00:01.50>world'), [
        LyricLine(ms(1000), 'Hello world'),
      ]);
    });

    test('keeps source order for equal times', () {
      final lines = parseLrc('[00:01.00] a\n[00:01.00] b');
      expect(lines.map((l) => l.text), ['a', 'b']);
    });
  });

  group('activeLineIndex', () {
    final lines = [
      LyricLine(ms(1000), 'a'),
      LyricLine(ms(2000), 'b'),
      LyricLine(ms(3000), 'c'),
    ];

    test('is -1 before the first line', () {
      expect(activeLineIndex(lines, ms(999)), -1);
      expect(activeLineIndex(const [], ms(5000)), -1);
    });

    test('switches exactly at a line start and holds until the next', () {
      expect(activeLineIndex(lines, ms(1000)), 0);
      expect(activeLineIndex(lines, ms(1999)), 0);
      expect(activeLineIndex(lines, ms(2000)), 1);
      expect(activeLineIndex(lines, ms(60000)), 2);
    });
  });
}
