import 'dart:async';

import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// One engine per media source behind a single [PlaybackEngine], so the
/// controller and UI stay source-agnostic. Only the active engine's events
/// and position are forwarded; switching sources stops the other engine.
class RoutingEngine implements PlaybackEngine {
  RoutingEngine(this._engines) : _active = _engines.values.first {
    for (final MapEntry(key: source, value: engine) in _engines.entries) {
      _subs
        ..add(
          engine.events.listen((e) {
            if (identical(engine, _active)) _events.add(e);
          }),
        )
        ..add(
          engine.position.listen((p) {
            if (identical(engine, _active)) _position.add(p);
          }),
        )
        ..add(
          engine.duration.listen((d) {
            if (identical(engine, _active)) _duration.add(d);
          }),
        );
      assert(_engines[source] == engine, 'one engine per source');
    }
  }

  final Map<MediaSource, PlaybackEngine> _engines;
  PlaybackEngine _active;
  final _subs = <StreamSubscription<Object?>>[];
  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  PlaybackEngine? engineFor(MediaSource source) => _engines[source];

  @override
  PlaybackCapabilities get capabilities => _active.capabilities;
  @override
  Stream<EngineEvent> get events => _events.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Duration get currentPosition => _active.currentPosition;
  @override
  Stream<Duration?> get duration => _duration.stream;
  @override
  Duration? get currentDuration => _active.currentDuration;

  Future<bool> _switchTo(Track track) async {
    final next = _engines[track.source];
    if (next == null) {
      _events.add(
        const EngineFailed('This kind of item cannot be played here.'),
      );
      return false;
    }
    if (!identical(next, _active)) {
      await _active.stop();
      _active = next;
    }
    return true;
  }

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async =>
      await _switchTo(track) && await _active.load(track, start: start);

  @override
  Future<void> play() => _active.play();
  @override
  Future<void> pause() => _active.pause();
  @override
  Future<void> seek(Duration position) => _active.seek(position);
  @override
  Future<void> stop() => _active.stop();

  @override
  Future<void> setVolume(double volume) async {
    for (final e in _engines.values) {
      await e.setVolume(volume);
    }
  }

  /// Fades only within the same source; across sources it simply switches.
  @override
  Future<void> crossfadeTo(Track next, Duration fade) async {
    final same = identical(_engines[next.source], _active);
    if (same && _active.capabilities.canCrossfade) {
      return await _active.crossfadeTo(next, fade);
    }
    if (await load(next)) await play();
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    for (final e in _engines.values) {
      await e.dispose();
    }
    await _events.close();
    await _position.close();
    await _duration.close();
  }
}
