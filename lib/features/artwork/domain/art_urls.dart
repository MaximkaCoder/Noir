/// Pure URL helpers for remote artwork: YouTube Music's square album art
/// (`*.googleusercontent.com`, sized by a URL suffix) and YouTube video
/// thumbnails (`i.ytimg.com`). See test/artwork/art_urls_test.dart.
library;

/// Square sizes requested from googleusercontent, in physical pixels.
/// Few distinct sizes keep the HTTP and image caches warm across screens.
const artBuckets = [120, 226, 544, 1200];

/// The smallest bucket that covers [px] physical pixels (the largest one
/// beyond that).
int artBucket(double px) {
  for (final b in artBuckets) {
    if (b >= px) return b;
  }
  return artBuckets.last;
}

/// Album art / avatar served by Google's image CDN, resizable by suffix.
bool isGoogleArt(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.endsWith('.googleusercontent.com') || host.endsWith('.ggpht.com');
}

final _sizeOption = RegExp(r'^[whs]\d+$');

/// [url] without its `=w544-h544-l90-rj`-style options.
String googleArtBase(String url) {
  final eq = url.lastIndexOf('=');
  if (eq < 0 || url.indexOf('/', eq) >= 0) return url;
  return url.substring(0, eq);
}

/// A googleusercontent [url] resized to the [artBucket] for [px] physical
/// pixels: size options (`w60`, `h60`, `s192`) are replaced, others (`l90`,
/// `rj`, `p`, …) kept. Other URLs are returned unchanged.
String resizeGoogleArt(String url, double px) {
  if (!isGoogleArt(url)) return url;
  final base = googleArtBase(url);
  final options = base.length == url.length
      ? const <String>[]
      : url.substring(base.length + 1).split('-');
  final kept = options.where((o) => o.isNotEmpty && !_sizeOption.hasMatch(o));
  final b = artBucket(px);
  final rest = kept.isEmpty ? _defaultOptions : kept;
  return '$base=${['w$b', 'h$b', ...rest].join('-')}';
}

/// What YouTube Music itself asks for: JPEG quality 90, WebP allowed.
const _defaultOptions = ['l90', 'rj'];

final _ytimg = RegExp(
  r'^https?://i\d?\.ytimg\.com/vi(?:_webp)?/([A-Za-z0-9_-]{11})/',
);

/// The video id of a YouTube thumbnail URL (`i.ytimg.com/vi/<id>/…`).
String? youtubeThumbnailVideoId(String url) => _ytimg.firstMatch(url)?[1];

/// A YouTube thumbnail and where its centred square lies.
typedef YouTubeFrame = ({
  String name,
  int width,
  int height,

  /// Side of the centred square that holds the picture (no letterbox).
  int square,
});

/// 1280×720, 16:9; missing for some (mostly older) videos.
const YouTubeFrame maxresFrame = (
  name: 'maxresdefault',
  width: 1280,
  height: 720,
  square: 720,
);

/// 640×480 with the 16:9 picture letterboxed: a 360 px square.
const YouTubeFrame sdFrame = (
  name: 'sddefault',
  width: 640,
  height: 480,
  square: 360,
);

/// 480×360 with the 16:9 picture letterboxed: a 270 px square. Always
/// exists.
const YouTubeFrame hqFrame = (
  name: 'hqdefault',
  width: 480,
  height: 360,
  square: 270,
);

/// The smallest thumbnail whose centred square covers [px] physical pixels
/// (maxres beyond the sd square). Never `mqdefault`: its square is 180 px.
YouTubeFrame youtubeFrame(double px) => px <= hqFrame.square
    ? hqFrame
    : px <= sdFrame.square
    ? sdFrame
    : maxresFrame;

String youtubeFrameUrl(String videoId, YouTubeFrame frame) =>
    'https://i.ytimg.com/vi/$videoId/${frame.name}.jpg';

/// Whether an artwork source is fetched over the network; anything else is
/// a file NOIR saved itself.
bool isRemoteImage(String source) =>
    source.startsWith('https://') || source.startsWith('http://');
