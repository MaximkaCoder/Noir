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
  int get schemaVersion => 1;

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
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
