import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';

/// Square artwork decoded at display size × device pixel ratio
/// (`cacheWidth`) to keep memory and decode time proportional to what is on
/// screen. Missing or broken artwork falls back to a quiet placeholder.
///
/// Remote artwork is fetched at the size shown: YouTube Music art
/// (googleusercontent) is re-requested at the matching size, and YouTube
/// video thumbnails become a [YouTubeCover] (real album art when YouTube
/// Music has it).
class Artwork extends StatelessWidget {
  const Artwork({
    required this.path,
    required this.size,
    this.radius = NoirRadii.sm,
    this.icon = Icons.music_note_rounded,
    this.semanticLabel,
    super.key,
  });

  /// Local file path or http(s) URL.
  final String? path;
  final double size;
  final double radius;
  final IconData icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = _Placeholder(size: size, icon: icon);
    final source = path;
    final px = size * dpr;
    final videoId = source == null ? null : youtubeThumbnailVideoId(source);
    if (videoId != null) {
      return YouTubeCover(
        videoId: videoId,
        size: size,
        radius: radius,
        semanticLabel: semanticLabel,
        placeholder: placeholder,
      );
    }
    final googleArt = source != null && isGoogleArt(source);
    final image = source == null
        ? placeholder
        : isRemoteImage(source)
        ? Image.network(
            googleArt ? resizeGoogleArt(source, px) : source,
            width: size,
            height: size,
            fit: BoxFit.cover,
            // Google art is square. Other images may be wide, and a
            // width-only decode would leave them short of `size` once
            // cropped to a square: decode those whole.
            cacheWidth: googleArt ? artBucket(px) : null,
            gaplessPlayback: true,
            semanticLabel: semanticLabel,
            errorBuilder: (_, _, _) => placeholder,
          )
        : Image.file(
            File(source),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: px.ceil(),
            gaplessPlayback: true,
            semanticLabel: semanticLabel,
            errorBuilder: (_, _, _) => placeholder,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(dimension: size, child: image),
    );
  }
}

bool isRemoteImage(String source) =>
    source.startsWith('https://') || source.startsWith('http://');

/// 2×2 collage of up to four covers, as used for playlists.
class ArtworkCollage extends StatelessWidget {
  const ArtworkCollage({
    required this.paths,
    required this.size,
    this.radius = NoirRadii.sm,
    super.key,
  });

  final List<String> paths;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (paths.length < 4) {
      return Artwork(
        path: paths.firstOrNull,
        size: size,
        radius: radius,
        icon: Icons.queue_music_rounded,
      );
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Wrap(
          children: [
            for (final p in paths.take(4))
              Artwork(path: p, size: half, radius: 0),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.icon});

  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.surfaceElevated, c.backgroundSecondary],
        ),
      ),
      child: Center(
        child: Icon(icon, size: size * 0.36, color: c.textTertiary),
      ),
    );
  }
}
