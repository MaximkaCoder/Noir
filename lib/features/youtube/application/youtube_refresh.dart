import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

/// Refreshes of single YouTube pages in flight, and the last failure of each.
@immutable
class YouTubeRefreshState {
  const YouTubeRefreshState({this.running = const {}, this.errors = const {}});

  /// Keys ([YouTubeRefreshController.likesKey] or a playlist id) being
  /// refreshed.
  final Set<String> running;

  /// Key → user-facing message of the last failed refresh.
  final Map<String, String> errors;
}

final youTubeRefreshProvider =
    NotifierProvider<YouTubeRefreshController, YouTubeRefreshState>(
      YouTubeRefreshController.new,
    );

/// Brings one playlist (or the likes) up to date when its page is opened,
/// so changes made on YouTube show up without waiting for the next full
/// sync.
///
/// Each page is checked at most once per [YouTubeSyncController.refreshGap]
/// (and not at all right after a full sync). Checks are conditional
/// requests: while nothing changed YouTube answers 304 and the database is
/// not touched. Failures keep the cached list and are reported in [state].
class YouTubeRefreshController extends Notifier<YouTubeRefreshState> {
  static const likesKey = ':likes';

  final _checkedAt = <String, DateTime>{};
  final _etags = <String, String>{};
  final _inFlight = <String, Future<void>>{};

  @override
  YouTubeRefreshState build() => const YouTubeRefreshState();

  Future<void> refreshPlaylist(String id) => _refresh(id, () => _playlist(id));

  Future<void> refreshLikes() => _refresh(likesKey, _likes);

  Future<void> _refresh(String key, Future<void> Function() work) {
    final running = _inFlight[key];
    if (running != null) return running;
    if (ref.read(accountServiceProvider).current.status !=
        AccountStatus.connected) {
      // Etags describe data that disconnecting deleted.
      _etags.clear();
      _checkedAt.clear();
      return Future.value();
    }
    final sync = ref.read(youTubeSyncProvider.notifier);
    if (sync.isFresh) return sync.whenIdle();
    final now = ref.read(youTubeClockProvider)();
    final last = _checkedAt[key];
    if (last != null &&
        now.difference(last) < YouTubeSyncController.refreshGap) {
      return Future.value();
    }
    _checkedAt[key] = now;
    // A block body: returning the removed future would make this one wait
    // for itself.
    return _inFlight[key] = _run(key, work).whenComplete(() {
      unawaited(_inFlight.remove(key));
    });
  }

  Future<void> _run(String key, Future<void> Function() work) async {
    state = YouTubeRefreshState(
      running: {...state.running, key},
      errors: {...state.errors}..remove(key),
    );
    String? failure;
    try {
      await work();
    } on YouTubeApiException catch (e) {
      debugPrint('YouTube refresh failed: ${e.kind.name}');
      failure = e.message;
    }
    if (!ref.mounted) return;
    state = YouTubeRefreshState(
      running: {...state.running}..remove(key),
      errors: {...state.errors, key: ?failure},
    );
  }

  Future<void> _playlist(String id) async {
    final api = ref.read(youTubeApiProvider);
    final repo = ref.read(youTubeRepositoryProvider);
    var fetched = await api.playlist(id, ifNoneMatch: _etags[id]);
    if (fetched == null) {
      // Not modified — as long as NOIR still has the items it saw then.
      if ((await repo.playlistRow(id))?.itemsEtag != null) return;
      fetched = await api.playlist(id);
      if (fetched == null) return;
    }
    final playlist = fetched.value;
    final row = await repo.playlistRow(id);
    // Deleted or no longer visible: the next full sync drops it. Unknown
    // playlists are left to the full sync too (it keeps the order).
    if (playlist == null || row == null) return;

    if (row.etag != playlist.etag) await repo.updatePlaylist(playlist);
    if (row.itemsEtag != playlist.etag) {
      final ids = await api.playlistVideoIds(id);
      final missing = await repo.videosNeedingDetails(ids);
      if (missing.isNotEmpty) await repo.saveVideos(await api.videos(missing));
      await repo.savePlaylistItems(id, playlist.etag, ids);
    }
    if (fetched.etag case final etag?) _etags[id] = etag;
  }

  Future<void> _likes() async {
    final fetched = await ref
        .read(youTubeApiProvider)
        .likedVideosIfChanged(ifNoneMatch: _etags[likesKey]);
    if (fetched == null) return; // 304: unchanged.
    await ref.read(youTubeRepositoryProvider).saveLikes(fetched.value);
    if (fetched.etag case final etag?) _etags[likesKey] = etag;
  }
}
