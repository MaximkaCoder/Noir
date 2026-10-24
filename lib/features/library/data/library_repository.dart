import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/shared/models/media.dart';
import 'package:path/path.dart' as p;

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(databaseProvider)),
);

enum TrackSort { title, artist, album, recentlyAdded }

const unknownArtist = 'Unknown artist';

extension TrackRecordX on TrackRecord {
  Track toTrack() => Track(
    id: 'local:$id',
    source: MediaSource.local,
    title: title,
    uri: path,
    artist: artist,
    album: album,
    trackNumber: trackNumber,
    year: year,
    duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
    artworkPath: artworkPath,
    isFavorite: isFavorite,
  );
}

/// Local library metadata. Everything here comes from files the user chose.
class LibraryRepository {
  LibraryRepository(this._db);

  final AppDatabase _db;

  $TracksTable get _t => _db.tracks;

  Stream<List<Track>> watchTracks({TrackSort sort = TrackSort.title}) {
    final query = _db.select(_t)
      ..orderBy([
        switch (sort) {
          TrackSort.title => (t) => OrderingTerm.asc(
            t.title.collate(Collate.noCase),
          ),
          TrackSort.artist => (t) => OrderingTerm.asc(
            t.artist.collate(Collate.noCase),
          ),
          TrackSort.album => (t) => OrderingTerm.asc(
            t.album.collate(Collate.noCase),
          ),
          TrackSort.recentlyAdded => (t) => OrderingTerm.desc(t.addedAt),
        },
        (t) => OrderingTerm.asc(t.trackNumber),
      ]);
    return query.watch().map(_toTracks);
  }

  Stream<List<Track>> watchFavorites() {
    final query = _db.select(_t)
      ..where((t) => t.isFavorite)
      ..orderBy([(t) => OrderingTerm.asc(t.title.collate(Collate.noCase))]);
    return query.watch().map(_toTracks);
  }

  Stream<int> watchTrackCount() {
    final count = _t.id.count();
    return (_db.selectOnly(
      _t,
    )..addColumns([count])).map((r) => r.read(count) ?? 0).watchSingle();
  }

