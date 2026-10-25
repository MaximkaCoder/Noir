import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/menus.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/analysis/presentation/track_analysis_dialog.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/presentation/add_to_playlist.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/presentation/add_to_youtube_playlist.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/shared/models/media.dart';
import 'package:url_launcher/url_launcher.dart';

/// A track in any list: number or artwork, title/artist, duration, and a
/// context menu (right-click, long-press, or the "more" button).
class TrackRow extends ConsumerStatefulWidget {
  const TrackRow({
    required this.track,
    required this.onPlay,
    this.number,
    this.showArtwork = true,
    this.onRemove,
    this.removeLabel = 'Remove from playlist',
    this.trailing,
    super.key,
  });

  final Track track;
  final VoidCallback onPlay;

  /// Position shown before the artwork, as in playlist views.
  final int? number;
  final bool showArtwork;

  /// Adds a remove action (playlist or queue context).
  final VoidCallback? onRemove;
  final String removeLabel;

  /// Replaces the duration (e.g. a drag handle in the queue).
  final Widget? trailing;

  @override
  ConsumerState<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends ConsumerState<TrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    final compact =
        ref.watch(settingsProvider.select((s) => s.density)) == Density.compact;
    final isCurrent = ref.watch(
      playbackProvider.select((s) => s.current?.track.id == widget.track.id),
    );
    final track = widget.track;
    final art = compact ? 36.0 : 44.0;

    return Semantics(
      button: true,
      label: '${track.title}, ${track.artistOrUnknown}',
      hint: 'Double tap to play',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onSecondaryTapUp: (d) => _showMenu(d.globalPosition),
          onLongPressStart: (d) => _showMenu(d.globalPosition),
          child: InkWell(
            onTap: widget.onPlay,
            borderRadius: NoirRadii.mdAll,
            hoverColor: c.hover,
            focusColor: c.selected,
            hoverDuration: NoirEffects.of(context).motion(NoirMotion.fast),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: NoirSpacing.sm,
                vertical: compact ? NoirSpacing.xs : NoirSpacing.sm - 2,
              ),
              child: Row(
                children: [
                  if (widget.number != null)
                    SizedBox(
                      width: 32,
                      child: isCurrent
                          ? Icon(
                              Icons.graphic_eq_rounded,
                              size: 16,
                              color: c.textPrimary,
                            )
                          : Text(
                              '${widget.number}',
                              style: t.bodySmall?.copyWith(
                                fontFeatures: tabularFigures,
                              ),
                            ),
                    ),
                  if (widget.showArtwork) ...[
                    Artwork(path: track.artwork, size: art, radius: 6),
                    const SizedBox(width: NoirSpacing.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyMedium?.copyWith(
                            color: isCurrent ? c.textPrimary : null,
                            fontWeight: isCurrent ? FontWeight.w600 : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            track.artistOrUnknown,
                            if (track.album != null) track.album!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (track.isFavorite)
                    Padding(
                      padding: const EdgeInsets.only(left: NoirSpacing.sm),
                      child: Icon(
                        Icons.favorite_rounded,
                        size: 14,
                        color: c.textSecondary,
                        semanticLabel: 'Favorite',
                      ),
                    ),
                  // YouTube songs: saved to the user's chosen playlist.
                  if (track.source == MediaSource.youtube)
                    Padding(
                      padding: const EdgeInsets.only(left: NoirSpacing.xs),
                      child: YouTubeSaveButton(
                        track,
                        size: 16,
                        showWhenUnsaved: _hovered || !_hasHover(context),
                      ),
                    ),
                  const SizedBox(width: NoirSpacing.md),
                  widget.trailing ??
                      Text(
                        track.duration == null
                            ? ''
                            : formatClock(track.duration!),
                        style: t.bodySmall?.copyWith(
                          fontFeatures: tabularFigures,
                        ),
                      ),
                  _MoreButton(
                    visible: _hovered || !_hasHover(context),
                    onPressed: _showMenu,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static bool _hasHover(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  Future<void> _showMenu(Offset position) async {
    final track = widget.track;
    final playback = ref.read(playbackProvider.notifier);
    final youTube =
        track.source == MediaSource.youtube &&
        ref.read(accountServiceProvider).current.isConnected;
    final action = await showNoirMenu<String>(
      context,
      anchor: position & Size.zero,
      items: [
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
        if (widget.onRemove != null)
          NoirMenuItem(
            'remove',
            widget.removeLabel,
            icon: Icons.remove_circle_outline,
          ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'play':
        widget.onPlay();
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
        widget.onRemove?.call();
    }
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.visible, required this.onPressed});

  final bool visible;
  final ValueChanged<Offset> onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: NoirEffects.of(context).motion(NoirMotion.fast),
      child: Builder(
        builder: (context) => IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.more_horiz_rounded, size: 18),
          color: context.noir.textSecondary,
          onPressed: () {
            final box = context.findRenderObject()! as RenderBox;
            onPressed(box.localToGlobal(box.size.center(Offset.zero)));
          },
        ),
      ),
    );
  }
}
