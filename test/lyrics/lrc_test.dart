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

    test('plain lines carry no word timings', () {
      final line = parseLrc('[00:01.00] Hello world').single;
      expect(line.words, isNull);
      expect(line.wordsEnd, isNull);
    });
  });

  group('enhanced LRC', () {
    String piece(LyricLine l, LyricWord w) => l.text.substring(w.from, w.to);

    test('keeps per-word times and strips the marks from the text', () {
      final line = parseLrc(
        '[00:01.00] <00:01.00>Hello <00:01.50>big <00:02.25>world',
      ).single;
      expect(line.text, 'Hello big world');
      expect(line.words!.map((w) => piece(line, w)), ['Hello', 'big', 'world']);
      expect(line.words!.map((w) => w.time), [ms(1000), ms(1500), ms(2250)]);
      expect(line.wordsEnd, isNull);
    });

    test('text before the first mark starts with the line', () {
      final line = parseLrc('[00:04.00]Oh <00:04.40>yeah').single;
      expect(line.words, [
        const LyricWord(0, 2, Duration(seconds: 4)),
        const LyricWord(3, 7, Duration(milliseconds: 4400)),
      ]);
    });

    test('a closing mark ends the last word', () {
      final line = parseLrc('[00:10.00]<00:10.00>one <00:10.50>two <00:11.20>')
          .single;
      expect(line.text, 'one two');
      expect(line.words, hasLength(2));
      expect(line.wordsEnd, ms(11200));
    });

    test('syllable marks inside a word stay apart', () {
      final line = parseLrc('[00:01.00]<00:01.00>Hel<00:01.30>lo <00:01.80>you')
          .single;
      expect(line.text, 'Hello you');
      expect(line.words!.map((w) => piece(line, w)), ['Hel', 'lo', 'you']);
    });

    test('repeated lines and the offset shift word times too', () {
      final lines = parseLrc(
        '[offset:+500]\n[00:10.00][00:30.00]<00:10.00>la <00:11.00>la',
      );
      expect(lines.map((l) => l.time), [ms(9500), ms(29500)]);
      expect(lines.last.words!.map((w) => w.time), [ms(29500), ms(30500)]);
    });

    test('lineWordTimings uses the marks, ending at the next mark', () {
      final lines = parseLrc(
        '[00:01.00]<00:01.00>a <00:01.50>b <00:02.00>\n[00:05.00] next',
      );
      expect(lineWordTimings(lines, 0), [
        WordTiming(0, 1, ms(1000), ms(1500)),
        WordTiming(2, 3, ms(1500), ms(2000)),
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

  group('estimateWordTimings', () {
    Duration total(List<WordTiming> w) => w.last.end - w.first.start;

    test('covers the span back to back after a short lead-in/out', () {
      final words = estimateWordTimings(
        'never gonna give you up',
        ms(10000),
        ms(13000),
      );
      expect(words, hasLength(5));
      expect(words.first.start, greaterThan(ms(10000)));
      expect(words.first.start, lessThanOrEqualTo(ms(10080)));
      expect(words.last.end, lessThan(ms(13000)));
      expect(words.last.end, greaterThanOrEqualTo(ms(12800)));
      for (var i = 1; i < words.length; i++) {
        expect(words[i].start, words[i - 1].end);
      }
      // Lead-in and lead-out together are a small part of the line.
      expect(total(words), greaterThan(ms(2700)));
    });

    test('longer words get more time', () {
      final words = estimateWordTimings('I understand', ms(0), ms(2000));
      final short = words[0].end - words[0].start;
      final long = words[1].end - words[1].start;
      expect(long, greaterThan(short * 2));
    });

    test('counts Cyrillic vowels', () {
      expect(syllableCount('пісня'), 2);
      expect(syllableCount('моя'), 2);
      expect(syllableCount('beautiful'), 3);
      expect(syllableCount('rhythm'), 1);
      expect(syllableCount('—'), 1);
    });

    test('maps character ranges in the text', () {
      const text = '  hey   there ';
      final words = estimateWordTimings(text, ms(0), ms(1000));
      expect(words.map((w) => text.substring(w.from, w.to)), ['hey', 'there']);
    });
  });

  group('lineEnd', () {
    test('runs to the next line', () {
      final lines = [
        LyricLine(ms(1000), 'a fairly ordinary line of lyrics'),
        LyricLine(ms(3500), 'next'),
      ];
      expect(lineEnd(lines, 0), ms(3500));
    });

    test('caps lines before a long instrumental gap', () {
      final lines = [
        LyricLine(ms(1000), 'short line'),
        LyricLine(ms(40000), 'after the solo'),
      ];
      final end = lineEnd(lines, 0);
      expect(end - ms(1000), lessThan(const Duration(seconds: 3)));
      expect(end - ms(1000), greaterThanOrEqualTo(ms(1500)));
    });

    test('never exceeds the longest line', () {
      final lines = [LyricLine(ms(0), 'x' * 400)];
      expect(lineEnd(lines, 0), maxLineDuration);
    });

    test('estimated words of a capped line still sum to its span', () {
      final lines = [
        LyricLine(ms(1000), 'hold on'),
        LyricLine(ms(60000), 'later'),
      ];
      final words = lineWordTimings(lines, 0);
      expect(words.last.end, lessThan(lineEnd(lines, 0)));
      expect(words.first.start, greaterThanOrEqualTo(ms(1000)));
    });
  });

  group('activeWordIndex', () {
    final words = [
      WordTiming(0, 1, ms(1000), ms(1500)),
      WordTiming(2, 3, ms(1500), ms(2000)),
    ];

    test('follows the word being sung', () {
      expect(activeWordIndex(words, ms(999)), -1);
      expect(activeWordIndex(words, ms(1000)), 0);
      expect(activeWordIndex(words, ms(1700)), 1);
      expect(activeWordIndex(words, ms(9000)), 1);
    });

    test('progress fills within the word', () {
      expect(words[0].progressAt(ms(1250)), closeTo(0.5, 1e-9));
      expect(words[0].progressAt(ms(500)), 0);
      expect(words[0].progressAt(ms(1600)), 1);
    });
  });
}
