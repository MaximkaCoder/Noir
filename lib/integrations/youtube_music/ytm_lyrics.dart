import 'package:freezed_annotation/freezed_annotation.dart' show immutable;
import 'package:noir/integrations/youtube_music/json_nav.dart';

/// Lyrics as YouTube Music shows them: time-synced [lines] when it has
/// them, otherwise plain [text].
@immutable
class YtmLyrics {
  const YtmLyrics({this.lines, this.text, this.provider});

  /// Lines with start and end times; null for plain lyrics.
  final List<YtmLyricLine>? lines;

  /// Plain lyrics; null when [lines] are set.
  final String? text;

  /// Who licensed them to YouTube Music ("Musixmatch", "LyricFind"), from
  /// its "Source: …" note.
  final String? provider;
}

@immutable
class YtmLyricLine {
  const YtmLyricLine(this.start, this.end, this.text);

  final Duration start;
  final Duration end;

  /// Empty for instrumental breaks (YouTube Music shows "♪").
  final String text;
}

/// The browse id of a song's Lyrics tab (`MPLY…`) in an InnerTube `next`
/// response; null when the tab has none (no lyrics). Searched for anywhere
/// in the response, so a reshuffled layout still finds it.
String? parseLyricsBrowseId(Map<String, Object?> json) {
  String? found;
  void walk(Object? node) {
    if (found != null) return;
    if (node is Map) {
      final id = node['browseId'];
      if (id is String && id.startsWith('MPLY')) {
        found = id;
        return;
      }
      node.values.forEach(walk);
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(json['contents']);
  return found;
}

/// Time-synced lyrics from a lyrics `browse` answered for the Android app
/// (`timedLyricsModel.lyricsData`); null when it has none.
YtmLyrics? parseTimedLyrics(Map<String, Object?> json) {
  final data = _find(json['contents'], 'timedLyricsData');
  if (data is! List) return null;
  final lines = <YtmLyricLine>[];
  for (final entry in data) {
    final text = navString(entry, ['lyricLine']);
    final cue = navMap(entry, ['cueRange']);
    final start = _ms(cue?['startTimeMilliseconds']);
    final end = _ms(cue?['endTimeMilliseconds']);
    if (text == null || start == null) continue;
    final line = text.trim();
    lines.add(YtmLyricLine(start, end ?? start, line == '♪' ? '' : line));
  }
  if (!lines.any((l) => l.text.isNotEmpty)) return null;
  lines.sort((a, b) => a.start.compareTo(b.start));
  final message = _find(json['contents'], 'sourceMessage');
  return YtmLyrics(
    lines: lines,
    provider: _provider(message is String ? message : textOf(message)),
  );
}

/// Plain lyrics from a lyrics `browse` answered for the web client
/// (`musicDescriptionShelfRenderer`); null when it has none.
YtmLyrics? parsePlainLyrics(Map<String, Object?> json) {
  final shelf = _find(json['contents'], 'musicDescriptionShelfRenderer');
  if (shelf is! Map) return null;
  final text = navList(shelf, [
    'description',
    'runs',
  ]).map((r) => navString(r, ['text']) ?? '').join().trim();
  if (text.isEmpty) return null;
  return YtmLyrics(
    text: text,
    provider: _provider(
      navList(shelf, [
        'footer',
        'runs',
      ]).map((r) => navString(r, ['text']) ?? '').join(),
    ),
  );
}

/// "Source: Musixmatch" → "Musixmatch".
String? _provider(String? message) {
  final m = message?.trim();
  if (m == null || m.isEmpty) return null;
  final colon = m.indexOf(':');
  final name = (colon < 0 ? m : m.substring(colon + 1)).trim();
  return name.isEmpty ? null : name;
}

Duration? _ms(Object? value) {
  final ms = switch (value) {
    final int v => v,
    final String v => int.tryParse(v),
    _ => null,
  };
  return ms == null || ms < 0 ? null : Duration(milliseconds: ms);
}

/// The first value under [key] anywhere in [node], depth first.
Object? _find(Object? node, String key) {
  if (node is Map) {
    if (node.containsKey(key)) return node[key];
    for (final v in node.values) {
      final found = _find(v, key);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = _find(v, key);
      if (found != null) return found;
    }
  }
  return null;
}
