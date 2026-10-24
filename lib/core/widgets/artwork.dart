import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';

/// Square artwork decoded at display size (`cacheWidth`) to keep memory and
/// decode time proportional to what is on screen. Missing or broken artwork
/// falls back to a quiet placeholder.
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
    final image = source == null
        ? placeholder
        : isRemoteImage(source)
        ? Image.network(
            source,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * dpr).round(),
            gaplessPlayback: true,
            semanticLabel: semanticLabel,
            errorBuilder: (_, _, _) => placeholder,
          )
        : Image.file(
            File(source),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * dpr).round(),
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
