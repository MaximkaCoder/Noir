import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';

/// Square cover art for a YouTube video, cut from its thumbnail.
///
/// YouTube Music tracks ("Artist - Topic" videos) show the album cover
/// centered in a 16:9 frame, so the centered square of the frame *is* the
/// cover:
/// - `maxresdefault.jpg` (1280×720, 16:9): center 720×720 square;
/// - fallback `hqdefault.jpg` (480×360, letterboxed 4:3): the 16:9 picture
///   sits between 45 px bars, so its center square is 270×270.
class YouTubeCover extends StatelessWidget {
  const YouTubeCover({
    required this.videoId,
    required this.size,
    this.radius = NoirRadii.xl,
    super.key,
  });

  final String videoId;
  final double size;
  final double radius;

  /// 16:9 thumbnail without letterbox bars, for small list artwork.
  static String thumbnail(String videoId) =>
      'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = ColoredBox(
      color: context.noir.surfaceElevated,
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.3,
        color: context.noir.textTertiary,
      ),
    );

    // 270 px of the hq frame become `size` px on screen.
    final hqScale = size / 270;
    final fallback = OverflowBox(
      maxWidth: 480 * hqScale,
      maxHeight: 360 * hqScale,
      child: Image.network(
        'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        width: 480 * hqScale,
        height: 360 * hqScale,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Image.network(
          'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
          fit: BoxFit.cover,
          // Decode only what is shown: the square is 720 px of the source.
          cacheHeight: (size * dpr).round().clamp(1, 720),
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
          semanticLabel: 'Cover art',
          // YouTube answers a missing maxres with a 120×90 grey image
          // (HTTP 404 → error), so fall back to the hq frame.
          errorBuilder: (_, _, _) => fallback,
          frameBuilder: (context, child, frame, sync) =>
              frame == null && !sync ? fallback : child,
        ),
      ),
    );
  }
}
