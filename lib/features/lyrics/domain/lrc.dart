import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One time-synced lyric line.
@immutable
class LyricLine {
  const LyricLine(this.time, this.text, {this.words, this.wordsEnd});

  final Duration time;

  /// Empty for instrumental breaks.
  final String text;

  /// Word (or syllable) start times from enhanced LRC (`<mm:ss.xx>` marks),
  /// in order; null when the line has none.
  final List<LyricWord>? words;

  /// When the last of [words] ends, if the line closes with a bare mark.
  final Duration? wordsEnd;

  @override
  bool operator ==(Object other) =>
      other is LyricLine &&
      other.time == time &&
      other.text == text &&
      listEquals(other.words, words) &&
      other.wordsEnd == wordsEnd;

  @override
  int get hashCode => Object.hash(
    time,
    text,
    words == null ? null : Object.hashAll(words!),
    wordsEnd,
  );

  @override
  String toString() => 'LyricLine($time, $text)';
}

/// A timed piece of a line: the characters [from]–[to] of its text, sung
/// from [time].
@immutable
class LyricWord {
  const LyricWord(this.from, this.to, this.time);

  final int from;
  final int to;
  final Duration time;

  @override
  bool operator ==(Object other) =>
      other is LyricWord &&
      other.from == from &&
      other.to == to &&
      other.time == time;

  @override
  int get hashCode => Object.hash(from, to, time);

  @override
  String toString() => 'LyricWord($from–$to @ $time)';
}

/// A piece of a line with when it is sung: the characters [from]–[to],
/// filling from [start] to [end].
@immutable
class WordTiming {
  const WordTiming(this.from, this.to, this.start, this.end);

  final int from;
  final int to;
  final Duration start;
  final Duration end;

  /// How far the word has filled at [position], 0–1.
  double progressAt(Duration position) {
    if (position <= start) return 0;
    if (position >= end) return 1;
    return (position - start).inMicroseconds / (end - start).inMicroseconds;
  }

  @override
  bool operator ==(Object other) =>
      other is WordTiming &&
      other.from == from &&
      other.to == to &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(from, to, start, end);

  @override
  String toString() => 'WordTiming($from–$to, $start–$end)';
}

final _timestamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _offsetTag = RegExp(
  r'^\s*\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);
final _wordTimestamp = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

Duration _stamp(Match m) {
  final fraction = m.group(3);
  return Duration(
    minutes: int.parse(m.group(1)!),
    seconds: int.parse(m.group(2)!),
    milliseconds: fraction == null
        ? 0
        : int.parse(fraction.padRight(3, '0').substring(0, 3)),
  );
}

/// Parses LRC text into lines sorted by time.
///
/// Supports several timestamps per line (`[00:12.00][01:30.50] chorus`),
/// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, and the `[offset:±ms]` tag
/// (positive values show lyrics earlier). Metadata tags (`[ar:…]`, `[ti:…]`)
/// are dropped. Enhanced LRC word marks (`<mm:ss.xx>` before a word or
/// syllable, optionally one more closing the line) become
/// [LyricLine.words].
List<LyricLine> parseLrc(String source) {
  var offsetMs = 0;
  final lines = <LyricLine>[];
  for (final raw in source.split(RegExp(r'\r?\n'))) {
    final offset = _offsetTag.firstMatch(raw);
    if (offset != null) {
      offsetMs = int.parse(offset.group(1)!);
      continue;
    }
    // Timestamps must lead the line; anything else is a tag or noise.
    final stamps = <Duration>[];
    var rest = raw.trimLeft();
    while (true) {
      final m = _timestamp.matchAsPrefix(rest);
      if (m == null) break;
      stamps.add(_stamp(m));
      rest = rest.substring(m.end).trimLeft();
    }
    if (stamps.isEmpty) continue;
    final parsed = _parseWords(rest, stamps.first);
    for (final t in stamps) {
      // Word times belong to the first occurrence; repeats shift with it.
      final shift = t - stamps.first;
      lines.add(
        LyricLine(
          t,
          parsed.text,
          words: parsed.words == null
              ? null
              : [
                  for (final w in parsed.words!)
                    LyricWord(w.from, w.to, w.time + shift),
                ],
          wordsEnd: parsed.end == null ? null : parsed.end! + shift,
        ),
      );
    }
  }
  final shifted = offsetMs == 0
      ? lines
      : [for (final l in lines) _shift(l, -offsetMs)];
  // List.sort isn't stable; keep source order for equal times.
  final indexed = shifted.indexed.toList()
    ..sort((a, b) {
      final byTime = a.$2.time.compareTo(b.$2.time);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, l) in indexed) l];
}

Duration _clampTime(Duration d) =>
    Duration(milliseconds: d.inMilliseconds.clamp(0, 1 << 31));

LyricLine _shift(LyricLine l, int ms) {
  final by = Duration(milliseconds: ms);
  return LyricLine(
    _clampTime(l.time + by),
    l.text,
    words: l.words == null
        ? null
        : [
            for (final w in l.words!)
              LyricWord(w.from, w.to, _clampTime(w.time + by)),
          ],
    wordsEnd: l.wordsEnd == null ? null : _clampTime(l.wordsEnd! + by),
  );
}

