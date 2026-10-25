import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

final youTubePendingEditsProvider = Provider<YouTubePendingEdits>(
  (ref) => YouTubePendingEdits(ref.watch(youTubeClockProvider)),
);

/// Playlist changes NOIR just made on YouTube.
///
/// YouTube answers list requests from a cache that can lag a write by
/// several seconds, so a sync right after "add" may not contain the new item
/// yet (or still contain a removed one). Fetched lists pass through [apply]
/// before they replace the cached ones, so the user's change does not
/// flicker out and back in.
class YouTubePendingEdits {
  YouTubePendingEdits(this._now);

  /// After this long YouTube's answer wins regardless.
  static const ttl = Duration(minutes: 2);

  final DateTime Function() _now;
  final _added = <String, List<({YtPlaylistEntry entry, DateTime at})>>{};
  final _removed = <String, List<({String videoId, DateTime at})>>{};

  void added(String playlistId, YtPlaylistEntry entry) {
    _removed[playlistId]?.removeWhere((r) => r.videoId == entry.videoId);
    (_added[playlistId] ??= []).add((entry: entry, at: _now()));
  }

  void removed(String playlistId, String videoId) {
    _added[playlistId]?.removeWhere((a) => a.entry.videoId == videoId);
    (_removed[playlistId] ??= []).add((videoId: videoId, at: _now()));
  }

  /// [fetched] with this device's recent changes applied. Changes YouTube
  /// already reflects (or that expired) are forgotten.
  List<YtPlaylistEntry> apply(
    String playlistId,
    List<YtPlaylistEntry> fetched,
  ) {
    final cutoff = _now().subtract(ttl);
    final fetchedItems = {for (final e in fetched) e.id};
    final fetchedVideos = {for (final e in fetched) e.videoId};
    final added = (_added[playlistId] ?? [])
      ..removeWhere(
        (a) => a.at.isBefore(cutoff) || fetchedItems.contains(a.entry.id),
      );
    final removed = (_removed[playlistId] ?? [])
      ..removeWhere(
        (r) => r.at.isBefore(cutoff) || !fetchedVideos.contains(r.videoId),
      );
    if (added.isEmpty && removed.isEmpty) {
      _added.remove(playlistId);
      _removed.remove(playlistId);
      return fetched;
    }
    final gone = {for (final r in removed) r.videoId};
    return [
      for (final e in fetched)
        if (!gone.contains(e.videoId)) e,
      for (final a in added) a.entry,
    ];
  }

  void clear() {
    _added.clear();
    _removed.clear();
  }
}
