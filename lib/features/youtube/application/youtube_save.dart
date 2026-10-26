import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_pending_edits.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';

/// YouTube's playlist id for the user's likes. As a [SaveTarget] or edit
/// target it means rating the video, not a playlist item.
const likedVideosId = 'LL';

/// The YouTube playlist hearted songs are saved to.
@immutable
class SaveTarget {
  const SaveTarget(this.id, this.title);

  final String id;

  /// Title when it was chosen; the cached playlist's title wins when known.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is SaveTarget && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);
}

final saveTargetProvider = NotifierProvider<SaveTargetController, SaveTarget?>(
  SaveTargetController.new,
);

/// Which playlist the heart saves to. Stored on this device; forgotten when
/// the account is disconnected.
class SaveTargetController extends Notifier<SaveTarget?> {
  /// `key_values` entry; also deleted by the sync's disconnect cleanup.
  static const storageKey = 'youtube_save_target';

  bool _chosen = false;

  @override
  SaveTarget? build() {
    ref.listen(accountConnectionProvider, (previous, next) {
      final was = previous?.value?.status;
      if (next.value?.status == AccountStatus.disconnected &&
          was != null &&
          was != AccountStatus.disconnected) {
        clear();
      }
    });
    unawaited(_load());
    return null;
  }

  void set(SaveTarget target) {
    _chosen = true;
    state = target;
    unawaited(
      ref.read(settingsRepositoryProvider).writeJson(storageKey, {
        'id': target.id,
        'title': target.title,
      }),
    );
  }

  void clear() {
    _chosen = true;
    state = null;
    unawaited(ref.read(settingsRepositoryProvider).delete(storageKey));
  }

  Future<void> _load() async {
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(storageKey);
    final id = json?['id'];
    final title = json?['title'];
    // A choice made while loading wins over the stored one.
    if (id is String && !_chosen && ref.mounted) {
      state = SaveTarget(id, title is String ? title : 'your playlist');
    }
  }
}

/// Video ids in the target playlist, from the local cache.
final saveTargetVideoIdsProvider = StreamProvider<Set<String>>((ref) {
  final id = ref.watch(saveTargetProvider.select((t) => t?.id));
  if (id == null) return Stream.value(const {});
  final repo = ref.watch(youTubeRepositoryProvider);
  return id == likedVideosId
      ? repo.watchLikedVideoIds()
      : repo.watchPlaylistVideoIds(id);
});

/// Ids of the videos the user liked, from the cache.
final youTubeLikedVideoIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(youTubeRepositoryProvider).watchLikedVideoIds(),
);

/// Display title of the target: the cached playlist's, else the stored one.
final saveTargetTitleProvider = Provider<String?>((ref) {
  final target = ref.watch(saveTargetProvider);
  if (target == null) return null;
  if (target.id == likedVideosId) return 'Liked music';
  final playlists = ref.watch(youTubePlaylistsProvider).value ?? const [];
  return playlists.where((p) => p.id == target.id).firstOrNull?.title ??
      target.title;
});

/// Ids of the user's playlists that contain a video id, from the cache.
final youTubePlaylistsWithVideoProvider = StreamProvider.autoDispose
    .family<Set<String>, String>(
      (ref, videoId) =>
          ref.watch(youTubeRepositoryProvider).watchPlaylistsWithVideo(videoId),
    );

/// Whether the heart for a video id is filled: the optimistic value while a
/// change is pending, else whether the cached target playlist contains it.
final youTubeSavedProvider = Provider.autoDispose.family<bool, String>((
  ref,
  videoId,
) {
  final pending = ref.watch(
    youTubeSaveProvider.select((s) => s.overrides[videoId]),
  );
  if (pending != null) return pending;
  return ref.watch(saveTargetVideoIdsProvider).value?.contains(videoId) ??
      false;
});

enum SaveResult {
  saved,
  removed,

  /// No playlist chosen yet: ask the user, then call again.
  needsTarget,

