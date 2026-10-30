import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/routing_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/fake_audio_files.dart';
import '../helpers/fake_engine.dart';

Track track(String id, MediaSource source) =>
    Track(id: id, source: source, title: id, uri: id);

void main() {
  late FakeEngine local;
  late FakeEngine youtube;
  late RoutingEngine router;
  late List<EngineEvent> events;

  setUp(() {
    local = FakeEngine();
    youtube = FakeEngine();
    router = RoutingEngine({
      MediaSource.local: local,
      MediaSource.youtube: youtube,
    });
    events = [];
    router.events.listen(events.add);
  });

  test('loads each track on the engine for its source', () async {
    await router.load(track('song', MediaSource.local));
    await router.load(track('video', MediaSource.youtube));

    expect(local.calls, ['load song @0', 'stop']);
    expect(youtube.calls, ['load video @0']);
  });

  test('forwards events from the active engine only', () async {
    await router.load(track('video', MediaSource.youtube));
    await pumpEventQueue();
    events.clear();

    local.emit(const EngineStatusChanged(PlaybackStatus.playing));
    youtube.emit(const EngineStatusChanged(PlaybackStatus.buffering));
    await pumpEventQueue();

    expect(events.whereType<EngineStatusChanged>().map((e) => e.status), [
      PlaybackStatus.buffering,
    ]);
  });

  test('never crossfades into another source', () async {
    await router.load(track('song', MediaSource.local));
    await router.crossfadeTo(
      track('video', MediaSource.youtube),
      const Duration(seconds: 5),
    );

    expect(local.calls, isNot(contains(startsWith('crossfade'))));
    expect(youtube.calls, ['load video @0', 'play']);
  });

  test('volume applies to every engine', () async {
    await router.setVolume(0.4);
    expect(local.calls, ['volume 0.4']);
    expect(youtube.calls, ['volume 0.4']);
  });

  group('with an audio file provider', () {
    late FakeAudioFiles files;
    var background = false;

    setUp(() {
      files = FakeAudioFiles();
      background = false;
      router = RoutingEngine(
        {MediaSource.local: local, MediaSource.youtube: youtube},
        files: files,
        inBackground: () => background,
        restartAfter: Duration.zero,
        restartTimeout: Duration.zero,
      );
      events = [];
      router.events.listen(events.add);
    });

    Future<void> playVideo() async {
      await router.load(track('video', MediaSource.youtube));
      await router.play();
      youtube.tick(const Duration(seconds: 42));
      await pumpEventQueue();
      events.clear();
      local.calls.clear();
    }

    List<PlaybackStatus> statuses() => [
      for (final e in events.whereType<EngineStatusChanged>()) e.status,
    ];

    /// The player stops by itself in the background.
    Future<void> suspend() async {
      background = true;
      youtube.emit(const EngineStatusChanged(PlaybackStatus.paused));
      await pumpEventQueue();
    }

    test('in the background, a player that stops by itself is started '
        'again', () async {
      files.later['video'] = '/cache/video.webm';
      await playVideo();

      await suspend();

      expect(youtube.calls.last, 'play');
      expect(statuses(), [PlaybackStatus.buffering, PlaybackStatus.playing]);
      expect(local.calls, isEmpty);
    });

    test('when it stops again, the track carries on from its file', () async {
      files.later['video'] = '/cache/video.webm';
      await playVideo();

      await suspend();
      await suspend();

      expect(youtube.calls.last, 'stop');
      expect(local.calls, ['load video @42', 'play']);
      expect(local.loaded!.uri, '/cache/video.webm');
      expect(statuses(), isNot(contains(PlaybackStatus.paused)));
      expect(statuses().last, PlaybackStatus.playing);
    });

    test('when it does not play again, the file takes over', () async {
      files.later['video'] = '/cache/video.webm';
      await playVideo();
      youtube.silentPlay = true;

      await suspend();

      expect(local.calls, ['load video @42', 'play']);
    });

    test('keeps the track going until its file is there', () async {
      final file = files.waits['video'] = Completer<void>();
      files.later['video'] = '/cache/video.webm';
      await playVideo();

      await suspend();
      await suspend();
      expect(statuses(), [
        PlaybackStatus.buffering,
        PlaybackStatus.playing,
        PlaybackStatus.buffering,
      ]);
      expect(local.calls, isEmpty);

      file.complete();
      await pumpEventQueue();
      expect(local.calls, ['load video @42', 'play']);
    });

    test('pauses after all when the file cannot be got', () async {
      await playVideo();

      await suspend();
      await suspend();

      expect(statuses().last, PlaybackStatus.paused);
      expect(local.calls, isEmpty);
    });

    test('a pause asked for is a pause, in the background too', () async {
      files.later['video'] = '/cache/video.webm';
      await playVideo();

      background = true;
      await router.pause();
      await pumpEventQueue();

      expect(statuses(), [PlaybackStatus.paused]);
      expect(local.calls, isEmpty);
    });

    test('in sight, the player stopping by itself is a pause', () async {
      files.later['video'] = '/cache/video.webm';
      await playVideo();

      youtube.emit(const EngineStatusChanged(PlaybackStatus.paused));
      await pumpEventQueue();

      expect(statuses(), [PlaybackStatus.paused]);
      expect(local.calls, isEmpty);
    });

    test('plays a provided file on the local engine', () async {
      files.files['video'] = '/cache/video.webm';
      await router.load(track('video', MediaSource.youtube));

      expect(local.calls, ['load video @0']);
      expect(local.loaded!.uri, '/cache/video.webm');
      expect(local.loaded!.source, MediaSource.youtube);
      expect(youtube.calls, isEmpty);
    });

    test('uses the embedded player when there is no file', () async {
      await router.load(track('video', MediaSource.youtube));

      expect(youtube.calls, ['load video @0']);
      expect(local.calls, isNot(contains(startsWith('load'))));
    });

    test('falls back to the embedded player when the lookup fails', () async {
      files.error = Exception('broken');
      await router.load(track('video', MediaSource.youtube));

      expect(youtube.calls, ['load video @0']);
    });

    test('does not wait for a slow lookup', () async {
      files.gate = Completer<void>();
      await router.load(track('video', MediaSource.youtube));

      expect(youtube.calls, ['load video @0']);
    });

    test('with a player for the source, never waits for a file', () async {
      files.waits['video'] = Completer<void>();
      files.later['video'] = '/cache/video.webm';
      await router.load(track('video', MediaSource.youtube));

      expect(youtube.calls, ['load video @0']);
      // Fetched meanwhile, for when the player stops in the background.
      expect(files.askedNow, ['video']);
    });

    test('never consults the provider for local tracks', () async {
      files.files['song'] = 'elsewhere';
      await router.load(track('song', MediaSource.local));

      expect(local.loaded!.uri, 'song');
    });

    test('crossfades between two provided files', () async {
      files.files.addAll({'v1': 'f1', 'v2': 'f2'});
      await router.load(track('v1', MediaSource.youtube));

      expect(
        await router.canCrossfadeTo(track('v2', MediaSource.youtube)),
        isTrue,
      );
      unawaited(
        router.crossfadeTo(
          track('v2', MediaSource.youtube),
          const Duration(seconds: 5),
        ),
      );
      await pumpEventQueue();

      expect(local.calls, ['load v1 @0', 'crossfade v2 5s']);
      expect(local.loaded!.uri, 'f2');
    });

    test('switches engines instead of fading into a video', () async {
      files.files['v1'] = 'f1';
      await router.load(track('v1', MediaSource.youtube));

      expect(
        await router.canCrossfadeTo(track('v2', MediaSource.youtube)),
        isFalse,
      );
      await router.crossfadeTo(
        track('v2', MediaSource.youtube),
        const Duration(seconds: 5),
      );

      expect(local.calls, ['load v1 @0', 'stop']);
      expect(youtube.calls, ['load v2 @0', 'play']);
    });
  });

  // Platforms without the embedded player: a track plays once its file is
  // there, and looking ahead never makes a transition wait.
  group('without a player for the source', () {
    late FakeAudioFiles files;

    setUp(() {
      files = FakeAudioFiles();
      router = RoutingEngine({MediaSource.local: local}, files: files);
      events = [];
      router.events.listen(events.add);
    });

    test('loads the file fetched for it', () async {
      files.later['video'] = '/cache/video.webm';
      expect(await router.load(track('video', MediaSource.youtube)), isTrue);

      expect(files.askedNow, ['video']);
      expect(local.loaded!.uri, '/cache/video.webm');
    });

    test('fails when there is no file to get', () async {
      expect(await router.load(track('video', MediaSource.youtube)), isFalse);
      await pumpEventQueue();
      expect(events.whereType<EngineFailed>(), hasLength(1));
    });

    test(
      'the song playing stops while the next one waits for its file',
      () async {
        await router.load(track('song', MediaSource.local));
        local.calls.clear();
        final file = files.waits['video'] = Completer<void>();
        files.later['video'] = '/cache/video.webm';
        final loading = router.load(track('video', MediaSource.youtube));
        await pumpEventQueue();
        expect(local.calls, ['stop']);

        file.complete();
        expect(await loading, isTrue);
        expect(local.loaded!.uri, '/cache/video.webm');
      },
    );

    test('a song asked for while another waits plays instead of it', () async {
      final slow = files.waits['a'] = Completer<void>();
      files.later['a'] = '/cache/a.webm';
      final first = router.load(track('a', MediaSource.youtube));
      await pumpEventQueue();
      expect(await router.load(track('song', MediaSource.local)), isTrue);
      final song = local.loaded;

      slow.complete();
      expect(await first, isFalse);
      expect(local.loaded, same(song));
    });

    test('a look ahead does not fetch', () async {
      files.later['next'] = '/cache/next.webm';
      expect(
        await router.canMixInto(track('next', MediaSource.youtube)),
        isFalse,
      );
      expect(files.askedNow, isEmpty);
    });
  });
}
