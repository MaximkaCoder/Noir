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
import 'package:noir/features/playback/domain/transition_planner.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/fake_analysis.dart';
import '../helpers/fake_audio_files.dart';
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

  Future<void> setUpWith([
    AppSettings settings = const AppSettings(),
    List<Override> overrides = const [],
  ]) async {
    db = inMemoryDatabase();
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        initialSettingsProvider.overrideWithValue(settings),
        ...overrides,
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final name in ['A', 'B', 'C', 'D'])
        trackRow('$name.mp3', title: name),
    ]);
    tracks = await library.watchTracks().first;
    container.listen(playbackProvider, (_, _) {});
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('queue', () {
    setUp(setUpWith);

    test('playTracks loads and plays the chosen item', () async {
      await controller().playTracks(tracks, startIndex: 1);
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');
      expect(state().status, PlaybackStatus.playing);
      expect(engine.calls, containsAllInOrder(['load B @0', 'play']));
    });

    test('playSingle behavior queues only the chosen track', () async {
      container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(playBehavior: PlayBehavior.playSingle));
      await controller().playTracks(tracks, startIndex: 2);
      expect(titles(), ['C']);
    });

    test('completion advances, then stops at the end', () async {
      await controller().playTracks(tracks, startIndex: 2);
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'D');

      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().status, PlaybackStatus.completed);
      expect(state().current!.track.title, 'D');
    });

    test('repeat all wraps around; repeat one replays', () async {
      await controller().playTracks(tracks, startIndex: 3);
      controller().cycleRepeat(); // all
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'A');

      controller().cycleRepeat(); // one
      engine.calls.clear();
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'A');
      expect(engine.calls, ['seek 0', 'play']);
    });

    test('previous restarts after 3 s, otherwise goes back', () async {
      await controller().playTracks(tracks, startIndex: 1);
      engine.positionValue = const Duration(seconds: 10);
      await controller().previous();
      expect(state().current!.track.title, 'B');
      expect(engine.calls.last, 'seek 0');

      engine.positionValue = const Duration(seconds: 1);
      await controller().previous();
      expect(state().current!.track.title, 'A');
    });

    test(
      'playNext inserts after current; remove and move keep current',
      () async {
        await controller().playTracks(tracks.take(2).toList());
        controller().playNext(tracks[3]);
        expect(titles(), ['A', 'D', 'B']);

        controller().move(2, 0); // B to the top
        expect(titles(), ['B', 'A', 'D']);
        expect(state().current!.track.title, 'A');

        controller().removeAt(0);
        expect(titles(), ['A', 'D']);
        expect(state().index, 0);

        controller().removeAt(0); // current: ignored
        expect(titles(), ['A', 'D']);
      },
    );

    test('clearUpcoming keeps only the current item', () async {
      await controller().playTracks(tracks, startIndex: 1);
      controller().clearUpcoming();
      expect(titles(), ['B']);
      expect(state().index, 0);
    });

    test('shuffle keeps current first and restores order when off', () async {
      await controller().playTracks(tracks);
      controller().toggleShuffle();
      expect(state().current!.track.title, 'A');
      expect(titles().toSet(), {'A', 'B', 'C', 'D'});

      controller().toggleShuffle();
      expect(titles(), ['A', 'B', 'C', 'D']);
      expect(state().index, 0);
    });

    test('load failure surfaces a message instead of playing', () async {
      engine.failing.add('B.mp3');
      await controller().playTracks(tracks, startIndex: 1);
      await pumpEventQueue();
      expect(state().status, PlaybackStatus.error);
      expect(state().message, isNotNull);
      expect(engine.calls, isNot(contains('play')));
    });

    test('favorite toggles locally and updates queue items', () async {
      await controller().playTracks(tracks);
      await controller().toggleFavorite(state().current!.track);
      expect(state().current!.track.isFavorite, isTrue);
      final favs = await LibraryRepository(db).watchFavorites().first;
      expect(favs.map((t) => t.title), ['A']);
    });
  });

  test('tells the audio file provider what plays next', () async {
    final files = FakeAudioFiles();
    await setUpWith(const AppSettings(), [
      audioFilesProvider.overrideWithValue(files),
    ]);
    await controller().playTracks(tracks);
    expect(files.prefetched.last, ['B', 'C']);

    await controller().next();
    expect(files.prefetched.last, ['C', 'D']);

    await controller().jumpTo(3);
    controller().addToQueue([tracks.first]);
    expect(files.prefetched.last, ['A']);
  });

  group('crossfade', () {
    setUp(
      () => setUpWith(
        const AppSettings(
          transitionMode: TransitionMode.crossfade,
          crossfadeSeconds: 5,
        ),
      ),
    );

    test('starts the next track inside the fade window', () async {
      await controller().playTracks(tracks);
      engine
        ..durationValue = const Duration(minutes: 3)
        ..tick(const Duration(minutes: 2, seconds: 50));
      await pumpEventQueue();
      expect(engine.calls, isNot(contains(startsWith('crossfade'))));

      engine.tick(const Duration(minutes: 2, seconds: 56));
      await pumpEventQueue();
      expect(engine.calls, contains('crossfade B 5s'));
      expect(state().current!.track.title, 'B');

      // A completion arriving mid-fade must not skip B.
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');

      engine.fade!.complete();
      await pumpEventQueue();
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'C');
    });

    test('does not fade when repeating one track', () async {
      await controller().playTracks(tracks);
      controller()
        ..cycleRepeat()
        ..cycleRepeat();
      engine
        ..durationValue = const Duration(minutes: 3)
        ..tick(const Duration(minutes: 2, seconds: 58));
      await pumpEventQueue();
      expect(engine.calls, isNot(contains(startsWith('crossfade'))));
    });
  });

  group('smart transitions', () {
    final analysisA = fake();
    final analysisB = fake(bpm: 126, key: 'C major');
    final aLength = Duration(microseconds: (analysisA.duration * 1e6).round());
    Duration at(double seconds) =>
        Duration(microseconds: (seconds * 1e6).round());

    setUp(
      () => setUpWith(const AppSettings(transitionMode: TransitionMode.smart), [
        transitionSideLoaderProvider.overrideWithValue(
          (track) async => TransitionSide(
            analysis: track.title == 'A' ? analysisA : analysisB,
          ),
        ),
      ]),
    );

    TransitionStatus? status() => container.read(transitionStatusProvider);

    Future<TransitionPlan> planned() async {
      await controller().playTracks(tracks);
      // Inputs are gathered ~90 s before the end, the plan made at 70 s.
      engine
        ..durationValue = aLength
        ..tick(aLength - const Duration(seconds: 85));
      await pumpEventQueue();
      expect(status(), isNull);
      engine.tick(aLength - const Duration(seconds: 69));
      await pumpEventQueue();
      expect(status()?.phase, TransitionPhase.planned);
      return status()!.plan;
    }

    test('plans a beatmatch and moves on when B is heard', () async {
      final plan = await planned();
      expect(plan.type, TransitionType.beatmatch);
      expect(engine.calls, isNot(contains(startsWith('mix'))));

      // Handed to the engine a few seconds before the start.
      engine.tick(at(plan.startInA - 3));
      await pumpEventQueue();
      expect(engine.calls, contains('mix B beatmatch'));
      expect(state().current!.track.title, 'A');

      // A completion while preparing must not skip anything.
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'A');

      engine.mixStart!();
      expect(state().current!.track.title, 'B');
      expect(status()?.phase, TransitionPhase.mixing);
      engine.mixProgress!(0.5);
      expect(status()?.progress, 0.5);

      engine.mix!.complete(true);
      await pumpEventQueue();
      expect(status(), isNull);
      expect(state().current!.track.title, 'B');
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'C');
    });

    test('an abandoned transition is planned again', () async {
      final plan = await planned();
      engine.tick(at(plan.startInA - 3));
      await pumpEventQueue();
      expect(engine.calls.where((c) => c.startsWith('mix')), hasLength(1));
      engine.mix!.complete(false); // E.g. the user paused.
      await pumpEventQueue();
      expect(state().current!.track.title, 'A');
      engine.tick(at(plan.startInA - 3.5));
      await pumpEventQueue();
      engine.tick(at(plan.startInA - 3));
      await pumpEventQueue();
      expect(engine.calls.where((c) => c.startsWith('mix')), hasLength(2));
    });

    test('skipping drops the planned transition', () async {
      await planned();
      await controller().next();
      expect(status(), isNull);
      expect(state().current!.track.title, 'B');
    });

    test('a next track on another engine is not mixed', () async {
      engine.mixable = false;
      await controller().playTracks(tracks);
      engine
        ..durationValue = aLength
        ..tick(aLength - const Duration(seconds: 80));
      await pumpEventQueue();
      engine.tick(aLength - const Duration(seconds: 5));
      await pumpEventQueue();
      expect(engine.calls, isNot(contains(startsWith('mix'))));
      expect(status(), isNull);
      engine.emit(const EngineCompleted());
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');
    });

    test('B removed while preparing still becomes current', () async {
      final plan = await planned();
      engine.tick(at(plan.startInA - 3));
      await pumpEventQueue();
      controller().removeAt(1);
      expect(titles(), ['A', 'C', 'D']);
      engine.mixStart!();
      expect(state().current!.track.title, 'B');
      expect(titles(), ['A', 'B', 'C', 'D']);
    });
  });

  test('session survives a restart', () async {
    await setUpWith();
    await controller().playTracks(tracks, startIndex: 2);
    engine.positionValue = const Duration(seconds: 42);
    await controller().pause();
    await pumpEventQueue();

    // New container over the same database = app restart.
    final engine2 = FakeEngine();
    final container2 = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine2),
      ],
    );
    addTearDown(container2.dispose);
    final ctrl2 = container2.read(playbackProvider.notifier);
    // The engine reports 0:00 on start-up, before the session is read; that
    // must not wipe the saved session.
    engine2.tick(Duration.zero);
    await pumpEventQueue();
    await ctrl2.restoreSession();

    final restored = container2.read(playbackProvider);
    expect(restored.current!.track.title, 'C');
    expect(restored.queue, hasLength(4));
    expect(engine2.calls, contains('load C @42'));
    expect(engine2.calls, isNot(contains('play')));
  });
}
