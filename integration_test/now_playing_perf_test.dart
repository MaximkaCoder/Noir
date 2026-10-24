// Frame timings of the island → Now Playing morph on a real engine:
//
//   flutter test integration_test/now_playing_perf_test.dart -d windows \
//     --profile [--dart-define=NOIR_TRACE_DIR=<folder for timeline JSON>]
//     [--dart-define=NOIR_SHOT_DIR=<folder for screenshots>]
//
// Opens and closes Now Playing several times (lyrics off, then on) and
// prints worst / 90th percentile build and raster times per phase. Debug
// builds run too, but only profile numbers mean anything.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noir/app/app.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../test/helpers/fake_engine.dart';
import '../test/helpers/fake_http.dart';
import '../test/helpers/fake_innertube_client.dart';
import '../test/helpers/test_database.dart';

const _traceDir = String.fromEnvironment('NOIR_TRACE_DIR');
const _shotDir = String.fromEnvironment('NOIR_SHOT_DIR');

final GlobalKey<State<StatefulWidget>> _shotKey = GlobalKey();

/// A 1200 px cover with enough detail to cost a real decode.
Future<File> _cover(String path, ui.Color a, ui.Color b) async {
  const size = 1200.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(
      const ui.Rect.fromLTWH(0, 0, size, size),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          ui.Offset.zero,
          const ui.Offset(size, size),
          [a, b],
        ),
    );
  for (var i = 0; i < 60; i++) {
    canvas.drawCircle(
      ui.Offset((i * 197) % size, (i * 331) % size),
      20.0 + (i * 13) % 90,
      ui.Paint()..color = ui.Color((0x40FFFFFF + i * 0x010307) & 0x7FFFFFFF),
    );
  }
  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  await file.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  return file;
}

