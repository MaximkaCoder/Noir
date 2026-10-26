import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/application/transition_status.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_analysis.dart';
import '../helpers/fake_engine.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late FakeEngine engine;
  late ProviderContainer container;
  late List<Track> tracks;
  final calls = <TransitionSide>[];

  /// Hands over at 100 s of A, into B at 30 s.
  TransitionPlan disco(
    TransitionSide a,
    TransitionSide b, {
    required double fadeSeconds,
    required double earliestStart,
  }) {
    calls.add(a);
    return const TransitionPlan(
      type: TransitionType.beatmatch,
      startInA: 100,
      endInA: 110,
      entryInB: 30,
      reason: 'test',
    );
  }

  setUp(() async {
    calls.clear();
    db = inMemoryDatabase();
    engine = FakeEngine()..durationValue = const Duration(minutes: 4);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        initialSettingsProvider.overrideWithValue(
          const AppSettings(transitionMode: TransitionMode.disco),
        ),
        transitionSideLoaderProvider.overrideWithValue(
          (t) async => TransitionSide(analysis: fake()),
        ),
        vocalTimingLoaderProvider.overrideWithValue((t) async => null),
        discoPlannerProvider.overrideWithValue(disco),
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final name in ['A', 'B', 'C']) trackRow('$name.mp3', title: name),
    ]);
    tracks = await library.watchTracks().first;
    container.listen(playbackProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> tick(double seconds) async {
    engine.tick(Duration(milliseconds: (seconds * 1000).round()));
    await pumpEventQueue();
  }

  test('plans as soon as both tracks are known, then hands over', () async {
    await container.read(playbackProvider.notifier).playTracks(tracks);
    await tick(5);
    await tick(6);
    expect(calls, hasLength(1));
    expect(calls.single.playedFrom, 0);
    expect(engine.mix, isNull);
    await tick(97);
    expect(engine.mixPlan?.startInA, 100);
  });

  test('the next track knows where the mix entered it', () async {
    await container.read(playbackProvider.notifier).playTracks(tracks);
    await tick(5);
    await tick(97);
    engine.mixStart!();
    engine.mix!.complete(true);
    await pumpEventQueue();
    expect(container.read(playbackProvider).current!.track.title, 'B');
    await tick(31);
    await tick(32);
    expect(calls.last.playedFrom, 30);
  });
}
