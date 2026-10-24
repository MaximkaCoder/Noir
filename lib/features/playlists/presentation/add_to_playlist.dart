import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/shared/models/media.dart';

/// Asks for a name and creates a local playlist. Returns its id.
Future<int?> createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await promptText(
    context,
    title: 'New playlist',
    confirmLabel: 'Create',
    hint: 'Playlist name',
  );
  if (name == null) return null;
  return await ref.read(playlistRepositoryProvider).create(name);
}

/// Lets the user pick (or create) a local playlist for [tracks].
Future<void> addToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  final ids = [for (final t in tracks) ?t.localId];
  if (ids.isEmpty) return;
  const newPlaylist = -1;
  final chosen = await showGlassDialog<int>(
    context,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final t = Theme.of(context).textTheme;
        final playlists = ref.watch(playlistsProvider).value ?? const [];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add to playlist', style: t.titleMedium),
            const SizedBox(height: NoirSpacing.md),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('New playlist…'),
              shape: const RoundedRectangleBorder(
                borderRadius: NoirRadii.mdAll,
              ),
              onTap: () => Navigator.of(context).pop(newPlaylist),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in playlists)
                    ListTile(
                      leading: ArtworkCollage(paths: p.artworkPaths, size: 36),
                      title: Text(p.name, maxLines: 1),
                      subtitle: Text(
                        songCount(p.trackCount),
                        style: t.bodySmall,
                      ),
                      shape: const RoundedRectangleBorder(
                        borderRadius: NoirRadii.mdAll,
                      ),
                      onTap: () => Navigator.of(context).pop(p.id),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
  if (chosen == null || !context.mounted) return;
  final id = chosen == newPlaylist
      ? await createPlaylist(context, ref)
      : chosen;
  if (id == null || !context.mounted) return;
  await ref.read(playlistRepositoryProvider).addTracks(id, ids);
  if (context.mounted) {
    showToast(
      context,
      ids.length == 1 ? 'Added to playlist' : 'Added ${ids.length} songs',
    );
  }
}
