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

    setUp(() {
      files = FakeAudioFiles();
      router = RoutingEngine({
        MediaSource.local: local,
        MediaSource.youtube: youtube,
      }, files: files);
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
}
