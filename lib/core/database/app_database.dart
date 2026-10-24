import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:noir/core/database/tables.dart';
import 'package:path_provider/path_provider.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Tracks,
    LibraryFolders,
    Playlists,
    PlaylistEntries,
    PlayHistory,
    SearchHistory,
    KeyValues,
    YtPlaylists,
    YtVideos,
    YtPlaylistItems,
    YtLikes,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens the on-disk database in the app support directory (not the user's
  /// Documents folder, which is drift_flutter's default).
  factory AppDatabase.open() => AppDatabase(
    driftDatabase(
      name: 'noir',
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
    ),
  );

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(
        'CREATE INDEX idx_history_played_at ON play_history (played_at)',
      );
      await customStatement(
        'CREATE INDEX idx_entries_playlist '
        'ON playlist_entries (playlist_id, position)',
      );
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(ytPlaylists);
        await m.createTable(ytVideos);
        await m.createTable(ytPlaylistItems);
        await m.createTable(ytLikes);
      } else {
        if (from < 3) {
          // v2 → v3: video category for the "Liked music" filter. Existing
          // rows stay null until the next sync fills them in.
          await m.addColumn(ytVideos, ytVideos.categoryId);
        }
        if (from < 4) {
          // v3 → v4: playlist item ids, to remove saved songs on YouTube.
          await m.addColumn(ytPlaylistItems, ytPlaylistItems.itemId);
        }
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
