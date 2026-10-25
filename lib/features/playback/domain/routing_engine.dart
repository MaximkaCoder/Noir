import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noir/features/playback/domain/audio_source_provider.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// One engine per media source behind a single [PlaybackEngine], so the
/// controller and UI stay source-agnostic. Only the active engine's events
/// and position are forwarded; switching sources stops the other engine.
///
/// A non-local track for which [AudioFileProvider] has a local file plays
/// on the local engine; otherwise on the engine for its source.
class RoutingEngine implements PlaybackEngine, MixingEngine {
  RoutingEngine(this._engines, {this._files = const NoAudioFiles()})
    : _active = _engines.values.first {
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
  final AudioFileProvider _files;
  PlaybackEngine _active;

  /// A file lookup slower than this is ignored, so playback never waits.
  static const _lookupTimeout = Duration(seconds: 2);
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

  /// The engine for [track] and the track as that engine should see it.
  Future<(PlaybackEngine, Track)?> _route(Track track) async {
    final local = _engines[MediaSource.local];
    if (track.source != MediaSource.local && local != null) {
      final path = await _lookup(track);
      if (path != null) return (local, track.copyWith(uri: path));
    }
    final engine = _engines[track.source];
    return engine == null ? null : (engine, track);
  }

  Future<String?> _lookup(Track track) async {
    try {
      return await _files
          .cachedFile(track)
          .timeout(_lookupTimeout, onTimeout: () => null);
    } on Object catch (e) {
      debugPrint('Audio file lookup failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Whether [next] would play on the active engine, so it can fade in.
  Future<bool> canCrossfadeTo(Track next) async {
    final route = await _route(next);
    return route != null &&
        identical(route.$1, _active) &&
        _active.capabilities.canCrossfade;
  }

  /// Whether [next] would play on the active engine and that engine can
  /// mix (beat-match) into it.
  @override
  Future<bool> canMixInto(Track next) async {
    final route = await _route(next);
    return route != null &&
        identical(route.$1, _active) &&
        _active is MixingEngine &&
        await (_active as MixingEngine).canMixInto(route.$2);
  }

  @override
  Future<bool> transitionTo(
    Track next,
    TransitionPlan plan, {
    void Function()? onStart,
    void Function(double progress)? onProgress,
  }) async {
    final route = await _route(next);
    final active = _active;
    if (route == null ||
        !identical(route.$1, active) ||
        active is! MixingEngine) {
      return false;
    }
    return await (active as MixingEngine).transitionTo(
      route.$2,
      plan,
      onStart: onStart,
      onProgress: onProgress,
    );
  }

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async {
    final route = await _route(track);
    if (route == null) {
      _events.add(
        const EngineFailed('This kind of item cannot be played here.'),
      );
      return false;
    }
    final (next, routed) = route;
    if (!identical(next, _active)) {
      await _active.stop();
      _active = next;
    }
    return await _active.load(routed, start: start);
  }

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

  /// Fades only within the same engine; across engines it simply switches.
  @override
  Future<void> crossfadeTo(Track next, Duration fade) async {
    final route = await _route(next);
    if (route != null &&
        identical(route.$1, _active) &&
        _active.capabilities.canCrossfade) {
      return await _active.crossfadeTo(route.$2, fade);
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
