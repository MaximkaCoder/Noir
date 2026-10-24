/// Turns messy track metadata — mostly YouTube video titles and channel
/// names — into (artist, title) guesses a lyrics service can look up.
///
/// Pure functions; see test/lyrics/song_guess_test.dart for the cases.
library;

/// One lookup candidate. `artist` is null when nothing artist-like is known.
typedef SongGuess = ({String? artist, String title});

const _noiseWords = [
  'official',
  'video',
  'audio',
  'lyric',
  'lyrics',
  'clip',
  'visualizer',
  'visualiser',
  'hd',
  'hq',
  '4k',
  '8k',
  '1080p',
  '720p',
  'remaster',
  'remastered',
  'mv',
  'm/v',
  'explicit',
  'color coded',
  'teaser',
  'premiere',
  'out now',
];

final _noise = RegExp(
  r'(^|[^\p{L}\p{N}])('
  '${_noiseWords.map(RegExp.escape).join('|')}'
  r')(?=$|[^\p{L}\p{N}])',
  caseSensitive: false,
  unicode: true,
);
final _bracketed = RegExp(r'\s*(\([^()]*\)|\[[^\[\]]*\]|【[^【】]*】|「[^「」]*」)');
final _feat = RegExp(
  r'^\s*(feat\.?|ft\.?|featuring|with)\s',
  caseSensitive: false,
);
final _featTail = RegExp(
  r'\s+(feat\.?|ft\.?|featuring)\s.*$',
  caseSensitive: false,
);
final _trailingNoise = RegExp(
  r'\s+(official\s+)?(music\s+|lyrics?\s+)?(video|audio|visuali[sz]er)$',
  caseSensitive: false,
);
final _hashtags = RegExp(r'(\s+#[^\s#]+)+\s*$');
final _dash = RegExp(r'\s+[-–—]\s+');
final _pipe = RegExp(r'\s*[|｜]\s*');
final _quoted = RegExp(r'^(.+?)\s*["“”«]([^"“”«»]+)["“”»](.*)$');

/// "Artist - Topic", "ArtistVEVO", "Artist Official" → "Artist".
String cleanArtistName(String channel) => _tidy(
  channel
      .replaceFirst(RegExp(r'\s+-\s+Topic$'), '')
      .replaceFirst(RegExp(r'\s*VEVO$'), '')
      .replaceFirst(
        RegExp(r'\s*[(\[]?\bofficial( channel)?[)\]]?$', caseSensitive: false),
        '',
      ),
);

/// Drops bracketed noise ("(Official Video)", "[4K]", "(feat. X)"),
/// trailing "Official Music Video", "feat. X" and hashtags. Meaningful
/// brackets ("(Remix)", "(Live)") stay unless [allBrackets] is set.
String cleanSongTitle(String title, {bool allBrackets = false}) {
  var s = title.replaceAllMapped(_bracketed, (m) {
    final inner = m[1]!.substring(1, m[1]!.length - 1);
    final drop = allBrackets || _isNoise(inner) || _feat.hasMatch(inner);
    return drop ? '' : m[0]!;
  });
  s = s.replaceFirst(_hashtags, '').replaceFirst(_featTail, '');
  // "Title Official Video" without brackets.
  s = s.replaceFirst(_trailingNoise, '');
  return _tidy(s);
}

/// Lookup candidates, most likely first.
///
/// `artist` is the track's artist tag, or for YouTube the channel name.
List<SongGuess> songGuesses({required String title, String? artist}) {
  final channel = artist == null ? null : _nonEmpty(cleanArtistName(artist));
  final guesses = <SongGuess>[];
  void add(String? a, String t) {
    final cleanArtist = a == null
        ? null
        : _nonEmpty(_tidy(a.replaceFirst(_featTail, '')));
    final cleanTitle = cleanSongTitle(t);
    if (cleanTitle.isEmpty) return;
    guesses.add((artist: cleanArtist, title: cleanTitle));
  }

  // "Title | Artist", "Artist - Title | Official Video".
  final segments = [
    for (final s in title.split(_pipe))
      if (cleanSongTitle(s).isNotEmpty && !_isNoise(cleanSongTitle(s))) s,
  ];
  if (segments.isEmpty) segments.add(title);
  final main = segments.first;
  final dash = _dash.firstMatch(main);

  if (dash != null) {
    final left = main.substring(0, dash.start);
    final right = main.substring(dash.end);
    // "Title - Artist" only when the channel says so.
    if (channel != null &&
        similarity(channel, right) >= 0.8 &&
        similarity(channel, left) < 0.8) {
      add(right, left);
    }
    add(left, right);
  } else {
    final quoted = _quoted.firstMatch(cleanSongTitle(main));
    if (quoted != null) add(quoted[1], quoted[2]!);
    if (segments.length > 1) add(segments[1], main);
  }
  // The channel is the artist and the whole title is the song.
  add(channel, main);

  // Last resort: every bracket removed ("Song (Remix)" → "Song").
  for (final g in [...guesses]) {
    final bare = cleanSongTitle(g.title, allBrackets: true);
    if (bare.isNotEmpty) guesses.add((artist: g.artist, title: bare));
  }

  final seen = <String>{};
  return [
    for (final g in guesses)
      if (seen.add('${_key(g.artist ?? '')}|${_key(g.title)}')) g,
  ];
}

/// 0–1 likeness of two names, ignoring case, punctuation, spacing and
/// word order.
double similarity(String a, String b) {
  final ka = _key(a);
  final kb = _key(b);
  if (ka.isEmpty || kb.isEmpty) return 0;
  if (ka == kb) return 1;
  final shorter = ka.length < kb.length ? ka : kb;
  final longer = ka.length < kb.length ? kb : ka;
  if (shorter.length >= 3 && longer.contains(shorter)) {
    return 0.6 + 0.4 * shorter.length / longer.length;
  }
  final wa = _words(a);
  final wb = _words(b);
  if (wa.isEmpty || wb.isEmpty) return 0;
  return wa.intersection(wb).length / wa.union(wb).length;
}

bool _isNoise(String text) {
  if (!_noise.hasMatch(text)) return false;
  // Noise when nothing but noise words, years and punctuation remain.
  final rest = text
      .replaceAll(_noise, ' ')
      .replaceAll(
        RegExp(
          r'\b(music|the|new|19\d\d|20\d\d|version)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  return rest.isEmpty;
}

String _key(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

Set<String> _words(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((w) => w.isNotEmpty)
    .toSet();

String _tidy(String s) => s
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[\s\-–—|:,]+|[\s\-–—|:,]+$'), '')
    .trim();

String? _nonEmpty(String s) => s.isEmpty ? null : s;