/// Splits [rest] at `<mm:ss.xx>` marks into the plain text and its timed
/// pieces. Text before the first mark starts at [lineTime].
({String text, List<LyricWord>? words, Duration? end}) _parseWords(
  String rest,
  Duration lineTime,
) {
  final marks = _wordTimestamp.allMatches(rest).toList();
  if (marks.isEmpty) return (text: rest.trim(), words: null, end: null);

  final pieces = <(Duration, String)>[
    (lineTime, rest.substring(0, marks[0].start)),
  ];
  for (final (i, m) in marks.indexed) {
    final next = i + 1 < marks.length ? marks[i + 1].start : rest.length;
    pieces.add((_stamp(m), rest.substring(m.end, next)));
  }

  final text = StringBuffer();
  final words = <LyricWord>[];
  Duration? end;
  for (final (time, piece) in pieces) {
    if (piece.trim().isEmpty) {
      // A bare mark after the last word closes the line.
      if (words.isNotEmpty && time > words.last.time) end = time;
      text.write(piece);
      continue;
    }
    end = null;
    final lead = piece.length - piece.trimLeft().length;
    final from = text.length + lead;
    words.add(LyricWord(from, from + piece.trim().length, time));
    text.write(piece);
  }
  final raw = text.toString();
  final cut = raw.length - raw.trimLeft().length;
  return (
    text: raw.trim(),
    words: [for (final w in words) LyricWord(w.from - cut, w.to - cut, w.time)],
    end: end,
  );
}

/// Index of the line sung at [position]: the last line whose time is not
/// after it. -1 before the first line.
int activeLineIndex(List<LyricLine> lines, Duration position) {
  var lo = 0;
  var hi = lines.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time <= position) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// ---------------------------------------------------------------- karaoke --

/// Longest a single line is ever assumed to be sung.
const maxLineDuration = Duration(seconds: 8);

/// Rough singing pace, per character, for lines without word marks.
const _perCharacter = Duration(milliseconds: 90);

/// When line [index] has been sung: its closing word mark if it has one,
/// otherwise the next line's start — but no longer than [maxLineDuration],
/// nor much longer than its text takes to sing, so the fill doesn't crawl
/// through an instrumental gap before the next line.
Duration lineEnd(List<LyricLine> lines, int index) {
  final line = lines[index];
  if (line.wordsEnd case final end? when end > line.time) return end;
  final start = line.time;
  final next = index + 1 < lines.length
      ? lines[index + 1].time
      : start + maxLineDuration;
  final sung = _perCharacter * line.text.length;
  final expected = Duration(
    microseconds: (sung.inMicroseconds * 1.6).round().clamp(
      const Duration(milliseconds: 1500).inMicroseconds,
      maxLineDuration.inMicroseconds,
    ),
  );
  var span = next - start;
  if (span > expected) span = expected;
  if (span > maxLineDuration) span = maxLineDuration;
  final words = line.words;
  if (words != null && words.isNotEmpty) {
    // Leave the last marked word some time of its own.
    final last = words.last.time + const Duration(milliseconds: 300);
    if (start + span < last) return last;
  }
  return start + span;
}

/// The timed pieces of line [index]: its enhanced-LRC words when it has
/// them, otherwise [estimateWordTimings] over its span.
List<WordTiming> lineWordTimings(List<LyricLine> lines, int index) {
  final line = lines[index];
  final end = lineEnd(lines, index);
  final words = line.words;
  if (words == null || words.isEmpty) {
    return estimateWordTimings(line.text, line.time, end);
  }
  return [
    for (final (i, w) in words.indexed)
      WordTiming(
        w.from,
        w.to,
        w.time,
        i + 1 < words.length
            ? words[i + 1].time
            : (end > w.time ? end : w.time),
      ),
  ];
}

/// Spreads [start]–[end] over the words of [text], weighted by roughly how
/// many syllables each has (vowel groups, at least one) plus a small
/// constant per word, after a short lead-in and before a short lead-out.
/// The words cover that trimmed span exactly, back to back.
List<WordTiming> estimateWordTimings(
  String text,
  Duration start,
  Duration end,
) {
  final words = [
    for (final m in RegExp(r'\S+').allMatches(text)) (m.start, m.end),
  ];
  if (words.isEmpty || end <= start) {
    return [for (final (from, to) in words) WordTiming(from, to, start, start)];
  }
  final span = (end - start).inMicroseconds;
  final leadIn = math.min<double>(span * 0.04, 80000);
  final leadOut = math.min<double>(span * 0.1, 200000);
  final from = start.inMicroseconds + leadIn;
  final usable = span - leadIn - leadOut;
  final weights = [
    for (final (a, b) in words) syllableCount(text.substring(a, b)) + 0.6,
  ];
  final total = weights.fold<double>(0, (a, b) => a + b);
  final timings = <WordTiming>[];
  var at = from;
  for (final (i, (a, b)) in words.indexed) {
    final next = i == words.length - 1
        ? from + usable
        : at + usable * weights[i] / total;
    timings.add(
      WordTiming(
        a,
        b,
        Duration(microseconds: at.round()),
        Duration(microseconds: next.round()),
      ),
    );
    at = next;
  }
  return timings;
}

const _latinVowels = 'aeiouyàáâãäåæèéêëìíîïòóôõöøœùúûüýÿ';
const _cyrillicVowels = 'аеёиоуыэюяіїєў';

/// Syllables in [word], roughly: Latin vowel groups plus each Cyrillic
/// vowel; at least one.
int syllableCount(String word) {
  var count = 0;
  var inLatinGroup = false;
  for (final rune in word.toLowerCase().runes) {
    final c = String.fromCharCode(rune);
    if (_cyrillicVowels.contains(c)) {
      count++;
      inLatinGroup = false;
    } else if (_latinVowels.contains(c)) {
      if (!inLatinGroup) count++;
      inLatinGroup = true;
    } else {
      inLatinGroup = false;
    }
  }
  return math.max(count, 1);
}

/// Index of the word being sung at [position]: the last one that has
/// started. -1 before the first.
int activeWordIndex(List<WordTiming> words, Duration position) {
  var found = -1;
  for (final (i, w) in words.indexed) {
    if (w.start > position) break;
    found = i;
  }
  return found;
}
