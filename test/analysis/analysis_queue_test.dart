import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/analysis/data/analysis_store.dart';
import 'package:noir/features/analysis/domain/track_analysis.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

import '../helpers/fake_engine.dart';
import '../helpers/test_database.dart';

TrackAnalysis fakeAnalysis({double bpm = 120}) => TrackAnalysis(
  analysisVersion: TrackAnalysis.currentVersion,
  duration: 180,
  loudnessLufs: -10,
  peakDb: -0.5,
  energyCurve: const [-12, -11],
  contentStart: 0.1,
  contentEnd: 179,
  bpm: bpm,
  tempoConfidence: 0.9,
  steadyTempo: true,
  beats: const [0.5, 1, 1.5],
  firstDownbeat: 0.5,
  beatsPerBar: 4,
  key: const MusicalKey(9, KeyMode.minor),
  keyConfidence: 0.7,
  tuningCents: 0,
  introEnd: 15.5,
  outroStart: 150,
  mixInPoints: const [0.5],
  mixOutPoints: const [150],
  sections: const [],
);

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late List<String> analysed;
  late Map<String, Completer<void>> gates;
  var failing = <String>{};

  Future<TrackAnalysis> runner(String path) async {
    analysed.add(p(path));
    await gates[p(path)]?.future;
    if (failing.contains(p(path))) throw const FormatException('bad file');
    return fakeAnalysis();
  }

  File audio(String name) =>
      File('${tmp.path}/$name')..writeAsStringSync('audio $name');

  ProviderContainer makeContainer({
    Duration librarySweepDelay = const Duration(hours: 1),
  }) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      playbackEngineProvider.overrideWithValue(FakeEngine()),
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      appDirectoriesProvider.overrideWithValue(
        AppDirectories(
          artwork: Directory('${tmp.path}/support/artwork'),
          importedMusic: Directory('${tmp.path}/music'),
        ),
      ),
      analysisRunnerProvider.overrideWithValue(runner),
      analysisQueueConfigProvider.overrideWithValue(
        AnalysisQueueConfig(
          librarySweepDelay: librarySweepDelay,
          gap: Duration.zero,
        ),
      ),
    ],
  )..listen(analysisQueueProvider, (_, _) {});

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('noir_analysis_');
    db = inMemoryDatabase();
    analysed = [];
    gates = {};
    failing = {};
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  AnalysisQueue queue() => container.read(analysisQueueProvider.notifier);

  /// Waits (in real time: the store does file I/O) for the queue to drain.
  Future<void> drained() async {
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final s = container.read(analysisQueueProvider);
      if (!s.isBusy && s.pending == 0) return;
    }
    fail('analysis queue did not drain');
  }

  test('analyzeFile stores the result under the track id', () async {
    final f = audio('yt.webm');
    final result = await queue().analyzeFile(f.path, trackId: 'youtube:abc');
    expect(result?.bpm, 120);
    expect(result?.source, isNotNull);

    final stored = await container.read(
      trackAnalysisProvider('youtube:abc').future,
    );
    expect(stored?.key?.camelot, '8A');
    expect(
      File('${tmp.path}/support/analysis/index.json').existsSync(),
      isTrue,
    );

    // Unchanged file: served from the store, not analysed again.
    await queue().analyzeFile(f.path, trackId: 'youtube:abc');
    expect(analysed, ['yt.webm']);
    expect(container.read(analysisQueueProvider).completed, 2);
  });

  test('a changed file is analysed again', () async {
    final f = audio('a.mp3');
    await queue().analyzeFile(f.path, trackId: 'local:1');
    f.writeAsStringSync('different, longer contents');
    await queue().analyzeFile(f.path, trackId: 'local:1');
    expect(analysed, ['a.mp3', 'a.mp3']);
  });

  test('failures complete with null and are counted', () async {
    final f = audio('broken.m4a');
    failing = {'broken.m4a'};
    expect(await queue().analyzeFile(f.path, trackId: 'local:9'), isNull);
    expect(await queue().analyzeFile('${tmp.path}/missing.mp3'), isNull);
    expect(container.read(analysisQueueProvider).failed, 2);
    expect(
      await container.read(trackAnalysisProvider('local:9').future),
      isNull,
    );
  });

  test('analyses the playing track and the next three first', () async {
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final n in ['A', 'B', 'C', 'D', 'E', 'F'])
        trackRow(audio('$n.mp3').path, title: n),
    ]);
    final tracks = await library.watchTracks().first;
    await container.read(playbackProvider.notifier).playTracks(tracks);
    await drained();
    expect(analysed, ['A.mp3', 'B.mp3', 'C.mp3', 'D.mp3']);
    final store = container.read(analysisStoreProvider);
    expect(await store.read(tracks.first.id), isNotNull);
  });

  test('sweeps the library, skipping analysed tracks', () async {
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final n in ['A', 'B', 'C']) trackRow(audio('$n.mp3').path, title: n),
    ]);
    final tracks = await library.watchTracks().first;
    final b = tracks.firstWhere((t) => t.title == 'B');
    await AnalysisStore(Directory('${tmp.path}/support/analysis'))
        .write(b.id, fakeAnalysis());

    container.dispose();
    container = makeContainer(librarySweepDelay: Duration.zero);
    for (var i = 0; i < 300 && analysed.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await drained();
    expect(analysed..sort(), ['A.mp3', 'C.mp3']);
  });

  test('pause holds the queue until resume', () async {
    final a = audio('a.flac');
    final b = audio('b.flac');
    gates['a.flac'] = Completer<void>();
    final first = queue().analyzeFile(a.path, trackId: 'local:1');
    await pumpEventQueue();
    queue().pause();
    final second = queue().analyzeFile(b.path, trackId: 'local:2');
    gates['a.flac']!.complete();
    await first;
    await pumpEventQueue();
    expect(analysed, ['a.flac']);
    expect(container.read(analysisQueueProvider).paused, isTrue);
    expect(container.read(analysisQueueProvider).pending, 1);

    queue().resume();
    await second;
    expect(analysed, ['a.flac', 'b.flac']);
  });

  test('cancel drops waiting jobs', () async {
    final a = audio('a.ogg');
    final b = audio('b.ogg');
    gates['a.ogg'] = Completer<void>();
    final first = queue().analyzeFile(a.path, trackId: 'local:1');
    await pumpEventQueue();
    final second = queue().analyzeFile(b.path, trackId: 'local:2');
    queue().cancel();
    gates['a.ogg']!.complete();
    expect(await second, isNull);
    expect(await first, isNull); // In flight: finished but discarded.
    expect(analysed, ['a.ogg']);
    expect(
      await AnalysisStore(Directory('${tmp.path}/support/analysis'))
          .read('local:1'),
      isNull,
    );
  });
}

String p(String path) => path.split(RegExp(r'[\\/]')).last;
