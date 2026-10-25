import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/shared/models/media.dart';

final historyRepositoryProvider = Provider<HistoryRepository>(
  (ref) => HistoryRepository(ref.watch(databaseProvider)),
);

/// Local listening history. Never leaves the device.
class HistoryRepository {
  HistoryRepository(this._db);

  final AppDatabase _db;

  Future<void> record(int trackId) => _db
      .into(_db.playHistory)
      .insert(
        PlayHistoryCompanion.insert(trackId: trackId, playedAt: DateTime.now()),
      );

  /// Distinct tracks, most recently played first.
  Stream<List<Track>> watchRecentTracks({int limit = 24}) => _recent(limit)
      .watch()
      .map((rows) => [for (final r in rows) _db.tracks.map(r.data).toTrack()]);

  Selectable<QueryRow> _recent(int limit) => _db.customSelect(
    'SELECT t.* FROM tracks t JOIN ( '
    'SELECT track_id, MAX(played_at) AS last FROM play_history '
    'GROUP BY track_id) h ON h.track_id = t.id '
    'ORDER BY h.last DESC LIMIT ?',
    variables: [Variable.withInt(limit)],
    readsFrom: {_db.tracks, _db.playHistory},
  );

  Future<void> clear() => _db.delete(_db.playHistory).go();
}
