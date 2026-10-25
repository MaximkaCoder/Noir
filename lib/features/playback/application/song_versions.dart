import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/shared/models/media.dart';

final songVersionsProvider = Provider<SongVersions>(
  (ref) => SongVersions(ref.watch(innerTubeClientProvider)),
);

/// Swaps an official music video for the song YouTube Music pairs it with,
/// as YouTube Music's own "Song" mode does: the studio audio, without the
/// video's intro, skits or outro (a 5:46 video can be a 3:40 song).
///
/// Asked anonymously (`music/get_queue`, one request per video) and
/// remembered for the session. Anything uncertain keeps the original.
class SongVersions {
  SongVersions(this._client);

  final InnerTubeClient _client;

  /// Waiting longer than this delays the start of playback too much.
  static const timeout = Duration(seconds: 3);

  /// Video id → its song twin's id and length, null when it has none.
  final _known = <String, ({String id, Duration? duration})?>{};
  final _pending = <String, Future<void>>{};

  /// [track] as its song twin, or [track] itself.
  Future<Track> resolve(Track track) async {
    final id = track.uri;
    if (track.source != MediaSource.youtube || id.isEmpty) return track;
    if (!_known.containsKey(id)) {
      try {
        await (_pending[id] ??= _lookup(id)).timeout(timeout);
      } on TimeoutException {
        return track; // Looked up for next time.
      }
    }
    return _apply(track);
  }

  Future<void> _lookup(String id) async {
    try {
      final entry = (await _client.queue([id]))[id];
      final twin = entry?.counterpart;
      _known[id] = entry != null && !entry.isSong && twin != null && twin.isSong
          ? (id: twin.videoId, duration: twin.duration)
          : null;
    } on Object catch (e) {
      // Unknown this time (offline, unexpected answer); playback goes on
      // with the video and asks again on the next play.
      debugPrint('Song version lookup failed: $e');
    } finally {
      unawaited(_pending.remove(id));
    }
  }

  Track _apply(Track track) {
    final twin = _known[track.uri];
    if (twin == null) return track;
    return track.copyWith(
      id: 'yt:${twin.id}',
      uri: twin.id,
      duration: twin.duration ?? track.duration,
      artworkUrl: YouTubeCover.thumbnail(twin.id),
    );
  }
}