  /// The write scope is missing (never granted, or YouTube answered 403
  /// insufficientPermissions): ask for it, then call again.
  needsPermission,
  failed,

  /// A change for this video is already in flight (double tap).
  ignored,
}

@immutable
class SaveOutcome {
  const SaveOutcome(this.result, [this.message]);

  final SaveResult result;

  /// Toast text for [SaveResult.saved], [SaveResult.removed] and
  /// [SaveResult.failed].
  final String? message;
}

@immutable
class YouTubeSaveState {
  const YouTubeSaveState({
    this.overrides = const {},
    this.inFlight = const {},
    this.authorizing = false,
  });

  /// Video id → shown state while YouTube has not confirmed it yet (kept
  /// until the cache catches up).
  final Map<String, bool> overrides;

  /// Video ids with a request running.
  final Set<String> inFlight;

  /// The browser is open asking for the playlist permission.
  final bool authorizing;

  YouTubeSaveState copyWith({
    Map<String, bool>? overrides,
    Set<String>? inFlight,
    bool? authorizing,
  }) => YouTubeSaveState(
    overrides: overrides ?? this.overrides,
    inFlight: inFlight ?? this.inFlight,
    authorizing: authorizing ?? this.authorizing,
  );
}

final youTubeSaveProvider =
    NotifierProvider<YouTubeSaveController, YouTubeSaveState>(
      YouTubeSaveController.new,
    );

/// The heart for YouTube songs: adds the video to, or removes it from, the
/// playlist the user chose ([saveTargetProvider]). With [likedVideosId] as
/// the target it likes the video on YouTube, or clears the rating.
///
/// Each change costs 50 quota units, so a video has at most one request in
/// flight; taps meanwhile are ignored.
class YouTubeSaveController extends Notifier<YouTubeSaveState> {
  @override
  YouTubeSaveState build() {
    // Once the cache reflects a finished change, its override is redundant.
    ref
      ..listen(saveTargetVideoIdsProvider, (_, _) => _dropSettled())
      ..listen(saveTargetProvider, (_, _) => _dropSettled());
    return const YouTubeSaveState();
  }

  /// Adds [track] to the target playlist, or removes it when it is there.
  Future<SaveOutcome> toggle(Track track) async {
    final videoId = track.uri;
    if (track.source != MediaSource.youtube || videoId.isEmpty) {
      return const SaveOutcome(SaveResult.ignored);
    }
    if (state.inFlight.contains(videoId)) {
      return const SaveOutcome(SaveResult.ignored);
    }
    final account = ref.read(accountServiceProvider).current;
    if (!account.isConnected) {
      return const SaveOutcome(
        SaveResult.failed,
        'Connect your Google account in Settings to save songs.',
      );
    }
    final target = ref.read(saveTargetProvider);
    if (target == null) return const SaveOutcome(SaveResult.needsTarget);
    if (!account.canSaveToPlaylists) {
      return const SaveOutcome(SaveResult.needsPermission);
    }

    final repo = ref.read(youTubeRepositoryProvider);
    // Reserve the video before the first await so a second tap is ignored.
    state = state.copyWith(inFlight: {...state.inFlight, videoId});
    final liked = target.id == likedVideosId;
    final save =
        !(state.overrides[videoId] ??
            await (liked
                ? repo.isLiked(videoId)
                : repo.playlistContains(target.id, videoId)));
    state = state.copyWith(overrides: {...state.overrides, videoId: save});
    final title = ref.read(saveTargetTitleProvider) ?? target.title;
    try {
      if (liked) {
        await _rate(track, like: save);
      } else if (save) {
        await _insert(target.id, track);
      } else {
        final ids = await repo.playlistItemIds(target.id, videoId);
        await _delete(target.id, videoId, ids);
        await repo.removePlaylistItems(target.id, videoId);
      }
      _finish(videoId, keepOverride: true);
      return SaveOutcome(
        save ? SaveResult.saved : SaveResult.removed,
        save ? 'Saved to $title' : 'Removed from $title',
      );
    } on YouTubeApiException catch (e) {
      debugPrint('YouTube save failed: ${e.kind.name}');
      _finish(videoId, keepOverride: false);
      return switch (e.kind) {
        YouTubeErrorKind.permission => const SaveOutcome(
          SaveResult.needsPermission,
        ),
        YouTubeErrorKind.notFound => SaveOutcome(
          SaveResult.failed,
          '"$title" is no longer available on YouTube. Choose another '
          'playlist in Settings.',
        ),
        _ => SaveOutcome(
          SaveResult.failed,
          save
              ? "Couldn't save to $title. ${e.message}"
              : "Couldn't remove from $title. ${e.message}",
        ),
      };
    }
  }