  Stream<List<Album>> watchAlbums() => _db
      .customSelect(
        'SELECT album, $_albumArtistSql AS artist, COUNT(*) AS n, '
        'MAX(year) AS year, MAX(artwork_path) AS art '
        'FROM tracks WHERE album IS NOT NULL '
        'GROUP BY album, $_albumArtistSql '
        'ORDER BY album COLLATE NOCASE',
        readsFrom: {_t},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            Album(
              title: r.read<String>('album'),
              artist: r.read<String>('artist'),
              trackCount: r.read<int>('n'),
              year: r.readNullable<int>('year'),
              artworkPath: r.readNullable<String>('art'),
            ),
        ],
      );

  Stream<List<Artist>> watchArtists() => _db
      .customSelect(
        "SELECT COALESCE(artist, '$unknownArtist') AS name, COUNT(*) AS n, "
        'COUNT(DISTINCT album) AS albums, MAX(artwork_path) AS art '
        'FROM tracks GROUP BY name ORDER BY name COLLATE NOCASE',
        readsFrom: {_t},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            Artist(
              name: r.read<String>('name'),
              trackCount: r.read<int>('n'),
              albumCount: r.read<int>('albums'),
              artworkPath: r.readNullable<String>('art'),
            ),
        ],
      );

  Future<List<Track>> albumTracks(Album album) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM tracks WHERE album = ? AND $_albumArtistSql = ? '
          'ORDER BY disc_number, track_number, title COLLATE NOCASE',
          variables: [
            Variable.withString(album.title),
            Variable.withString(album.artist),
          ],
          readsFrom: {_t},
        )
        .get();
    return [for (final r in rows) _t.map(r.data).toTrack()];
  }

  Future<List<Track>> artistTracks(String artist) async {
    final query = _db.select(_t)
      ..where(
        (t) => artist == unknownArtist
            ? t.artist.isNull()
            : t.artist.equals(artist),
      )
      ..orderBy([
        (t) => OrderingTerm.asc(t.album.collate(Collate.noCase)),
        (t) => OrderingTerm.asc(t.trackNumber),
      ]);
    return _toTracks(await query.get());
  }

  Future<List<Track>> tracksByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await (_db.select(_t)..where((t) => t.id.isIn(ids))).get();
    final byId = {for (final r in rows) r.id: r.toTrack()};
    return [for (final id in ids) ?byId[id]];
  }

  /// Case-insensitive substring search over title, artist and album.
  Future<List<Track>> searchTracks(String query, {int limit = 50}) {
    final pattern = '%${escapeLike(query)}%';
    final q = _db.select(_t)
      ..where(
        (t) =>
            t.title.like(pattern, escapeChar: r'\') |
            t.artist.like(pattern, escapeChar: r'\') |
            t.album.like(pattern, escapeChar: r'\'),
      )
      ..orderBy([(t) => OrderingTerm.asc(t.title.collate(Collate.noCase))])
      ..limit(limit);
    return q.get().then(_toTracks);
  }

  Future<void> setFavorite(int trackId, {required bool favorite}) =>
      (_db.update(_t)..where((t) => t.id.equals(trackId))).write(
        TracksCompanion(isFavorite: Value(favorite)),
      );

  /// Inserts new files and refreshes metadata of known ones, keeping
  /// user state (favorite flag, added date).
  Future<void> upsertScanned(List<TracksCompanion> rows) => _db.batch((b) {
    for (final row in rows) {
      b.insert(
        _t,
        row,
        onConflict: DoUpdate(
          (_) => row.copyWith(
            isFavorite: const Value.absent(),
            addedAt: const Value.absent(),
          ),
          target: [_t.path],
        ),
      );
    }
  });

  Future<Map<String, DateTime>> knownFilesUnder(String folder) async {
    final rows =
        await (_db.select(_t)..where(
              (t) => t.path.like(
                '${escapeLike(_dirPrefix(folder))}%',
                escapeChar: r'\',
              ),
            ))
            .get();
    return {for (final r in rows) r.path: r.modifiedAt};
  }

  Future<void> removePaths(Iterable<String> paths) async {
    final list = paths.toList();
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      await (_db.delete(_t)..where((t) => t.path.isIn(chunk))).go();
    }
  }

  /// Forgets extracted artwork and marks every file as changed, so the next
  /// rescan extracts artwork again.
  Future<void> resetArtwork() => _db.customStatement(
    'UPDATE tracks SET artwork_path = NULL, modified_at = 0',
  );

  Stream<List<LibraryFolder>> watchFolders() => (_db.select(
    _db.libraryFolders,
  )..orderBy([(f) => OrderingTerm.asc(f.path)])).watch();

  Future<List<LibraryFolder>> folders() => _db.select(_db.libraryFolders).get();

  Future<void> addFolder(String path) => _db
      .into(_db.libraryFolders)
      .insert(
        LibraryFoldersCompanion.insert(path: path, addedAt: DateTime.now()),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> markScanned(String path) =>
      (_db.update(_db.libraryFolders)..where((f) => f.path.equals(path))).write(
        LibraryFoldersCompanion(lastScannedAt: Value(DateTime.now())),
      );

  /// Forgets the folder and every track indexed from it. Files are untouched.
  Future<void> removeFolder(String path) => _db.transaction(() async {
    await (_db.delete(
      _db.libraryFolders,
    )..where((f) => f.path.equals(path))).go();
    await (_db.delete(_t)..where(
          (t) =>
              t.path.like('${escapeLike(_dirPrefix(path))}%', escapeChar: r'\'),
        ))
        .go();
  });

  static const _albumArtistSql =
      "COALESCE(album_artist, artist, '$unknownArtist')";

  static List<Track> _toTracks(List<TrackRecord> rows) => [
    for (final r in rows) r.toTrack(),
  ];
}

/// `D:\Music` -> `D:\Music\` so `D:\Music2` is not matched as a child.
String _dirPrefix(String dir) =>
    dir.endsWith(p.separator) ? dir : '$dir${p.separator}';

/// Escapes LIKE wildcards so user input is matched literally.
String escapeLike(String input) =>
    input.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
