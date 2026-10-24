import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/search/application/search_controller.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/test_database.dart';

class _CountingLibrary extends LibraryRepository {
  _CountingLibrary(super._db);

  final queries = <String>[];

  @override
  Future<List<Track>> searchTracks(String query, {int limit = 50}) {
    queries.add(query);
    return super.searchTracks(query, limit: limit);
  }
}

void main() {
  late AppDatabase db;
  late _CountingLibrary library;
  late ProviderContainer container;

  setUp(() async {
    db = inMemoryDatabase();
    library = _CountingLibrary(db);
    await library.upsertScanned([
      trackRow(
        '1.mp3',
        title: 'Signal',
        artist: 'Kei Aoto',
        album: 'Signal Path',
      ),
      trackRow('2.mp3', title: 'Silver', artist: 'Ilse North'),
    ]);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        libraryRepositoryProvider.overrideWithValue(library),
      ],
    )..listen(searchProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  LibrarySearchController ctrl() => container.read(searchProvider.notifier);

  test('typing quickly runs one query, for the last input', () async {
    ctrl()
      ..setQuery('s')
      ..setQuery('si')
      ..setQuery('sig');
    expect(container.read(searchProvider).searching, isTrue);
    expect(library.queries, isEmpty);

    await Future<void>.delayed(
      LibrarySearchController.debounce + const Duration(milliseconds: 150),
    );

    expect(library.queries, ['sig']);
    final results = container.read(searchProvider).results!;
    expect(results.tracks.map((t) => t.title), ['Signal']);
    expect(results.artists.map((a) => a.name), isEmpty);
    expect(results.albums.map((a) => a.title), ['Signal Path']);
  });

  test('clearing the field resets without querying', () async {
    ctrl()
      ..setQuery('si')
      ..setQuery('  ');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(library.queries, isEmpty);
    expect(container.read(searchProvider).results, isNull);
  });

  test('commit stores the query in local history', () async {
    ctrl().setQuery('silver');
    await ctrl().commit();
    final history = await db.select(db.searchHistory).get();
    expect(history.map((h) => h.query), ['silver']);
  });
}