  /// Adds [track] to the user's playlist [playlistId] ("Add to playlist…").
  /// Reports [SaveResult.saved], or why not.
  Future<SaveOutcome> addTo(String playlistId, Track track) => _edit(
    playlistId,
    track,
    add: true,
    run: () => playlistId == likedVideosId
        ? _rate(track, like: true)
        : _insert(playlistId, track),
  );

  /// Removes every copy of [track] from [playlistId]. The cached list drops
  /// it at once and gets it back if YouTube refuses.
  Future<SaveOutcome> removeFrom(String playlistId, Track track) {
    final repo = ref.read(youTubeRepositoryProvider);
    return _edit(
      playlistId,
      track,
      add: false,
      run: () async {
        if (playlistId == likedVideosId) {
          await _rate(track, like: false);
          return;
        }
        final rows = await repo.removePlaylistItems(playlistId, track.uri);
        try {
          await _delete(playlistId, track.uri, [
            for (final r in rows) ?r.itemId,
          ]);
        } on Object {
          await repo.restorePlaylistItems(rows);
          rethrow;
        }
      },
    );
  }

  Future<SaveOutcome> _edit(
    String playlistId,
    Track track, {
    required bool add,
    required Future<void> Function() run,
  }) async {
    final key = '$playlistId/${track.uri}';
    if (track.source != MediaSource.youtube || track.uri.isEmpty) {
      return const SaveOutcome(SaveResult.ignored);
    }
    if (state.inFlight.contains(key)) {
      return const SaveOutcome(SaveResult.ignored);
    }
    if (!ref.read(accountServiceProvider).current.canSaveToPlaylists) {
      return const SaveOutcome(SaveResult.needsPermission);
    }
    final title = playlistId == likedVideosId
        ? 'Liked music'
        : (ref.read(youTubePlaylistsProvider).value ?? const [])
                  .where((p) => p.id == playlistId)
                  .firstOrNull
                  ?.title ??
              'the playlist';
    state = state.copyWith(inFlight: {...state.inFlight, key});
    try {
      await run();
      return SaveOutcome(
        add ? SaveResult.saved : SaveResult.removed,
        add ? 'Added to $title' : 'Removed from $title',
      );
    } on YouTubeApiException catch (e) {
      debugPrint('YouTube playlist edit failed: ${e.kind.name}');
      return switch (e.kind) {
        YouTubeErrorKind.permission => const SaveOutcome(
          SaveResult.needsPermission,
        ),
        _ => SaveOutcome(
          SaveResult.failed,
          add
              ? "Couldn't add to $title. ${e.message}"
              : "Couldn't remove from $title. ${e.message}",
        ),
      };
    } finally {
      if (ref.mounted) {
        state = state.copyWith(inFlight: {...state.inFlight}..remove(key));
      }
    }
  }

  /// Appends [track] on YouTube, then to the cache.
  Future<void> _insert(String playlistId, Track track) async {
    final itemId = await ref
        .read(youTubeApiProvider)
        .insertPlaylistItem(playlistId, track.uri);
    ref
        .read(youTubePendingEditsProvider)
        .added(playlistId, YtPlaylistEntry(id: itemId, videoId: track.uri));
    await ref
        .read(youTubeRepositoryProvider)
        .addPlaylistItem(playlistId, itemId, track);
  }

