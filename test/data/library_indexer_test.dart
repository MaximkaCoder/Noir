import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/features/library/data/library_indexer.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_database.dart';
import '../helpers/wav.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository repo;
  late LibraryIndexer indexer;
  late Directory root;
  late String music;

  setUp(() {
    db = inMemoryDatabase();
    repo = LibraryRepository(db);
    root = Directory.systemTemp.createTempSync('noir_indexer_');
    music = p.join(root.path, 'Music');
    indexer = LibraryIndexer(repo, Directory(p.join(root.path, 'artwork')));
  });

  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  test('indexes audio files recursively and ignores other files', () async {
    writeSineWav(File(p.join(music, 'Morning.wav')));
    writeSineWav(File(p.join(music, 'Album', 'Night.wav')));
    File(p.join(music, 'cover.jpg')).writeAsStringSync('not audio');

    final summary = await indexer.scanFolder(music);

    expect(summary.indexed, 2);
    final titles = (await repo.watchTracks().first).map((t) => t.title);
    expect(titles, ['Morning', 'Night']);
  });

  test('damaged files are kept with a filename title and counted', () async {
    File(p.join(music, 'Broken Song.mp3'))
      ..createSync(recursive: true)
      ..writeAsStringSync('garbage');

    final summary = await indexer.scanFolder(music);

    expect(summary.indexed, 1);
    expect(summary.unreadableTags, 1);
    expect((await repo.watchTracks().first).single.title, 'Broken Song');
  });

  test('rescan skips unchanged files and drops deleted ones', () async {
    final keep = File(p.join(music, 'Keep.wav'));
    final gone = File(p.join(music, 'Gone.wav'));
    writeSineWav(keep);
    writeSineWav(gone);
    await indexer.scanFolder(music);

    gone.deleteSync();
    final summary = await indexer.scanFolder(music);

    expect(summary.unchanged, 1);
    expect(summary.indexed, 0);
    expect(summary.removed, 1);
    expect((await repo.watchTracks().first).single.title, 'Keep');
  });

  test('a missing folder yields an empty scan instead of an error', () async {
    final summary = await indexer.scanFolder(p.join(root.path, 'nope'));
    expect(summary.indexed, 0);
  });

  test('fnv1a64 is stable', () {
    expect(fnv1a64('a'), 'af63dc4c8601ec8c');
  });
}
