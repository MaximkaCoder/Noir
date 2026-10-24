import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/media_commands.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/windows_media_controls.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/fake_engine.dart';
import '../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late FakeEngine engine;
  late ProviderContainer container;
  late List<Track> tracks;
  late DateTime now;
  late List<MethodCall> calls;
  late WindowsMediaControls controls;

  PlaybackController controller() => container.read(playbackProvider.notifier);
  PlaybackState state() => container.read(playbackProvider);
  List<String> methods() => [for (final c in calls) c.method];
  List<MethodCall> callsTo(String method) => [
    for (final c in calls)
      if (c.method == method) c,
  ];

  /// Delivers a button press from the native side, as the runner would.
  Future<void> press(String button) async {
    await messenger.handlePlatformMessage(
      smtcChannel.name,
      smtcChannel.codec.encodeMethodCall(MethodCall('button', button)),
      (_) {},
    );
    await pumpEventQueue();
  }

  setUp(() async {
    now = DateTime(2026);
    calls = [];
    messenger.setMockMethodCallHandler(smtcChannel, (call) async {
      calls.add(call);
      return null;
    });
    db = inMemoryDatabase();
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
        mediaCommandsProvider.overrideWith(
          (ref) => MediaCommands(ref, clock: () => now),
        ),
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final name in ['A', 'B', 'C'])
        trackRow('$name.mp3', title: name, artist: 'Artist $name'),
    ]);
    tracks = await library.watchTracks().first;
    controls = WindowsMediaControls(container, clock: () => now)..start();
  });

  tearDown(() async {
    controls.dispose();
    messenger.setMockMethodCallHandler(smtcChannel, null);
    container.dispose();
    await db.close();
  });

  group('state → SMTC', () {
    test('nothing is sent before a track is loaded', () async {
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test('playing a track sends metadata, playback and timeline', () async {
      engine.durationValue = const Duration(minutes: 3);
      await controller().playTracks(tracks);
      await pumpEventQueue();

      expect(callsTo('metadata').single.arguments, {
        'title': 'A',
        'artist': 'Artist A',
        'album': '',
        'artwork': '',
      });
      final playback = callsTo('playback').last.arguments as Map;
      expect(playback['status'], 'playing');
      expect(playback['canNext'], isTrue);
      expect(playback['canPrevious'], isTrue);
      expect(callsTo('timeline').last.arguments, {
        'positionMs': 0,
        'durationMs': 180000,
      });
    });

    test('unrelated state changes send nothing', () async {
      await controller().playTracks(tracks);
      await pumpEventQueue();
      calls.clear();

      await controller().setVolume(0.4);
      controller().toggleShuffle();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test(
      'a new track sends new metadata; the last one disables Next',
      () async {
        await controller().playTracks(tracks, startIndex: 1);
        await pumpEventQueue();
        calls.clear();

        await controller().next();
        await pumpEventQueue();
        expect(
          callsTo('metadata').single.arguments,
          containsPair('title', 'C'),
        );
        expect((callsTo('playback').last.arguments as Map)['canNext'], isFalse);
      },
    );

    test('pausing reports paused and re-anchors the timeline', () async {
      await controller().playTracks(tracks);
      await pumpEventQueue();
      calls.clear();

      await controller().pause();
      await pumpEventQueue();
      expect(methods(), ['playback', 'timeline']);
      expect((calls.first.arguments as Map)['status'], 'paused');
    });

    test('artwork passes through: https thumbnail or local file', () async {
      await controller().playTracks([
        tracks.first.copyWith(
          artworkUrl: 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
        ),
        tracks[1].copyWith(artworkPath: r'C:\art\b.jpg'),
      ]);
      await pumpEventQueue();
      await controller().next();
      await pumpEventQueue();
      expect(
        [for (final c in callsTo('metadata')) (c.arguments as Map)['artwork']],
        ['https://i.ytimg.com/vi/abc/hqdefault.jpg', r'C:\art\b.jpg'],
      );
    });
  });

  group('timeline throttling', () {
    setUp(() async {
      await controller().playTracks(tracks);
      await pumpEventQueue();
      calls.clear();
    });

    /// Plays for [seconds] in 250 ms engine ticks, advancing the clock.
    void playFor(int seconds, {Duration from = Duration.zero}) {
      for (var ms = 250; ms <= seconds * 1000; ms += 250) {
        now = now.add(const Duration(milliseconds: 250));
        engine.tick(from + Duration(milliseconds: ms));
      }
    }

    test('regular ticks only send a heartbeat every 5 s', () {
      playFor(4);
      expect(calls, isEmpty);

      playFor(1, from: const Duration(seconds: 4));
      expect(
        callsTo('timeline').single.arguments,
        containsPair('positionMs', 5000),
      );

      playFor(10, from: const Duration(seconds: 5));
      expect(callsTo('timeline'), hasLength(3));
    });

    test('a seek is sent immediately', () {
      now = now.add(const Duration(milliseconds: 250));
      engine.tick(const Duration(seconds: 90));
      expect(
        callsTo('timeline').single.arguments,
        containsPair('positionMs', 90000),
      );
    });

    test('no heartbeat while paused', () async {
      await controller().pause();
      await pumpEventQueue();
      calls.clear();
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(milliseconds: 250));
        engine.tick(Duration.zero);
      }
      expect(calls, isEmpty);
    });
  });

  group('SMTC buttons → controller', () {
    setUp(() async {
      await controller().playTracks(tracks);
      await pumpEventQueue();
      engine.calls.clear();
    });

    test('pause, play, next, previous and stop', () async {
      await press('pause');
      expect(state().status, PlaybackStatus.paused);

      await press('play');
      expect(state().status, PlaybackStatus.playing);

      now = now.add(const Duration(seconds: 1));
      await press('next');
      expect(state().current!.track.title, 'B');

      now = now.add(const Duration(seconds: 1));
      await press('previous');
      expect(state().current!.track.title, 'A');

      now = now.add(const Duration(seconds: 1));
      await press('stop');
      expect(state().status, PlaybackStatus.paused);
    });

    test('unknown buttons are ignored', () async {
      await press('rewind');
      expect(engine.calls, isEmpty);
    });

    test('a failing channel is logged once and never throws', () async {
      messenger.setMockMethodCallHandler(smtcChannel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'smtc');
      });
      calls.clear();
      await controller().next();
      await pumpEventQueue();
      final attempted = calls.length;
      expect(attempted, greaterThan(0));

      await controller().next();
      await pumpEventQueue();
      expect(calls, hasLength(attempted)); // Gave up after the failure.
      expect(state().current!.track.title, 'C');
    });
  });

  group('media key de-duplication', () {
    MediaCommands commands() => container.read(mediaCommandsProvider);

    setUp(() async {
      await controller().playTracks(tracks);
      await pumpEventQueue();
      engine.calls.clear();
    });

    test('one press seen by both the window and SMTC acts once', () async {
      await commands().handle(
        MediaCommand.playPause,
        MediaCommandSource.keyboard,
      );
      now = now.add(const Duration(milliseconds: 60));
      await press('pause'); // SMTC's view of the same key press.
      await pumpEventQueue();
      expect(engine.calls, ['pause']);

      now = now.add(const Duration(milliseconds: 60));
      await press('next');
      now = now.add(const Duration(milliseconds: 60));
      await commands().handle(MediaCommand.next, MediaCommandSource.keyboard);
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');
    });

    test('quick repeated presses from one source all count', () async {
      await commands().handle(MediaCommand.next, MediaCommandSource.keyboard);
      now = now.add(const Duration(milliseconds: 100));
      await commands().handle(MediaCommand.next, MediaCommandSource.keyboard);
      await pumpEventQueue();
      expect(state().current!.track.title, 'C');
    });

    test('the same command later from the other source counts', () async {
      await commands().handle(MediaCommand.next, MediaCommandSource.keyboard);
      now = now.add(MediaCommands.duplicateWindow);
      await press('next');
      expect(state().current!.track.title, 'C');
    });
  });
}
