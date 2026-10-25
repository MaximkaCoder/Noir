import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_pending_edits.dart';
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

/// Brings one playlist (or the likes) up to date when its page is opened
/// (or NOIR comes back to the foreground with it open), so changes made on
/// YouTube show up without waiting for the next full sync — which a page
/// never waits for.
///
/// Each page is checked at most once per [pageGap]. A playlist check reads
/// its items directly (1 unit per 50 songs): the playlist's own etag can lag
/// behind its items. The database is only written when something changed.
/// Likes use a conditional request. Failures keep the cached list and are
/// reported in [state].
class YouTubeRefreshController extends Notifier<YouTubeRefreshState> {
  static const likesKey = ':likes';

  /// Re-opening the same page sooner than this does not ask YouTube again.
  static const pageGap = Duration(seconds: 5);

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
    final now = ref.read(youTubeClockProvider)();
    final last = _checkedAt[key];
    if (last != null && now.difference(last) < pageGap) return Future.value();
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
    final row = await repo.playlistRow(id);
    // Unknown playlists are left to the full sync (it keeps the order).
    if (row == null) return;
    final List<YtPlaylistEntry> fetched;
    try {
      fetched = await api.playlistItems(id);
    } on YouTubeApiException catch (e) {
      // Deleted or no longer visible: the next full sync drops it.
      if (e.kind == YouTubeErrorKind.notFound) return;
      rethrow;
    }
    final items = ref.read(youTubePendingEditsProvider).apply(id, fetched);
    if (_same(await repo.playlistEntries(id), items)) return;
    final missing = await repo.videosNeedingDetails(
      items.map((i) => i.videoId),
    );
    if (missing.isNotEmpty) await repo.saveVideos(await api.videos(missing));
    // The items etag stays: it tells the full sync which playlist version
    // these items were last fully compared with.
    await repo.savePlaylistItems(id, row.itemsEtag ?? '', items);
  }

  static bool _same(List<YtPlaylistEntry> a, List<YtPlaylistEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].videoId != b[i].videoId || a[i].id != b[i].id) return false;
    }
    return true;
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
