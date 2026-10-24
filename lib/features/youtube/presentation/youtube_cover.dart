import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';

/// Square cover art for a YouTube video.
///
/// Shows the centred square of the video thumbnail at once, then
/// cross-fades to the real square album art once the `ArtworkResolver` finds
/// it on YouTube Music. Both are fetched at the size shown (× device pixel
/// ratio), and the layout never changes.
///
/// For songs ("Artist - Topic" videos) the thumbnail is the album cover
/// centred in a 16:9 frame, so the crop is the cover at lower quality:
/// - `hqdefault.jpg` (480×360, letterboxed 4:3): 270 px square;
/// - `sddefault.jpg` (640×480, letterboxed 4:3): 360 px square;
/// - `maxresdefault.jpg` (1280×720, 16:9): 720 px square, falling back to
///   hq when the video has none.
class YouTubeCover extends ConsumerStatefulWidget {
  const YouTubeCover({
    required this.videoId,
    required this.size,
    this.radius = NoirRadii.xl,
    this.semanticLabel = 'Cover art',
    this.placeholder,
    super.key,
  });

  final String videoId;
  final double size;
  final double radius;
  final String? semanticLabel;

  /// Shown while nothing has loaded and when loading fails.
  final Widget? placeholder;

  /// 16:9 thumbnail without letterbox bars. Small (320×180): only for
  /// stored metadata and blurred backgrounds, not for visible covers.
  static String thumbnail(String videoId) =>
      'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';

  @override
  ConsumerState<YouTubeCover> createState() => _YouTubeCoverState();
}

class _YouTubeCoverState extends ConsumerState<YouTubeCover> {
  /// The album art was already known when this video appeared: no need to
  /// load the thumbnail underneath it.
  bool? _artKnownAtStart;

  /// The album art has painted once; later size changes swap it without
  /// fading again.
  bool _artShown = false;

  @override
  void didUpdateWidget(YouTubeCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _artKnownAtStart = null;
      _artShown = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final px = size * MediaQuery.devicePixelRatioOf(context);
    final art = ref.watch(resolvedArtProvider(widget.videoId));
    final artUrl = art?.squareUrl(px);
    _artKnownAtStart ??= artUrl != null;

    final placeholder =
        widget.placeholder ??
        ColoredBox(
          color: context.noir.surfaceElevated,
          child: Icon(
            Icons.music_note_rounded,
            size: size * 0.3,
            color: context.noir.textTertiary,
          ),
        );
    final thumbnail = _ThumbnailCrop(
      videoId: widget.videoId,
      size: size,
      px: px,
      placeholder: placeholder,
      semanticLabel: artUrl == null ? widget.semanticLabel : null,
    );

    final Widget child;
    if (artUrl == null) {
      child = thumbnail;
    } else {
      final fade = NoirEffects.of(context).motion(NoirMotion.slow);
      child = Stack(
        fit: StackFit.expand,
        children: [
          if (_artKnownAtStart!) placeholder else thumbnail,
          Image.network(
            artUrl,
            key: const ValueKey('album-art'),
            width: size,
            height: size,
            fit: BoxFit.cover,
            // Decode at the requested bucket (≥ shown size × dpr), so
            // resizing within a bucket reuses the decoded image.
            cacheWidth: artBucket(px),
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
            semanticLabel: widget.semanticLabel,
            errorBuilder: (_, _, _) => thumbnail,
            frameBuilder: (context, image, frame, sync) {
              if (sync || frame != null) _artShown = true;
              return AnimatedOpacity(
                opacity: _artShown ? 1 : 0,
                duration: fade,
                curve: NoirMotion.standard,
                child: image,
              );
            },
          ),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox.square(dimension: size, child: child),
    );
  }
}

/// The centred square of the smallest YouTube thumbnail that covers [px]
/// physical pixels; see [youtubeFrame].
class _ThumbnailCrop extends StatelessWidget {
  const _ThumbnailCrop({
    required this.videoId,
    required this.size,
    required this.px,
    required this.placeholder,
    required this.semanticLabel,
  });

  final String videoId;
  final double size;
  final double px;
  final Widget placeholder;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final frame = youtubeFrame(px);
    final hq = frame == hqFrame
        ? null
        : _crop(hqFrame, onError: placeholder, whileLoading: null);
    return _crop(frame, onError: hq ?? placeholder, whileLoading: hq);
  }

  Widget _crop(
    YouTubeFrame frame, {
    required Widget onError,
    required Widget? whileLoading,
  }) {
    // `frame.square` source pixels become `size` logical pixels.
    final scale = size / frame.square;
    final width = frame.width * scale;
    final height = frame.height * scale;
    final dpr = px / size;
    return OverflowBox(
      maxWidth: width,
      maxHeight: height,
      child: Image.network(
        youtubeFrameUrl(videoId, frame),
        width: width,
        height: height,
        fit: BoxFit.fill,
        cacheWidth: math.min(frame.width, (width * dpr).ceil()),
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        semanticLabel: semanticLabel,
        // A missing maxres/sd frame answers 404 (with a grey placeholder).
        errorBuilder: (_, _, _) => onError,
        frameBuilder: whileLoading == null
            ? null
            : (context, child, loaded, sync) =>
                  loaded == null && !sync ? whileLoading : child,
      ),
    );
  }
}
