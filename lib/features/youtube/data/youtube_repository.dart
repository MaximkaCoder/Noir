import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/youtube/domain/music_filter.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';

final youTubeRepositoryProvider = Provider<YouTubeRepository>(
  (ref) => YouTubeRepository(ref.watch(databaseProvider)),
);

/// A playlist from the connected YouTube account.
class YouTubePlaylist {
  const YouTubePlaylist({
    required this.id,
    required this.title,
    required this.trackCount,
    required this.totalDuration,
    this.thumbnailUrl,
  });

  final String id;
  final String title;

  /// Playable items synced so far (may be lower than YouTube's count when
  /// videos were deleted or made private).
  final int trackCount;
  final Duration totalDuration;
  final String? thumbnailUrl;
}

extension YtVideoRowX on YtVideoRow {
  Track toTrack() => Track(
    id: 'yt:$id',
    source: MediaSource.youtube,
    title: title,
    uri: id,
    artist: artistFromChannel(channelTitle),
    duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
    // 16:9 frame without letterbox bars; its center square is the cover.
    artworkUrl: YouTubeCover.thumbnail(id),
  );
}

/// Local cache of YouTube data. Policy: refresh or delete within 30 days;
/// delete everything on disconnect.
class YouTubeRepository {
  YouTubeRepository(this._db);

  final AppDatabase _db;

  static const maxAge = Duration(days: 30);

  /// Videos older than this are re-fetched during sync, so nothing reaches
  /// [maxAge] while the account stays connected.
  static const refreshAge = Duration(days: 25);

