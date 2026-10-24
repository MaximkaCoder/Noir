import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';

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
  return ref.watch(youTubeRepositoryProvider).watchPlaylistVideoIds(id);
});

/// Display title of the target: the cached playlist's, else the stored one.
final saveTargetTitleProvider = Provider<String?>((ref) {
  final target = ref.watch(saveTargetProvider);
  if (target == null) return null;
  final playlists = ref.watch(youTubePlaylistsProvider).value ?? const [];
  return playlists.where((p) => p.id == target.id).firstOrNull?.title ??
      target.title;
});

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
/// playlist the user chose ([saveTargetProvider]). It never likes or rates
/// anything on YouTube.
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
    final api = ref.read(youTubeApiProvider);
    // Reserve the video before the first await so a second tap is ignored.
    state = state.copyWith(inFlight: {...state.inFlight, videoId});
    final save =
        !(state.overrides[videoId] ??
            await repo.playlistContains(target.id, videoId));
    state = state.copyWith(overrides: {...state.overrides, videoId: save});
    final title = ref.read(saveTargetTitleProvider) ?? target.title;
    try {
      if (save) {
        final itemId = await api.insertPlaylistItem(target.id, videoId);
        await repo.addPlaylistItem(target.id, itemId, track);
      } else {
        var ids = await repo.playlistItemIds(target.id, videoId);
        if (ids.isEmpty) {
          ids = await api.playlistItemIdsFor(target.id, videoId);
        }
        for (final id in ids) {
          try {
            await api.deletePlaylistItem(id);
          } on YouTubeApiException catch (e) {
            // Already removed on YouTube: that is the goal anyway.
            if (e.kind != YouTubeErrorKind.notFound) rethrow;
          }
        }
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
    final playlist = await ref.read(youTubeApiProvider).createPlaylist(title);
    await ref.read(youTubeRepositoryProvider).addPlaylist(playlist);
    final target = SaveTarget(playlist.id, playlist.title);
    ref.read(saveTargetProvider.notifier).set(target);
    return target;
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