/// `mm:ss` for [seconds].
String _clock(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
    '${(seconds % 60).toString().padLeft(2, '0')}';

class _Phase {
  _Phase(this.name);

  final String name;
  final timings = <ui.FrameTiming>[];

  static int _ms(Duration d) => d.inMicroseconds;

  String summary() {
    if (timings.isEmpty) return '$name: no frames';
    final build = [for (final t in timings) _ms(t.buildDuration)]..sort();
    final raster = [for (final t in timings) _ms(t.rasterDuration)]..sort();
    String f(int us) => (us / 1000).toStringAsFixed(1);
    int p90(List<int> v) => v[((v.length - 1) * 0.9).round()];
    final over = raster.where((us) => us > 16000).length;
    return '${name.padRight(22)} frames ${timings.length.toString().padLeft(3)}'
        ' | build worst ${f(build.last).padLeft(6)} p90 '
        '${f(p90(build)).padLeft(5)} ms'
        ' | raster worst ${f(raster.last).padLeft(6)} p90 '
        '${f(p90(raster)).padLeft(5)} ms | raster>16ms: $over';
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Now Playing opens without long frames', (tester) async {
    // Only frames the app asks for, as in the real app.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(const Size(1360, 860));
    }
    final tmp = Directory.systemTemp.createTempSync('noir_perf_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final covers = [
      await _cover(
        p.join(tmp.path, 'a.png'),
        const ui.Color(0xFF8A2BE2),
        const ui.Color(0xFF1E90FF),
      ),
      await _cover(
        p.join(tmp.path, 'b.png'),
        const ui.Color(0xFFFF7F50),
        const ui.Color(0xFF2E8B57),
      ),
    ];

    final db = inMemoryDatabase();
    final engine = FakeEngine();
    addTearDown(db.close);
    final http = FakeHttp(
      (_) => ok({
        'id': 1,
        'trackName': 'Ash & Ember',
        'artistName': 'Mara Vale',
        'duration': 180,
        'instrumental': false,
        'plainLyrics': 'One\nTwo',
        'syncedLyrics': [
          for (var i = 0; i < 40; i++)
            '[${_clock(i * 4)}.00] Line number $i of the song',
        ].join('\n'),
      }),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
        httpClientProvider.overrideWithValue(http.dio()),
        innerTubeClientProvider.overrideWithValue(FakeInnerTubeClient()),
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            artwork: Directory(p.join(tmp.path, 'artwork')),
            importedMusic: Directory(p.join(tmp.path, 'imported')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await LibraryRepository(db).upsertScanned([
      trackRow(
        'a.mp3',
        title: 'Ash & Ember',
        artist: 'Mara Vale',
        artworkPath: covers[0].path,
      ),
      trackRow(
        'b.mp3',
        title: 'Quiet Harbor',
        artist: 'Mara Vale',
        artworkPath: covers[1].path,
      ),
    ]);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const NoirApp(),
        ),
      ),
    );
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    await wait(1500);

    final rows = await db.select(db.tracks).get();
    rows.sort((a, b) => a.path.compareTo(b.path));
    await container.read(playbackProvider.notifier).playTracks([
      for (final r in rows) r.toTrack(),
    ]);
    await wait(1500);

    final phases = <_Phase>[];
    _Phase? recording;
    void collect(List<ui.FrameTiming> timings) =>
        recording?.timings.addAll(timings);
    SchedulerBinding.instance.addTimingsCallback(collect);
    addTearDown(() => SchedulerBinding.instance.removeTimingsCallback(collect));

    final router = container.read(routerProvider);
    final openButton = find.byTooltip('Open player (Ctrl+P)');

    Future<void> traced(String? key, Future<void> Function() action) async {
      if (_traceDir.isEmpty || key == null) {
        await action();
        return;
      }
      await binding.traceAction(action, reportKey: key);
      final file = File(p.join(_traceDir, '$key.json'));
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode(binding.reportData![key]));
    }

    /// Opens and closes Now Playing; [trace] names a timeline of the open.
    Future<void> cycle(String label, {String? trace}) async {
      final open = _Phase('open $label');
      phases.add(open);
      await traced(trace, () async {
        recording = open;
        expect(openButton, findsOneWidget);
        await tester.tap(openButton);
        await wait(900);
        // Timings arrive in batches; the last ones land meanwhile.
        recording = null;
      });
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      await wait(600);

      final close = _Phase('close $label');
      phases.add(close);
      recording = close;
      router.pop();
      await wait(800);
      recording = null;
      await wait(600);
    }

    await cycle('#1', trace: 'first_open');
    for (var i = 2; i <= 4; i++) {
      await cycle('#$i', trace: 'reopen_$i');
    }

    container.read(lyricsVisibleProvider.notifier).set(visible: true);
    for (var i = 1; i <= 3; i++) {
      await cycle('lyrics #$i', trace: 'lyrics_open_$i');
    }

    if (_shotDir.isNotEmpty) {
      Future<void> shot(String name) async {
        await wait(900);
        final boundary =
            _shotKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(p.join(_shotDir, '$name.png'));
        await file.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      }

      await tester.tap(openButton);
      // Part way through the third line.
      engine.tick(const Duration(milliseconds: 9600));
      await shot('now_playing_lyrics');
      container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(lyricsMode: LyricsMode.karaoke));
      await shot('now_playing_karaoke');
      container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(lyricsMode: LyricsMode.lines));
      container.read(lyricsVisibleProvider.notifier).set(visible: false);
      await shot('now_playing');
      router.pop();
      await wait(800);
      container.read(lyricsVisibleProvider.notifier).set(visible: true);
    }

    // The summarizer the integration_test report uses, over every phase.
    await binding.watchPerformance(
      () => cycle('watched'),
      reportKey: 'now_playing_performance',
    );

    const mode = kProfileMode
        ? 'profile'
        : kReleaseMode
        ? 'release'
        : 'debug';
    final perf = {
      for (final MapEntry(:key, :value)
          in (binding.reportData!['now_playing_performance'] as Map).entries)
        if (value is! List) key: value,
    };
    final report = [
      'Now Playing morph frame timings ($mode)',
      for (final phase in phases) phase.summary(),
      'watchPerformance: ${jsonEncode(perf)}',
    ].join('\n');
    binding.reportData!['summary'] = report;
    // The numbers are the point of this test.
    // ignore: avoid_print
    print(report);
  });
}
