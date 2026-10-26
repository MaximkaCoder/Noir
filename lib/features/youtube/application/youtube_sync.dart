import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_pending_edits.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

final youTubeApiProvider = Provider<YouTubeApi>((ref) {
  final account = ref.watch(accountServiceProvider);
  return YouTubeApi(
    dio: ref.watch(httpClientProvider),
    accessToken: account.accessToken,
  );
});

/// Current time; overridden in tests to step over refresh throttles.
final youTubeClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

enum SyncStatus { idle, syncing, failed }

@immutable
class YouTubeSyncState {
  const YouTubeSyncState({
    this.status = SyncStatus.idle,
    this.lastSyncAt,
    this.message,
  });

  final SyncStatus status;
  final DateTime? lastSyncAt;

  /// User-facing reason when [status] is failed.
  final String? message;

  YouTubeSyncState copyWith({
    SyncStatus? status,
    DateTime? lastSyncAt,
    String? message,
  }) => YouTubeSyncState(
    status: status ?? this.status,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    message: message,
  );
}

final youTubeSyncProvider =
    NotifierProvider<YouTubeSyncController, YouTubeSyncState>(
      YouTubeSyncController.new,
    );

/// Keeps the local YouTube cache in step with the account.
///
/// The YouTube Data API cannot push changes, so NOIR asks: when the account
/// connects, at startup, when the app comes back to the foreground after a
/// few minutes, every 15 minutes while open, and on demand. Playlists whose
/// etag did not change are not downloaded again.
class YouTubeSyncController extends Notifier<YouTubeSyncState>
    with WidgetsBindingObserver {
  static const interval = Duration(minutes: 15);
  static const foregroundGap = Duration(minutes: 5);

  /// Opening the Library's YouTube section re-reads the playlist list at
  /// most this often.
  static const refreshGap = Duration(seconds: 30);
  static const _metaKey = 'youtube_sync';

  Timer? _timer;
  Future<void>? _running;

  /// Etag of the likes NOIR has, so an unchanged list costs one request.
  String? _likesEtag;

  @override
  YouTubeSyncState build() {
    WidgetsBinding.instance.addObserver(this);
    ref
      ..onDispose(() {
        WidgetsBinding.instance.removeObserver(this);
        _timer?.cancel();
      })
      ..listen(accountConnectionProvider, (previous, next) {
        final was = previous?.value?.status;
        final now = next.value?.status;
        if (now == AccountStatus.connected && was != AccountStatus.connected) {
          _startSchedule();
          unawaited(sync());
        } else if (now == AccountStatus.disconnected &&
            was != AccountStatus.disconnected &&
            was != null) {
          _timer?.cancel();
          unawaited(_forget());
        }
      }, fireImmediately: true);
    unawaited(_loadMeta());
    return const YouTubeSyncState();
  }

  bool get _connected =>
      ref.read(accountServiceProvider).current.status ==
      AccountStatus.connected;

  /// Runs a sync unless one is already in progress.
  Future<void> sync({bool force = false}) {
    if (!_connected) return Future.value();
    return _running ??= _sync(force: force).whenComplete(() => _running = null);
  }

  /// Completes when no sync is running.
  Future<void> whenIdle() => _running ?? Future.value();

  /// Whether a sync is running or finished less than [refreshGap] ago, so a
  /// page refresh would learn nothing new.
  bool get isFresh {
    final last = state.lastSyncAt;
    return _running != null ||
        (last != null && _now().difference(last) < refreshGap);
  }

  /// Re-reads the playlist list (and likes) when the user looks at it — the
  /// Library's YouTube section — unless that happened in the last
  /// [refreshGap]. Unchanged playlists are not downloaded again.
  Future<void> refreshPlaylists() => isFresh ? whenIdle() : sync();

  DateTime _now() => ref.read(youTubeClockProvider)();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = this.state.lastSyncAt;
    if (last == null || _now().difference(last) > foregroundGap) {
      unawaited(sync());
    }
  }

  void _startSchedule() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(sync()));
  }

  Future<void> _sync({required bool force}) async {
    final api = ref.read(youTubeApiProvider);
    final repo = ref.read(youTubeRepositoryProvider);
    state = state.copyWith(status: SyncStatus.syncing);
    try {
      await repo.purgeStale();

      final playlists = await api.myPlaylists();
      final known = await repo.itemEtags();
      await repo.savePlaylists(playlists);

      final changed = [
        for (final p in playlists)
          if (force || known[p.id] != p.etag) p,
      ];
      final edits = ref.read(youTubePendingEditsProvider);
      // A few playlists at a time: fast, without bursting the API.
      for (var i = 0; i < changed.length; i += 3) {
        await Future.wait([
          for (final p in changed.skip(i).take(3))
            api
                .playlistItems(p.id)
                .then(
                  (items) => repo.savePlaylistItems(
                    p.id,
                    p.etag,
                    edits.apply(p.id, items),
                  ),
                ),
        ]);
      }

      final likes = await api.likedVideosIfChanged(
        ifNoneMatch: force ? null : _likesEtag,
      );
      if (likes != null) {
        final fetched = {for (final v in likes.value) v.id};
        final kept = [
          for (final e in edits.apply(likedVideosId, [
            for (final id in fetched) YtPlaylistEntry(id: id, videoId: id),
          ]))
            e.videoId,
        ];
        // Likes made here and not listed yet are the newest.
        await repo.saveLikes(likes.value, [
          ...kept.where((id) => !fetched.contains(id)),
          ...kept.where(fetched.contains),
        ]);
        _likesEtag = likes.etag;
      }

      final missing = await repo.videosNeedingDetails(
        await repo.referencedVideoIds(),
      );
      if (missing.isNotEmpty) await repo.saveVideos(await api.videos(missing));

      final now = _now();
      await ref.read(settingsRepositoryProvider).writeJson(_metaKey, {
        'lastSyncAt': now.toIso8601String(),
      });
      state = YouTubeSyncState(lastSyncAt: now);
    } on YouTubeApiException catch (e) {
      debugPrint('YouTube sync failed: ${e.kind.name}');
      state = state.copyWith(status: SyncStatus.failed, message: e.message);
    }
  }

  Future<void> _forget() async {
    _likesEtag = null;
    ref.read(youTubePendingEditsProvider).clear();
    await ref.read(youTubeRepositoryProvider).clearAll();
    await ref.read(settingsRepositoryProvider).delete(_metaKey);
    // The chosen save playlist belongs to the account that just left.
    await ref
        .read(settingsRepositoryProvider)
        .delete(SaveTargetController.storageKey);
    state = const YouTubeSyncState();
  }

  Future<void> _loadMeta() async {
    final json = await ref.read(settingsRepositoryProvider).readJson(_metaKey);
    final last = DateTime.tryParse(json?['lastSyncAt'] as String? ?? '');
    if (last != null && state.lastSyncAt == null) {
      state = state.copyWith(lastSyncAt: last, status: state.status);
    }
  }
}
