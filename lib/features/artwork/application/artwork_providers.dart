import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/artwork/data/artwork_cache_store.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Square album art for YouTube videos, looked up anonymously on YouTube
/// Music (the discovery client: no account, no cookies).
final artworkResolverProvider = Provider<ArtworkResolver>((ref) {
  final resolver = ArtworkResolver(
    lookup: InnerTubeArtworkLookup(ref.watch(innerTubeClientProvider)),
    store: JsonFileArtworkCacheStore(
      () async => File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'youtube_artwork.json',
        ),
      ),
    ),
  );
  ref.onDispose(() => unawaited(resolver.dispose()));
  return resolver;
});

/// What is known about one video's artwork; updates when it resolves.
/// Watching it asks for the lookup.
final resolvedArtProvider = NotifierProvider.autoDispose
    .family<ResolvedArtNotifier, ResolvedArt?, String>(ResolvedArtNotifier.new);

/// Where one YouTube video's artist and album names lead on YouTube Music
/// (artist channels `UC…`, album `MPREb_…`); null until known, or when
/// YouTube Music does not know the video. Watching it asks for the lookup
/// (shared with the artwork, one batched `get_queue`).
final ytmTrackLinksProvider = Provider.autoDispose
    .family<YtmTrackLinks?, String>(
      (ref, videoId) => ref.watch(resolvedArtProvider(videoId))?.links,
    );

class ResolvedArtNotifier extends Notifier<ResolvedArt?> {
  ResolvedArtNotifier(this.videoId);

  final String videoId;

  @override
  ResolvedArt? build() {
    final resolver = ref.watch(artworkResolverProvider);
    ref.onDispose(resolver.listen(videoId, (art) => state = art));
    return resolver.peek(videoId);
  }
}
