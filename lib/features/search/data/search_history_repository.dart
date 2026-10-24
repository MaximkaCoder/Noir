import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';

final searchHistoryRepositoryProvider = Provider<SearchHistoryRepository>(
  (ref) => SearchHistoryRepository(ref.watch(databaseProvider)),
);

class SearchHistoryRepository {
  SearchHistoryRepository(this._db);

  final AppDatabase _db;

  static const _keep = 20;

  Stream<List<String>> watch() =>
      (_db.select(_db.searchHistory)
            ..orderBy([(s) => OrderingTerm.desc(s.searchedAt)])
            ..limit(_keep))
          .map((s) => s.query)
          .watch();

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await _db
        .into(_db.searchHistory)
        .insertOnConflictUpdate(
          SearchHistoryCompanion.insert(query: q, searchedAt: DateTime.now()),
        );
    // Keep the table bounded.
    await _db.customStatement(
      'DELETE FROM search_history WHERE query NOT IN '
      '(SELECT query FROM search_history ORDER BY searched_at DESC LIMIT ?)',
      [_keep],
    );
  }

  Future<void> remove(String query) =>
      (_db.delete(_db.searchHistory)..where((s) => s.query.equals(query))).go();

  Future<void> clear() => _db.delete(_db.searchHistory).go();
}
