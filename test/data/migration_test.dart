import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';

import '../generated_migrations/schema.dart';

/// Guards the on-disk schema. When bumping `schemaVersion`:
///   dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
///   dart run drift_dev schema generate drift_schemas/ test/generated_migrations/
/// then add an upgrade case from the previous version.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('fresh install matches the v3 snapshot', () async {
    final db = AppDatabase(await verifier.startAt(3));
    await verifier.migrateAndValidate(db, 3);
    await db.close();
  });

  test(
    'upgrade v1 → v3 adds the YouTube cache and keeps library data',
    () async {
      final schema = await verifier.schemaAt(1);
      schema.rawDatabase.execute(
        'INSERT INTO tracks (path, title, file_size, modified_at, added_at) '
        "VALUES ('a.mp3', 'Kept', 1, 0, 0)",
      );
      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 3);
      final tracks = await db.select(db.tracks).get();
      expect(tracks.single.title, 'Kept');
      expect(await db.select(db.ytPlaylists).get(), isEmpty);
      await db.close();
    },
  );

  test(
    'upgrade v2 → v3 keeps cached videos with no category (backfilled later)',
    () async {
      final schema = await verifier.schemaAt(2);
      schema.rawDatabase.execute(
        'INSERT INTO yt_videos (id, title, channel_title, synced_at) '
        "VALUES ('v1', 'Song', 'Mara Vale - Topic', 0)",
      );
      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 3);
      final video = await db.select(db.ytVideos).getSingle();
      expect(video.title, 'Song');
      expect(video.categoryId, isNull);
      await db.close();
    },
  );
}
