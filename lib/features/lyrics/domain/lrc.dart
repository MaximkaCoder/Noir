import 'package:flutter/foundation.dart';

/// One time-synced lyric line.
@immutable
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;

  /// Empty for instrumental breaks.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is LyricLine && other.time == time && other.text == text;

  @override
  int get hashCode => Object.hash(time, text);

  @override
  String toString() => 'LyricLine($time, $text)';
}

final _timestamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _offsetTag = RegExp(
  r'^\s*\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);
final _wordTimestamp = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

/// Parses LRC text into lines sorted by time.
///
/// Supports several timestamps per line (`[00:12.00][01:30.50] chorus`),
/// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, and the `[offset:±ms]` tag
/// (positive values show lyrics earlier). Metadata tags (`[ar:…]`, `[ti:…]`)
/// and word-level `<mm:ss.xx>` marks are dropped.
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
      final fraction = m.group(3);
      stamps.add(
        Duration(
          minutes: int.parse(m.group(1)!),
          seconds: int.parse(m.group(2)!),
          milliseconds: fraction == null
              ? 0
              : int.parse(fraction.padRight(3, '0').substring(0, 3)),
        ),
      );
      rest = rest.substring(m.end).trimLeft();
    }
    if (stamps.isEmpty) continue;
    final text = rest.replaceAll(_wordTimestamp, '').trim();
    for (final t in stamps) {
      lines.add(LyricLine(t, text));
    }
  }
  final shifted = offsetMs == 0
      ? lines
      : [
          for (final l in lines)
            LyricLine(
              Duration(
                milliseconds: (l.time.inMilliseconds - offsetMs).clamp(
                  0,
                  1 << 31,
                ),
              ),
              l.text,
            ),
        ];
  // List.sort isn't stable; keep source order for equal times.
  final indexed = shifted.indexed.toList()
    ..sort((a, b) {
      final byTime = a.$2.time.compareTo(b.$2.time);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, l) in indexed) l];
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