  Stream<List<YouTubePlaylist>> watchPlaylists() => _db
      .customSelect(
        'SELECT p.id, p.title, p.thumbnail_url, COUNT(v.id) AS n, '
        'COALESCE(SUM(v.duration_ms), 0) AS ms '
        'FROM yt_playlists p '
        'LEFT JOIN yt_playlist_items i ON i.playlist_id = p.id '
        'LEFT JOIN yt_videos v ON v.id = i.video_id '
        'GROUP BY p.id ORDER BY p.position',
        readsFrom: {_db.ytPlaylists, _db.ytPlaylistItems, _db.ytVideos},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            YouTubePlaylist(
              id: r.read<String>('id'),
              title: r.read<String>('title'),
              thumbnailUrl: r.readNullable<String>('thumbnail_url'),
              trackCount: r.read<int>('n'),
              totalDuration: Duration(milliseconds: r.read<int>('ms')),
            ),
        ],
      );

  Stream<YouTubePlaylist?> watchPlaylist(String id) =>
      watchPlaylists().map((all) => all.where((p) => p.id == id).firstOrNull);

  Stream<List<Track>> watchPlaylistTracks(String playlistId) {
    final i = _db.ytPlaylistItems;
    final v = _db.ytVideos;
    final query = _db.select(i).join([innerJoin(v, v.id.equalsExp(i.videoId))])
      ..where(i.playlistId.equals(playlistId))
      ..orderBy([OrderingTerm.asc(i.position)]);
    return query.watch().map(
      (rows) => [for (final r in rows) r.readTable(v).toTrack()],
    );
  }

  /// Liked videos, newest like first; with [musicOnly], only those
  /// [isMusicVideo] accepts.
  Stream<List<Track>> watchLikes({bool musicOnly = false}) {
    final l = _db.ytLikes;
    final v = _db.ytVideos;
    final query = _db.select(l).join([innerJoin(v, v.id.equalsExp(l.videoId))])
      ..orderBy([OrderingTerm.asc(l.position)]);
    return query.watch().map(
      (rows) => [
        for (final r in rows.map((r) => r.readTable(v)))
          if (!musicOnly ||
              isMusicVideo(
                categoryId: r.categoryId,
                channelTitle: r.channelTitle,
              ))
            r.toTrack(),
      ],
    );
  }

  Stream<int> watchLikeCount() {
    final count = _db.ytLikes.videoId.count();
    return (_db.selectOnly(
      _db.ytLikes,
    )..addColumns([count])).map((r) => r.read(count) ?? 0).watchSingle();
  }

  Future<YtPlaylistRow?> playlistRow(String id) => (_db.select(
    _db.ytPlaylists,
  )..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Updates one known playlist's details (not its position or items).
  Future<void> updatePlaylist(YtPlaylist p) =>
      (_db.update(_db.ytPlaylists)..where((r) => r.id.equals(p.id))).write(
        YtPlaylistsCompanion(
          title: Value(p.title),
          itemCount: Value(p.itemCount),
          etag: Value(p.etag),
          thumbnailUrl: Value(p.thumbnailUrl),
          privacy: Value(p.privacy),
          syncedAt: Value(DateTime.now()),
        ),
      );

  /// Playlist id → etag of the items NOIR already has.
  Future<Map<String, String?>> itemEtags() async {
    final rows = await _db.select(_db.ytPlaylists).get();
    return {for (final r in rows) r.id: r.itemsEtag};
  }

  /// Replaces the playlist list; playlists deleted on YouTube disappear.
  Future<void> savePlaylists(List<YtPlaylist> playlists) => _db.transaction(
    () async {
      final now = DateTime.now();
      final ids = [for (final p in playlists) p.id];
      await (_db.delete(_db.ytPlaylists)..where((p) => p.id.isNotIn(ids))).go();
      for (final (index, p) in playlists.indexed) {
        await _db
            .into(_db.ytPlaylists)
            .insert(
              YtPlaylistsCompanion.insert(
                id: p.id,
                title: p.title,
                itemCount: p.itemCount,
                etag: p.etag,
                thumbnailUrl: Value(p.thumbnailUrl),
                privacy: Value(p.privacy),
                position: index,
                syncedAt: now,
              ),
              onConflict: DoUpdate(
                (_) => YtPlaylistsCompanion(
                  title: Value(p.title),
                  itemCount: Value(p.itemCount),
                  etag: Value(p.etag),
                  thumbnailUrl: Value(p.thumbnailUrl),
                  privacy: Value(p.privacy),
                  position: Value(index),
                  syncedAt: Value(now),
                ),
              ),
            );
      }
    },
  );

  Future<void> savePlaylistItems(
    String playlistId,
    String etag,
    List<YtPlaylistEntry> items,
  ) => _db.transaction(() async {
    await (_db.delete(
      _db.ytPlaylistItems,
    )..where((i) => i.playlistId.equals(playlistId))).go();
    await _db.batch((b) {
      for (final (index, item) in items.indexed) {
        b.insert(
          _db.ytPlaylistItems,
          YtPlaylistItemsCompanion.insert(
            playlistId: playlistId,
            position: index,
            videoId: item.videoId,
            itemId: Value(item.id),
          ),
        );
      }
    });
    await (_db.update(_db.ytPlaylists)..where((p) => p.id.equals(playlistId)))
        .write(YtPlaylistsCompanion(itemsEtag: Value(etag)));
  });

  /// Video ids in [playlistId], updated as the cache changes.
  Stream<Set<String>> watchPlaylistVideoIds(String playlistId) =>
      (_db.select(_db.ytPlaylistItems)
            ..where((i) => i.playlistId.equals(playlistId)))
          .watch()
          .map((rows) => {for (final r in rows) r.videoId});

  Future<bool> playlistContains(String playlistId, String videoId) async =>
      (await _itemsOf(playlistId, videoId).get()).isNotEmpty;

  /// Known YouTube item ids of [videoId] in [playlistId] (rows cached before
  /// schema v4 have none).
  Future<List<String>> playlistItemIds(
    String playlistId,
    String videoId,
  ) async => [
    for (final r in await _itemsOf(playlistId, videoId).get()) ?r.itemId,
  ];

  /// Appends a video NOIR just added on YouTube. [track] supplies the video
  /// details when they are not cached yet (the next sync completes them).
  Future<void> addPlaylistItem(String playlistId, String itemId, Track track) =>
      _db.transaction(() async {
        final max = _db.ytPlaylistItems.position.max();
        final last =
            await (_db.selectOnly(_db.ytPlaylistItems)
                  ..addColumns([max])
                  ..where(_db.ytPlaylistItems.playlistId.equals(playlistId)))
                .map((r) => r.read(max))
                .getSingle();
        await _db
            .into(_db.ytVideos)
            .insert(
              YtVideosCompanion.insert(
                id: track.uri,
                title: track.title,
                channelTitle: track.artist ?? '',
                durationMs: Value(track.duration?.inMilliseconds),
                syncedAt: DateTime.now(),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await _db
            .into(_db.ytPlaylistItems)
            .insert(
              YtPlaylistItemsCompanion.insert(
                playlistId: playlistId,
                position: (last ?? -1) + 1,
                videoId: track.uri,
                itemId: Value(itemId),
              ),
            );
      });

  /// Drops every cached entry of [videoId] in [playlistId].
  Future<void> removePlaylistItems(String playlistId, String videoId) =>
      (_db.delete(_db.ytPlaylistItems)..where(
            (i) => i.playlistId.equals(playlistId) & i.videoId.equals(videoId),
          ))
          .go();

  /// Adds a playlist NOIR just created on YouTube, after the known ones
  /// (the next sync puts it where YouTube lists it).
  Future<void> addPlaylist(YtPlaylist p) => _db.transaction(() async {
    final max = _db.ytPlaylists.position.max();
    final last = await (_db.selectOnly(
      _db.ytPlaylists,
    )..addColumns([max])).map((r) => r.read(max)).getSingle();
    await _db
        .into(_db.ytPlaylists)
        .insertOnConflictUpdate(
          YtPlaylistsCompanion.insert(
            id: p.id,
            title: p.title,
            itemCount: p.itemCount,
            etag: p.etag,
            thumbnailUrl: Value(p.thumbnailUrl),
            privacy: Value(p.privacy),
            position: (last ?? -1) + 1,
            syncedAt: DateTime.now(),
            // Empty and known: nothing to download.
            itemsEtag: Value(p.etag),
          ),
        );
  });

  SimpleSelectStatement<$YtPlaylistItemsTable, YtPlaylistItem> _itemsOf(
    String playlistId,
    String videoId,
  ) => _db.select(_db.ytPlaylistItems)
    ..where((i) => i.playlistId.equals(playlistId) & i.videoId.equals(videoId));

  Future<void> saveVideos(List<YtVideo> videos) {
    final now = DateTime.now();
    return _db.batch((b) {
      for (final v in videos) {
        b.insert(
          _db.ytVideos,
          YtVideosCompanion.insert(
            id: v.id,
            title: v.title,
            channelTitle: v.channelTitle,
            durationMs: Value(v.duration?.inMilliseconds),
            thumbnailUrl: Value(v.thumbnailUrl),
            embeddable: Value(v.embeddable),
            categoryId: Value(v.categoryId),
            syncedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> saveLikes(List<YtVideo> videos) => _db.transaction(() async {
    await saveVideos(videos);
    await _db.delete(_db.ytLikes).go();
    await _db.batch((b) {
      for (final (index, v) in videos.indexed) {
        b.insert(
          _db.ytLikes,
          YtLikesCompanion.insert(videoId: v.id, position: index),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  });

  /// Ids from [ids] that need details: unknown, older than [refreshAge], or
  /// cached before categories were stored (backfill; 1 unit per 50 videos).
  Future<List<String>> videosNeedingDetails(Iterable<String> ids) async {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return const [];
    final cutoff = DateTime.now().subtract(refreshAge);
    final fresh = <String>{};
    final list = wanted.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final rows =
          await (_db.select(_db.ytVideos)..where(
                (v) =>
                    v.id.isIn(chunk) &
                    v.syncedAt.isBiggerThanValue(cutoff) &
                    v.categoryId.isNotNull(),
              ))
              .get();
      fresh.addAll(rows.map((r) => r.id));
    }
    return wanted.difference(fresh).toList();
  }

  /// Every cached video id still referenced by a playlist or like.
  Future<Set<String>> referencedVideoIds() async {
    final rows = await _db
        .customSelect(
          'SELECT video_id FROM yt_playlist_items '
          'UNION SELECT video_id FROM yt_likes',
        )
        .get();
    return {for (final r in rows) r.read<String>('video_id')};
  }

  /// Drops anything not refreshed for [maxAge] and unreferenced videos.
  Future<void> purgeStale() => _db.transaction(() async {
    final cutoff = DateTime.now().subtract(maxAge);
    await (_db.delete(
      _db.ytPlaylists,
    )..where((p) => p.syncedAt.isSmallerThanValue(cutoff))).go();
    await (_db.delete(
      _db.ytVideos,
    )..where((v) => v.syncedAt.isSmallerThanValue(cutoff))).go();
    await _db.customStatement(
      'DELETE FROM yt_videos WHERE id NOT IN '
      '(SELECT video_id FROM yt_playlist_items '
      'UNION SELECT video_id FROM yt_likes)',
    );
  });

  /// Removes every YouTube-derived row (on disconnect).
  Future<void> clearAll() => _db.transaction(() async {
    await _db.delete(_db.ytPlaylistItems).go();
    await _db.delete(_db.ytLikes).go();
    await _db.delete(_db.ytPlaylists).go();
    await _db.delete(_db.ytVideos).go();
  });
}
