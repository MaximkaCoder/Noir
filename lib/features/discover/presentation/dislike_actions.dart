import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/shared/models/media.dart';

/// "Not interested" and "Don't recommend `artist`" for a YouTube song's
/// menu; empty for local files.
List<NoirMenuItem<String>> dislikeMenuItems(Track track) => [
  if (track.source == MediaSource.youtube) ...[
    const NoirMenuItem(
      'dislike',
      'Not interested',
      icon: Icons.thumb_down_alt_outlined,
    ),
    if (track.artist case final artist? when artist.isNotEmpty)
      NoirMenuItem(
        'block artist',
        "Don't recommend $artist",
        icon: Icons.block_rounded,
      ),
  ],
];

/// Runs a [dislikeMenuItems] choice; other values are ignored.
Future<void> runDislikeAction(
  BuildContext context,
  WidgetRef ref,
  String? action,
  Track track,
) async {
  final ctrl = ref.read(dislikesProvider.notifier);
  switch (action) {
    case 'dislike':
      await dislikeWithToast(context, ref, track);
    case 'block artist':
      final artist = track.artist!;
      await ctrl.blockArtist(artist, playing: track);
      if (context.mounted) {
        showToast(context, "NOIR won't recommend $artist");
      }
  }
}

Future<void> dislikeWithToast(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final onYouTube = await ref
      .read(dislikesProvider.notifier)
      .dislikeSong(track);
  if (context.mounted) {
    showToast(
      context,
      onYouTube
          ? 'Disliked. You won\'t see "${track.title}" in recommendations'
          : 'You won\'t see "${track.title}" in recommendations',
    );
  }
}

/// Thumbs down for the playing YouTube song: hides it from recommendations
/// and skips to the next one.
class DislikeButton extends ConsumerWidget {
  const DislikeButton(this.track, {this.size = 20, super.key});

  final Track track;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (track.source != MediaSource.youtube) return const SizedBox.shrink();
    return NoirIconButton(
      icon: Icons.thumb_down_alt_outlined,
      tooltip: 'Not interested',
      size: size,
      onPressed: () => unawaited(dislikeWithToast(context, ref, track)),
    );
  }
}
