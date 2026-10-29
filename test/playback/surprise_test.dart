import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/application/transition_status.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/fake_analysis.dart';
import '../helpers/fake_engine.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late FakeEngine engine;
  late ProviderContainer container;
  late List<Track> tracks;

  PlaybackController controller() => container.read(playbackProvider.notifier);
  PlaybackState state() => container.read(playbackProvider);
  List<String> titles() => [for (final q in state().queue) q.track.title];

  // Every pair is a different distance apart, so the closest track is never
  // a tie that the shuffled order would decide.
  const bpms = {'A': 100.0, 'B': 151.0, 'C': 103.0, 'D': 147.0, 'E': 108.0};

  Future<void> setUpWith([List<Override> overrides = const []]) async {
    db = inMemoryDatabase();
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        ...overrides,
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final name in bpms.keys) trackRow('$name.mp3', title: name),
    ]);
    tracks = await library.watchTracks().first;
    container.listen(playbackProvider, (_, _) {});
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> complete() async {
    engine.emit(const EngineCompleted());
    await pumpEventQueue();
  }

  /// Waits for the next pick (it loads analyses, which may take a while
  /// under load).
  Future<void> picked() async {
    for (var i = 0; i < 50 && state().queue.length <= state().index! + 1; i++) {
      await pumpEventQueue();
    }
  }

  test('without a picker: one track ahead at a time, each once', () async {
    await setUpWith();
    await controller().surprise(tracks);
    await pumpEventQueue();
    expect(state().queue, hasLength(2));
    expect(state().index, 0);
    for (var i = 0; i < 4; i++) {
      await complete();
    }
    expect(titles().toSet(), bpms.keys.toSet());
    expect(titles(), hasLength(5));
    await complete();
    expect(state().status, PlaybackStatus.completed);
  });

  test('each next track is the one the picker likes best', () async {
    await setUpWith([
      transitionSideLoaderProvider.overrideWithValue(
        (t) async => TransitionSide(analysis: fake(bpm: bpms[t.title]!)),
      ),
      // Closest tempo wins.
      nextTrackPickerProvider.overrideWithValue((current, candidates) {
        double gap(TransitionSide s) =>
            (s.analysis!.bpm - current.analysis!.bpm).abs();
        var best = 0;
        for (var i = 1; i < candidates.length; i++) {
          if (gap(candidates[i]) < gap(candidates[best])) best = i;
        }
        return best;
      }),
    ]);
    await controller().surprise(tracks);
    await pumpEventQueue();
    for (var i = 0; i < 4; i++) {
      await picked();
      final played = titles().sublist(0, state().index! + 1);
      final next = titles().last;
      final now = bpms[titles()[state().index!]]!;
      final rest = bpms.keys.where((t) => !played.contains(t));
      final closest = rest.reduce(
        (x, y) => (bpms[x]! - now).abs() <= (bpms[y]! - now).abs() ? x : y,
      );
      expect(next, closest, reason: titles().toString());
      await complete();
    }
  });

  test('playing something else ends the session', () async {
    await setUpWith();
    await controller().surprise(tracks);
    await pumpEventQueue();
    await controller().playTracks(tracks.sublist(0, 1));
    await pumpEventQueue();
    expect(titles(), ['A']);
    await complete();
    expect(titles(), ['A']);
  });
}
