import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/features/youtube/presentation/save_button.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

/// Name offered for a new playlist.
const defaultSavePlaylistName = 'NOIR Likes';

/// Lets the user choose the playlist hearted songs go to (or create one),
/// then makes sure NOIR may edit it. Returns the target once usable, or
/// null when the user backed out or declined the permission (a chosen
/// playlist is remembered anyway).
Future<SaveTarget?> pickSaveTarget(BuildContext context, WidgetRef ref) async {
  final choice = await showGlassDialog<_Choice>(
    context,
    builder: (context) => const _PickerBody(),
  );
  if (choice == null || !context.mounted) return null;

  final picked = choice.playlist;
  if (picked != null) {
    final target = SaveTarget(picked.id, picked.title);
    ref.read(saveTargetProvider.notifier).set(target);
    return await ensureWriteAccess(context, ref) ? target : null;
  }

  final name = await promptText(
    context,
    title: 'New YouTube playlist',
    confirmLabel: 'Create',
    initial: defaultSavePlaylistName,
    hint: 'Playlist name',
  );
  if (name == null || !context.mounted) return null;
  if (!await ensureWriteAccess(context, ref) || !context.mounted) return null;
  try {
    final target = await ref
        .read(youTubeSaveProvider.notifier)
        .createTarget(name);
    if (context.mounted) {
      showToast(context, 'Created "${target.title}" (private) on YouTube');
    }
    return target;
  } on YouTubeApiException catch (e) {
    if (context.mounted) {
      showToast(
        context,
        e.kind == YouTubeErrorKind.permission
            ? 'YouTube refused: NOIR may not create playlists. Allow access '
                  'and try again.'
            : "Couldn't create the playlist. ${e.message}",
      );
    }
    return null;
  }
}

/// Either an existing playlist or "create new".
class _Choice {
  const _Choice(this.playlist);

  final YouTubePlaylist? playlist;
}

class _PickerBody extends ConsumerWidget {
  const _PickerBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final playlists = ref.watch(youTubePlaylistsProvider).value ?? const [];
    final current = ref.watch(saveTargetProvider)?.id;

    Widget row({
      required IconData icon,
      required String title,
      required VoidCallback onTap,
      String? subtitle,
      bool selected = false,
    }) => InkWell(
      onTap: onTap,
      borderRadius: NoirRadii.mdAll,
      hoverColor: c.hover,
      focusColor: c.selected,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NoirSpacing.sm,
          vertical: NoirSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.textSecondary),
            const SizedBox(width: NoirSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium,
                  ),
                  if (subtitle != null) Text(subtitle, style: t.bodySmall),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 18, color: c.textPrimary),
          ],
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Save hearted songs to', style: t.titleMedium),
        const SizedBox(height: NoirSpacing.sm),
        Text(
          'The heart on a YouTube song adds it to this playlist on your '
          'YouTube account. Nothing is liked or rated.',
          style: t.bodySmall,
        ),
        const SizedBox(height: NoirSpacing.lg),
        if (playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.all(NoirSpacing.sm),
            child: Text('No playlists synced yet.', style: t.bodySmall),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in playlists)
                  row(
                    icon: Icons.queue_music_rounded,
                    title: p.title,
                    subtitle: p.trackCount == 1
                        ? '1 song'
                        : '${p.trackCount} songs',
                    selected: p.id == current,
                    onTap: () => Navigator.of(context).pop(_Choice(p)),
                  ),
              ],
            ),
          ),
        row(
          icon: Icons.add_rounded,
          title: 'Create new playlist…',
          subtitle: 'Private',
          onTap: () => Navigator.of(context).pop(const _Choice(null)),
        ),
        const SizedBox(height: NoirSpacing.lg),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}

/// Settings → Accounts: where hearted YouTube songs go.
class SaveTargetSetting extends ConsumerWidget {
  const SaveTargetSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final title = ref.watch(saveTargetTitleProvider);
    final authorizing = ref.watch(
      youTubeSaveProvider.select((s) => s.authorizing),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Save hearted songs to',
          style: t.bodySmall?.copyWith(color: c.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          authorizing
              ? 'Waiting for your browser…'
              : title ??
                    'Not chosen yet — NOIR asks the first time you heart a '
                        'YouTube song.',
          style: t.bodySmall,
        ),
        const SizedBox(height: NoirSpacing.sm),
        Wrap(
          spacing: NoirSpacing.sm,
          runSpacing: NoirSpacing.sm,
          children: [
            if (authorizing)
              PillButton(
                label: 'Cancel',
                icon: Icons.close_rounded,
                onPressed: ref
                    .read(youTubeSaveProvider.notifier)
                    .cancelAuthorization,
              )
            else
              PillButton(
                label: title == null ? 'Choose playlist' : 'Change playlist',
                icon: Icons.favorite_border_rounded,
                onPressed: () => unawaited(pickSaveTarget(context, ref)),
              ),
          ],
        ),
      ],
    );
  }
}
