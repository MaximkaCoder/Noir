import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/routing_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

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
}
