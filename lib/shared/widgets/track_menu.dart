import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/analysis/presentation/track_analysis_dialog.dart';
import 'package:noir/features/discover/presentation/dislike_actions.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/presentation/add_to_youtube_playlist.dart';
import 'package:noir/shared/models/media.dart';
import 'package:url_launcher/url_launcher.dart';

/// The context menu for [track] at [position] (global): queue, radio,
/// playlists, favorites and "Not interested". [onPlay] adds "Play" first;
/// [onRemove] adds a remove action named [removeLabel].
Future<void> showTrackMenu(
  BuildContext context,
  WidgetRef ref,
  Track track,
  Offset position, {
  VoidCallback? onPlay,
  VoidCallback? onRemove,
  String removeLabel = 'Remove from playlist',
}) async {
  final playback = ref.read(playbackProvider.notifier);
  final youTube =
      track.source == MediaSource.youtube &&
      ref.read(accountServiceProvider).current.isConnected;
  final action = await showNoirMenu<String>(
    context,
    anchor: position & Size.zero,
    items: [
      if (onPlay != null)
        const NoirMenuItem('play', 'Play', icon: Icons.play_arrow_rounded),
      const NoirMenuItem(
        'next',
        'Play next',
        icon: Icons.playlist_play_rounded,
      ),
      const NoirMenuItem(
        'queue',
        'Add to queue',
        icon: Icons.queue_music_rounded,
      ),
      const NoirMenuItem('radio', 'Start radio', icon: Icons.radio_rounded),
      if (track.localId != null || youTube)
        const NoirMenuItem(
          'playlist',
          'Add to playlist…',
          icon: Icons.playlist_add_rounded,
        ),
      if (track.localId != null)
        NoirMenuItem(
          'favorite',
          track.isFavorite ? 'Remove from favorites' : 'Add to favorites',
          icon: track.isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
        ),
      if (track.source == MediaSource.youtube)
        const NoirMenuItem(
          'open',
          'Open in YouTube Music',
          icon: Icons.open_in_new_rounded,
        ),
      if (ref.read(analysisRunnerProvider) != null)
        const NoirMenuItem(
          'analysis',
          'Show analysis',
          icon: Icons.graphic_eq_rounded,
        ),
      ...dislikeMenuItems(track),
      if (onRemove != null)
        NoirMenuItem('remove', removeLabel, icon: Icons.remove_circle_outline),
    ],
  );
  if (!context.mounted) return;
  switch (action) {
    case 'play':
      onPlay?.call();
    case 'next':
      playback.playNext(track);
      showToast(context, 'Playing next: ${track.title}');
    case 'queue':
      playback.addToQueue([track]);
      showToast(context, 'Added to queue');
    case 'radio':
      unawaited(playback.startRadio(track));
    case 'playlist' when youTube:
      await addToYouTubePlaylist(context, ref, track);
    case 'playlist':
      await addToPlaylist(context, ref, [track]);
    case 'favorite':
      unawaited(playback.toggleFavorite(track));
    case 'open':
      unawaited(
        launchUrl(
          youTubeMusicUrl(videoId: track.uri),
          mode: LaunchMode.externalApplication,
        ),
      );
    case 'analysis':
      unawaited(showTrackAnalysis(context, track));
    case 'remove':
      onRemove?.call();
    default:
      await runDislikeAction(context, ref, action, track);
  }
}
