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
/// on the local engine; otherwise on the engine for its source. Its file is
/// fetched meanwhile: when the remote player stops by itself while the app
/// is out of sight (Android's web view does), it is started again once;
/// if it stops again or doesn't play, the track carries on from that file
/// where it stopped.
class RoutingEngine implements PlaybackEngine, MixingEngine {
  RoutingEngine(
    this._engines, {
    this._files = const NoAudioFiles(),
    this._inBackground = _never,
    this._restartAfter = const Duration(milliseconds: 300),
    this._restartTimeout = const Duration(seconds: 3),
  }) : _active = _engines.values.first {
    for (final MapEntry(key: source, value: engine) in _engines.entries) {
      _subs
        ..add(
          engine.events.listen((e) {
            if (!identical(engine, _active)) return;
            if (e case EngineStatusChanged(status: PlaybackStatus.paused)
                when _handingOver) {
              return; // The file loading, about to play.
            }
            if (e case EngineStatusChanged(:final status)) {
              _remotePlaying = status == PlaybackStatus.playing;
            }
            if (e case EngineStatusChanged(status: PlaybackStatus.paused)
                when _suspended()) {
              // Not a pause anyone asked for: still "playing" (so the OS
              // keeps the app running) until it plays again.
              _events.add(const EngineStatusChanged(PlaybackStatus.buffering));
              unawaited(_restarted ? _handOver() : _restart());
              return;
            }
            _events.add(e);
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
  final bool Function() _inBackground;
  final Duration _restartAfter;
  final Duration _restartTimeout;
  PlaybackEngine _active;

  static bool _never() => false;

  /// The track the active remote player plays, and its file being fetched.
  Track? _remote;
  Future<String?>? _remoteFile;
  bool _handingOver = false;

  /// Whether the remote player was started again after stopping by itself
  /// (once per track), and whether it plays now.
  bool _restarted = false;
  bool _remotePlaying = false;

  /// Whether playing was asked for last (not a pause or stop).
  bool _wantsPlay = false;

  /// A file lookup slower than this is ignored, so playback never waits.
  static const _lookupTimeout = Duration(seconds: 2);

  /// How long a track nothing else can play may wait for its file.
  static const _fileNowTimeout = Duration(minutes: 2);

  /// Counts [load]s, so one overtaken while it waited plays nothing.
  int _loads = 0;
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
  /// [wait]: a track nothing here can play waits for its file (only when it
  /// is to play now, never for a look ahead).
  Future<(PlaybackEngine, Track)?> _route(
    Track track, {
    bool wait = false,
  }) async {
    final local = _engines[MediaSource.local];
    if (track.source != MediaSource.local && local != null) {
      final path = await _lookup(track);
      if (path != null) return (local, track.copyWith(uri: path));
    }
    final engine = _engines[track.source];
    if (wait &&
        engine == null &&
        local != null &&
        track.source != MediaSource.local) {
      // No player for this source here: wait for a file instead. What
      // played so far stops meanwhile; it isn't what was asked for.
      await _active.stop();
      final path = await _fileNow(track);
      return path == null ? null : (local, track.copyWith(uri: path));
    }
    return engine == null ? null : (engine, track);
  }

  Future<String?> _fileNow(Track track) async {
    try {
      return await _files
          .fileNow(track)
          .timeout(_fileNowTimeout, onTimeout: () => null);
    } on Object catch (e) {
      debugPrint('Audio file fetch failed: ${e.runtimeType}');
      return null;
    }
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
    final ticket = ++_loads;
    final route = await _route(track, wait: true);
    // Another song was asked for while this one waited for its file.
    if (ticket != _loads) return false;
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
    final local = _engines[MediaSource.local];
    final remote = local != null && !identical(next, local);
    _remote = remote ? track : null;
    _remoteFile = remote ? _fileNow(track) : null;
    _restarted = false;
    return await _active.load(routed, start: start);
  }

  bool _suspended() => _remote != null && _wantsPlay && _inBackground();

  /// Starts the remote player again, which plays on in the background once
  /// the web view is shown again; the file takes over if it doesn't.
  Future<void> _restart() async {
    _restarted = true;
    final ticket = _loads;
    final engine = _active;
    bool current() => ticket == _loads && identical(engine, _active);
    await Future<void>.delayed(_restartAfter);
    if (!current() || !_wantsPlay) return;
    await engine.play();
    await Future<void>.delayed(_restartTimeout);
    if (current() && _wantsPlay && !_remotePlaying) await _handOver();
  }

  /// Moves the remote track onto the local engine once its file is there,
  /// from where the remote player stopped.
  Future<void> _handOver() async {
    final track = _remote;
    final file = _remoteFile;
    final local = _engines[MediaSource.local];
    if (track == null || file == null || local == null || _handingOver) {
      return;
    }
    final ticket = _loads;
    _handingOver = true;
    try {
      final path = await file;
      if (ticket != _loads) return;
      if (path == null || !_wantsPlay) {
        _events.add(const EngineStatusChanged(PlaybackStatus.paused));
        return;
      }
      final at = _active.currentPosition;
      await _active.stop();
      _active = local;
      _remote = null;
      _remoteFile = null;
      if (await local.load(track.copyWith(uri: path), start: at)) {
        await local.play();
      }
    } finally {
      _handingOver = false;
    }
  }

  @override
  Future<void> play() {
    _wantsPlay = true;
    return _active.play();
  }

  @override
  Future<void> pause() {
    _wantsPlay = false;
    return _active.pause();
  }

  @override
  Future<void> seek(Duration position) => _active.seek(position);
  @override
  Future<void> stop() {
    _wantsPlay = false;
    return _active.stop();
  }

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
