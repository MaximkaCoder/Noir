import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:path/path.dart' as p;

// Imported copies are named after whatever the serving app calls the file,
// so a name with directories in it must not choose where the copy lands.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('noir_import'));
  tearDown(() => dir.deleteSync(recursive: true));

  String name(String raw) => LibraryScanController.freeName(dir.path, raw);

  test('a plain name lands in the folder', () {
    expect(name('Song.mp3'), p.join(dir.path, 'Song.mp3'));
  });

  test('a taken name gets a number', () {
    File(p.join(dir.path, 'Song.mp3')).createSync();
    expect(name('Song.mp3'), p.join(dir.path, 'Song (2).mp3'));
  });

  test('directories in the name are dropped', () {
    for (final raw in [
      '../Song.mp3',
      '../../files/Song.mp3',
      '/data/user/0/app.noir.player/files/Song.mp3',
      // A backslash only separates directories on Windows.
      if (Platform.isWindows) r'C:\Users\x\Song.mp3',
      'sub/dir/Song.mp3',
    ]) {
      expect(name(raw), p.join(dir.path, 'Song.mp3'), reason: raw);
    }
  });

  test('a name with nothing left still lands in the folder', () {
    for (final raw in ['', '.', '..', '/']) {
      expect(p.isWithin(dir.path, name(raw)), isTrue, reason: raw);
    }
  });
}
