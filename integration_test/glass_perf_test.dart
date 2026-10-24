// Frame times of the glass surfaces on a real desktop engine: scrolling
// Home (Discover shelves under the top bar, island and sidebar), opening
// and closing a track menu, and scrolling Settings (many small glass
// controls). Profile mode gives meaningful numbers:
//
//   flutter drive -d windows --profile \
//     --driver=<file calling integrationDriver()> \
//     --target=integration_test/glass_perf_test.dart
//
// `flutter test integration_test/glass_perf_test.dart -d windows` runs it in
// debug mode (slower builds; raster times still compare).
//
// Each phase prints `PERF <phase>: …` and lands in the binding's reportData.
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noir/app/app.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/home/presentation/home_screen.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/settings/presentation/settings_screen.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:window_manager/window_manager.dart';

import '../test/helpers/fake_engine.dart';
import '../test/helpers/fake_innertube_client.dart';
import '../test/helpers/test_database.dart';

/// Frame timings reported while [action] runs (plus a short tail, since the
/// engine reports them in batches).
Future<Map<String, Object>> _measure(
  String phase,
  Future<void> Function() action,
) async {
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> t) => timings.addAll(t);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await action();
  await Future<void>.delayed(const Duration(milliseconds: 600));
  SchedulerBinding.instance.removeTimingsCallback(collect);

  double ms(Duration d) => d.inMicroseconds / 1000;
  double pct(List<double> xs, double p) {
    if (xs.isEmpty) return 0;
    final s = [...xs]..sort();
    return s[((s.length - 1) * p).round()];
  }

  double avg(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  final build = [for (final t in timings) ms(t.buildDuration)];
  final raster = [for (final t in timings) ms(t.rasterDuration)];
  final total = [for (final t in timings) ms(t.totalSpan)];
  final result = <String, Object>{
    'frames': timings.length,
    'build_avg': avg(build),
    'build_p90': pct(build, 0.9),
    'raster_avg': avg(raster),
    'raster_p90': pct(raster, 0.9),
    'raster_max': pct(raster, 1),
    'raster_over_16ms': raster.where((t) => t > 16.7).length,
    'frames_over_16ms': total.where((t) => t > 16.7).length,
  };
  String f(Object v) => v is double ? v.toStringAsFixed(2) : '$v';
  final line = result.entries.map((e) => '${e.key}=${f(e.value)}').join(' ');
  // The numbers are the point of this test: show them in the run's log.
  // ignore: avoid_print
  print('PERF $phase: $line');
  return result;
}

FakeInnerTubeClient _feed() => FakeInnerTubeClient()
  ..homePage = YtmHomePage(
    chips: [
      for (final mood in ['Relax', 'Focus', 'Workout', 'Energize', 'Sleep'])
        YtmChip(title: mood, params: 'P_$mood'),
    ],
    shelves: [
      for (var s = 0; s < 8; s++)
        YtmShelf(
          title: 'Shelf $s',
          items: [
            for (var i = 0; i < 14; i++)
              YtmTrackItem(ytTrack('v${s}_$i', title: 'Song $s.$i')),
          ],
        ),
    ],
  );

ScrollPosition _scrollOf(WidgetTester tester, Finder page) => tester
    .state<ScrollableState>(
      find.descendant(of: page, matching: find.byType(Scrollable)).first,
    )
    .position;

Future<void> _sweep(ScrollPosition p, {int times = 3}) async {
  for (var i = 0; i < times; i++) {
    await p.animateTo(
      p.maxScrollExtent,
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
    );
    await p.animateTo(
      0,
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
    );
  }
}

Future<void> _wait(WidgetTester tester, [int ms = 500]) async {
  await tester.pump();
  await Future<void>.delayed(Duration(milliseconds: ms));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('glass frame times', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(const Size(1360, 860));
    }
    final tmp = Directory.systemTemp.createTempSync('noir_perf_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final db = inMemoryDatabase();
    addTearDown(db.close);
    await LibraryRepository(db).upsertScanned([
      for (var i = 0; i < 40; i++)
        trackRow(
          't$i.mp3',
          title: 'Track $i',
          artist: 'Artist ${i % 5}',
          album: 'Album ${i % 8}',
          trackNumber: i % 10 + 1,
        ),
    ]);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(FakeEngine()),
        innerTubeClientProvider.overrideWithValue(_feed()),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
        artworkResolverProvider.overrideWithValue(ArtworkResolver.offline()),
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            artwork: Directory('${tmp.path}/artwork'),
            importedMusic: Directory('${tmp.path}/imported'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const NoirApp()),
    );
    await _wait(tester, 1500);

    // The island floats over Home while something plays.
    final rows = await db.select(db.tracks).get();
    await container.read(playbackProvider.notifier).playTracks([
      for (final r in rows) r.toTrack(),
    ]);
    await _wait(tester, 1000);

    final results = <String, Object>{};
    results['home_scroll'] = await _measure(
      'home_scroll',
      () => _sweep(_scrollOf(tester, find.byType(HomeScreen))),
    );

    final router = container.read(routerProvider)..go('/library?tab=tracks');
    await _wait(tester, 1000);
    results['menu'] = await _measure('menu', () async {
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip('More').at(i));
        await _wait(tester, 450);
        // (Key events cannot be simulated in profile mode on Windows.)
        await Navigator.of(
          tester.element(find.text('Add to queue')),
          rootNavigator: true,
        ).maybePop();
        await _wait(tester, 350);
      }
    });

    router.go('/settings');
    await _wait(tester, 1000);
    results['settings_scroll'] = await _measure(
      'settings_scroll',
      () => _sweep(_scrollOf(tester, find.byType(SettingsScreen)), times: 2),
    );

    // Reference: the same Home scroll with Liquid Glass off.
    router.go('/');
    container
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(liquidGlass: false));
    await _wait(tester, 1000);
    results['home_scroll_glass_off'] = await _measure(
      'home_scroll_glass_off',
      () => _sweep(_scrollOf(tester, find.byType(HomeScreen))),
    );

    router.go('/settings');
    await _wait(tester, 1000);
    results['settings_scroll_glass_off'] = await _measure(
      'settings_scroll_glass_off',
      () => _sweep(_scrollOf(tester, find.byType(SettingsScreen)), times: 2),
    );

    binding.reportData = results;
    router.go('/');
    await _wait(tester);
    await container.read(playbackProvider.notifier).pause();
  });
}
