import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/features/search/data/search_history_repository.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() {
    db = inMemoryDatabase();
    library = LibraryRepository(db);
  });
  tearDown(() => db.close());

  group('LibraryRepository', () {
    test('rescan refreshes metadata but keeps favorite flag', () async {
      await library.upsertScanned([trackRow(r'D:\Music\a.mp3', title: 'Old')]);
      final id = (await library.watchTracks().first).single.localId!;
      await library.setFavorite(id, favorite: true);

      await library.upsertScanned([trackRow(r'D:\Music\a.mp3', title: 'New')]);

      final track = (await library.watchTracks().first).single;
      expect(track.title, 'New');
      expect(track.isFavorite, isTrue);
    });

    test('removing a folder does not touch sibling folders', () async {
      await library.addFolder(r'D:\Music');
      await library.upsertScanned([
        trackRow(r'D:\Music\a.mp3'),
        trackRow(r'D:\Music2\b.mp3'),
      ]);

      await library.removeFolder(r'D:\Music');

      final paths = (await library.watchTracks().first).map((t) => t.uri);
      expect(paths, [r'D:\Music2\b.mp3']);
      expect(await library.folders(), isEmpty);
    });

    test('albums group by album artist and count tracks', () async {
      await library.upsertScanned([
        trackRow('1.mp3', artist: 'Frank Ocean', album: 'Blonde'),
        trackRow('2.mp3', artist: 'Frank Ocean', album: 'Blonde'),
        trackRow('3.mp3', artist: 'Kendrick Lamar', album: 'GKMC'),
        trackRow('4.mp3', artist: 'Loose single'),
      ]);

      final albums = await library.watchAlbums().first;
      expect(albums.map((a) => (a.title, a.artist, a.trackCount)), [
        ('Blonde', 'Frank Ocean', 2),
        ('GKMC', 'Kendrick Lamar', 1),
      ]);
      expect(await library.albumTracks(albums.first), hasLength(2));
    });

    test('search treats LIKE wildcards literally', () async {
      await library.upsertScanned([
        trackRow('1.mp3', title: '100% Pure'),
        trackRow('2.mp3', title: '1000 Pure'),
      ]);

      final results = await library.searchTracks('100%');
      expect(results.map((t) => t.title), ['100% Pure']);
    });
  });

  group('PlaylistRepository', () {
    test('add, reorder and remove entries; summary reflects them', () async {
      final playlists = PlaylistRepository(db);
      await library.upsertScanned([
        trackRow('1.mp3', title: 'One', artworkPath: 'a.jpg'),
        trackRow('2.mp3', title: 'Two', artworkPath: 'b.jpg'),
        trackRow('3.mp3', title: 'Three'),
      ]);
      final ids = [
        for (final t in await library.watchTracks().first) t.localId!,
      ];
      final id = await playlists.create('  Focus  ');
      await playlists.addTracks(id, ids);

      var entries = await playlists.watchTracks(id).first;
      await playlists.reorder(
        id,
        entries.reversed.map((e) => e.entryId).toList(),
      );
      entries = await playlists.watchTracks(id).first;
      expect(entries.map((e) => e.track.title), ['Two', 'Three', 'One']);

      await playlists.removeEntry(id, entries.first.entryId);
      final summary = (await playlists.watchPlaylists().first).single;
      expect(summary.name, 'Focus');
      expect(summary.trackCount, 2);
      expect(summary.totalDuration, const Duration(minutes: 6));
      expect(summary.artworkPaths, ['a.jpg']);
    });

    test('deleting a track removes it from playlists (cascade)', () async {
      final playlists = PlaylistRepository(db);
      await library.upsertScanned([trackRow('1.mp3')]);
      final trackId = (await library.watchTracks().first).single.localId!;
      final id = await playlists.create('P');
      await playlists.addTracks(id, [trackId]);

      await library.removePaths(['1.mp3']);

      expect(await playlists.watchTracks(id).first, isEmpty);
    });
  });

  test('history returns distinct tracks, most recent first', () async {
    final history = HistoryRepository(db);
    await library.upsertScanned([
      trackRow('1.mp3', title: 'A'),
      trackRow('2.mp3', title: 'B'),
    ]);
    final tracks = await library.watchTracks().first;
    await history.record(tracks[0].localId!);
    await history.record(tracks[1].localId!);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await history.record(tracks[0].localId!);

    final recent = await history.watchRecentTracks().first;
    expect(recent.map((t) => t.title), ['A', 'B']);
  });

  test('search history keeps unique queries, newest first', () async {
    final repo = SearchHistoryRepository(db);
    await repo.add('frank');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await repo.add('ocean');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await repo.add('frank ');

    expect(await repo.watch().first, ['frank', 'ocean']);
    await repo.clear();
    expect(await repo.watch().first, isEmpty);
  });

  group('SettingsRepository', () {
    test('round-trips settings', () async {
      final repo = SettingsRepository(db);
      const settings = AppSettings(
        liquidGlass: false,
        performanceMode: PerformanceMode.performance,
        transitionMode: TransitionMode.smart,
        crossfadeSeconds: 8,
      );
      await repo.saveSettings(settings);
      expect(await repo.loadSettings(), settings);
    });

    test('migrates the old crossfade setting to a transition mode', () async {
      Future<AppSettings> load(String json) async {
        await db
            .into(db.keyValues)
            .insertOnConflictUpdate(
              KeyValuesCompanion.insert(key: 'app_settings', value: json),
            );
        return await SettingsRepository(db).loadSettings();
      }

      final fading = await load('{"crossfadeSeconds":4}');
      expect(fading.transitionMode, TransitionMode.crossfade);
      expect(fading.crossfadeSeconds, 4);
      final off = await load('{"crossfadeSeconds":0}');
      expect(off.transitionMode, TransitionMode.off);
      expect(off.crossfadeSeconds, 6);
      final current = await load(
        '{"transitionMode":"smart","crossfadeSeconds":3}',
      );
      expect(current.transitionMode, TransitionMode.smart);
      expect(current.crossfadeSeconds, 3);
    });

    test('falls back to defaults on corrupted data', () async {
      await db
          .into(db.keyValues)
          .insertOnConflictUpdate(
            KeyValuesCompanion.insert(key: 'app_settings', value: '{oops'),
          );
      expect(await SettingsRepository(db).loadSettings(), const AppSettings());
    });

    test('ignores unknown enum values from a newer version', () async {
      await db
          .into(db.keyValues)
          .insertOnConflictUpdate(
            const KeyValuesCompanion(
              key: Value('app_settings'),
              value: Value('{"themeMode":"neon"}'),
            ),
          );
      expect(await SettingsRepository(db).loadSettings(), const AppSettings());
    });
  });
}
