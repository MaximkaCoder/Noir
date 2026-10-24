import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/shared/models/media.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>(
  (ref) => PlaylistRepository(ref.watch(databaseProvider)),
);

/// A track inside a playlist; `entryId` identifies this occurrence.
typedef PlaylistTrack = ({int entryId, Track track});

/// NOIR's own playlists, stored on this device only.
class PlaylistRepository {
  PlaylistRepository(this._db);

  final AppDatabase _db;

  Stream<List<Playlist>> watchPlaylists() => _db
      .customSelect(
        'SELECT p.id, p.name, p.updated_at, COUNT(e.id) AS n, '
        'COALESCE(SUM(t.duration_ms), 0) AS ms, '
        '(SELECT GROUP_CONCAT(art, char(31)) FROM (SELECT DISTINCT '
        't2.artwork_path AS art FROM playlist_entries e2 '
        'JOIN tracks t2 ON t2.id = e2.track_id '
        'WHERE e2.playlist_id = p.id AND t2.artwork_path IS NOT NULL '
        'ORDER BY e2.position LIMIT 4)) AS arts '
        'FROM playlists p '
        'LEFT JOIN playlist_entries e ON e.playlist_id = p.id '
        'LEFT JOIN tracks t ON t.id = e.track_id '
        'GROUP BY p.id '
        'ORDER BY COALESCE(p.last_opened_at, p.updated_at) DESC',
        readsFrom: {_db.playlists, _db.playlistEntries, _db.tracks},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            Playlist(
              id: r.read<int>('id'),
              name: r.read<String>('name'),
              trackCount: r.read<int>('n'),
              totalDuration: Duration(milliseconds: r.read<int>('ms')),
              updatedAt: r.read<DateTime>('updated_at'),
              artworkPaths:
                  r.readNullable<String>('arts')?.split('\u001f') ?? const [],
            ),
        ],
      );

  Stream<Playlist?> watchPlaylist(int id) =>
      watchPlaylists().map((all) => all.where((p) => p.id == id).firstOrNull);

  Stream<List<PlaylistTrack>> watchTracks(int playlistId) {
    final e = _db.playlistEntries;
    final query =
        _db.select(e).join([
            innerJoin(_db.tracks, _db.tracks.id.equalsExp(e.trackId)),
          ])
          ..where(e.playlistId.equals(playlistId))
          ..orderBy([OrderingTerm.asc(e.position)]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          (
            entryId: row.readTable(e).id,
            track: row.readTable(_db.tracks).toTrack(),
          ),
      ],
    );
  }

  Future<int> create(String name) {
    final now = DateTime.now();
    return _db
        .into(_db.playlists)
        .insert(
          PlaylistsCompanion.insert(
            name: name.trim(),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> rename(int id, String name) =>
      (_db.update(_db.playlists)..where((p) => p.id.equals(id))).write(
        PlaylistsCompanion(
          name: Value(name.trim()),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> delete(int id) =>
      (_db.delete(_db.playlists)..where((p) => p.id.equals(id))).go();

  Future<void> markOpened(int id) =>
      (_db.update(_db.playlists)..where((p) => p.id.equals(id))).write(
        PlaylistsCompanion(lastOpenedAt: Value(DateTime.now())),
      );

  Future<void> addTracks(int playlistId, List<int> trackIds) =>
      _db.transaction(() async {
        final e = _db.playlistEntries;
        final maxPos = e.position.max();
        final last =
            await (_db.selectOnly(e)
                  ..addColumns([maxPos])
                  ..where(e.playlistId.equals(playlistId)))
                .map((r) => r.read(maxPos))
                .getSingle();
        var pos = (last ?? -1) + 1;
        await _db.batch((b) {
          for (final trackId in trackIds) {
            b.insert(
              e,
              PlaylistEntriesCompanion.insert(
                playlistId: playlistId,
                trackId: trackId,
                position: pos++,
              ),
            );
          }
        });
        await _touch(playlistId);
      });

  Future<void> removeEntry(int playlistId, int entryId) =>
      _db.transaction(() async {
        await (_db.delete(
          _db.playlistEntries,
        )..where((e) => e.id.equals(entryId))).go();
        await _touch(playlistId);
      });

  /// Persists a new order given the full list of entry ids.
  Future<void> reorder(int playlistId, List<int> entryIds) =>
      _db.transaction(() async {
        await _db.batch((b) {
          for (var i = 0; i < entryIds.length; i++) {
            b.update(
              _db.playlistEntries,
              PlaylistEntriesCompanion(position: Value(i)),
              where: (e) => e.id.equals(entryIds[i]),
            );
          }
        });
        await _touch(playlistId);
      });

  Future<void> _touch(int id) =>
      (_db.update(_db.playlists)..where((p) => p.id.equals(id))).write(
        PlaylistsCompanion(updatedAt: Value(DateTime.now())),
      );
}