  /// Likes [track] on YouTube or clears its rating, and updates the cached
  /// likes (put back if YouTube refuses an unlike).
  Future<void> _rate(Track track, {required bool like}) async {
    final repo = ref.read(youTubeRepositoryProvider);
    final edits = ref.read(youTubePendingEditsProvider);
    if (like) {
      await ref.read(youTubeApiProvider).rate(track.uri, YtRating.like);
      edits.added(
        likedVideosId,
        YtPlaylistEntry(id: track.uri, videoId: track.uri),
      );
      await repo.addLike(track);
      return;
    }
    final row = await repo.removeLike(track.uri);
    try {
      await ref.read(youTubeApiProvider).rate(track.uri, YtRating.none);
    } on Object {
      if (row != null) await repo.restoreLike(row);
      rethrow;
    }
    edits.removed(likedVideosId, track.uri);
  }

  /// Deletes the items [itemIds] (looked up on YouTube when unknown) of
  /// [videoId] on YouTube. The cache is the caller's.
  Future<void> _delete(
    String playlistId,
    String videoId,
    List<String> itemIds,
  ) async {
    final api = ref.read(youTubeApiProvider);
    final ids = itemIds.isNotEmpty
        ? itemIds
        : await api.playlistItemIdsFor(playlistId, videoId);
    for (final id in ids) {
      try {
        await api.deletePlaylistItem(id);
      } on YouTubeApiException catch (e) {
        // Already removed on YouTube: that is the goal anyway.
        if (e.kind != YouTubeErrorKind.notFound) rethrow;
      }
    }
    ref.read(youTubePendingEditsProvider).removed(playlistId, videoId);
  }

  /// Asks Google for the playlist permission (browser). When not granted,
  /// `message` says why (null when the user cancelled).
  Future<({bool granted, String? message})> requestWriteAccess() async {
    state = state.copyWith(authorizing: true);
    try {
      await ref.read(accountServiceProvider).requestWriteAccess();
      return (granted: true, message: null);
    } on OAuthCancelled {
      return (granted: false, message: null);
    } on OAuthException catch (e) {
      return (granted: false, message: e.message);
    } finally {
      if (ref.mounted) state = state.copyWith(authorizing: false);
    }
  }

  /// Stops waiting for the browser.
  void cancelAuthorization() =>
      ref.read(accountServiceProvider).cancelConnect();

  /// Creates a private playlist on YouTube (50 units), caches it and makes
  /// it the target. Throws [YouTubeApiException].
  Future<SaveTarget> createTarget(String title) async {
    final playlist = await createPlaylist(title);
    final target = SaveTarget(playlist.id, playlist.title);
    ref.read(saveTargetProvider.notifier).set(target);
    return target;
  }

  /// Creates a private playlist on YouTube (50 units) and caches it.
  /// Throws [YouTubeApiException].
  Future<YtPlaylist> createPlaylist(String title) async {
    final playlist = await ref.read(youTubeApiProvider).createPlaylist(title);
    await ref.read(youTubeRepositoryProvider).addPlaylist(playlist);
    return playlist;
  }

  void _finish(String videoId, {required bool keepOverride}) {
    if (!ref.mounted) return;
    state = state.copyWith(
      inFlight: {...state.inFlight}..remove(videoId),
      overrides: keepOverride
          ? state.overrides
          : ({...state.overrides}..remove(videoId)),
    );
  }

  void _dropSettled() {
    final settled = state.overrides.keys.where(
      (id) => !state.inFlight.contains(id),
    );
    if (settled.isEmpty) return;
    state = state.copyWith(
      overrides: {
        for (final e in state.overrides.entries)
          if (state.inFlight.contains(e.key)) e.key: e.value,
      },
    );
  }
}
