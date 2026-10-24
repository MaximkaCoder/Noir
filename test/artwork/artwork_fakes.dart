import 'dart:async';

import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/artwork/data/artwork_cache_store.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

String art(String id) => 'https://lh3.googleusercontent.com/$id';

/// A song: square art straight from get_queue.
YtmQueueEntry atv(String id) => YtmQueueEntry(
  videoId: id,
  title: 'Song $id',
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  thumbnailUrl: '${art(id)}=w544-h544-l90-rj',
  videoType: 'MUSIC_VIDEO_TYPE_ATV',
  artists: const [(name: 'Artist', browseId: 'UCartist')],
  album: (name: 'Album $id', browseId: 'MPREb_$id'),
);

/// A music video: only a video frame.
YtmQueueEntry omv(String id, {String title = 'Hit'}) => YtmQueueEntry(
  videoId: id,
  title: title,
  artist: 'Artist',
  duration: const Duration(minutes: 3),
  thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq720.jpg',
  videoType: 'MUSIC_VIDEO_TYPE_OMV',
  artists: const [(name: 'Artist', browseId: 'UCartist')],
);

Track songResult(String title, {String id = 'song1'}) => Track(
  id: 'yt:$id',
  source: MediaSource.youtube,
  title: title,
  uri: id,
  artist: 'Artist',
  duration: const Duration(minutes: 3, seconds: 2),
  artworkUrl: '${art(id)}=w544-h544-l90-rj',
);

class FakeLookup implements ArtworkLookup {
  final known = <String, YtmQueueEntry>{};
  final songsFor = <String, List<Track>>{};
  final queueCalls = <List<String>>[];
  final searchCalls = <String>[];

  /// While set, get_queue waits for it.
  Completer<void>? gate;
  int queueFailures = 0;
  Duration searchDelay = Duration.zero;
  int _activeSearches = 0;
  int maxActiveSearches = 0;

  @override
  Future<Map<String, YtmQueueEntry>> queue(List<String> videoIds) async {
    queueCalls.add(videoIds);
    await gate?.future;
    if (queueFailures > 0) {
      queueFailures--;
      throw const InnerTubeException(InnerTubeErrorKind.network, 'offline');
    }
    return {for (final id in videoIds) id: ?known[id]};
  }

  @override
  Future<List<Track>> songs(String query) async {
    searchCalls.add(query);
    _activeSearches++;
    if (_activeSearches > maxActiveSearches) {
      maxActiveSearches = _activeSearches;
    }
    await Future<void>.delayed(searchDelay);
    _activeSearches--;
    return songsFor[query] ?? const [];
  }
}

class MemoryStore implements ArtworkCacheStore {
  MemoryStore([Map<String, ResolvedArt>? saved]) : saved = saved ?? {};

  Map<String, ResolvedArt> saved;
  int saves = 0;

  @override
  Future<Map<String, ResolvedArt>> load() async => Map.of(saved);

  @override
  Future<void> save(Map<String, ResolvedArt> entries) async {
    saves++;
    saved = Map.of(entries);
  }
}
