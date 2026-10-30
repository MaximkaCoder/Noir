import 'dart:async';

import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Scriptable engine: records calls and lets tests emit events.
class FakeEngine implements PlaybackEngine, MixingEngine {
  final calls = <String>[];
  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration?>.broadcast(sync: true);

  Duration positionValue = Duration.zero;
  Duration? durationValue;
  Track? loaded;

  /// Paths for which load() reports a failure.
  final failing = <String>{};

  /// play() reports nothing, as a player that doesn't start.
  bool silentPlay = false;

  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities(
    canSeek: true,
    canSkip: true,
    canControlVolume: true,
    canShuffle: true,
    canRepeat: true,
    canCrossfade: true,
    supportsBackgroundPlayback: true,
    supportsQueueMutation: true,
  );

  void emit(EngineEvent e) => _events.add(e);

  void tick(Duration position) {
    positionValue = position;
    _position.add(position);
  }

  @override
  Stream<EngineEvent> get events => _events.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Duration get currentPosition => positionValue;
  @override
  Stream<Duration?> get duration => _duration.stream;
  @override
  Duration? get currentDuration => durationValue;

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async {
    calls.add('load ${track.title} @${start.inSeconds}');
    loaded = track;
    positionValue = start;
    if (failing.contains(track.uri)) {
      emit(const EngineFailed('cannot play'));
      return false;
    }
    emit(const EngineStatusChanged(PlaybackStatus.paused));
    return true;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    if (!silentPlay) emit(const EngineStatusChanged(PlaybackStatus.playing));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(const EngineStatusChanged(PlaybackStatus.paused));
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek ${position.inSeconds}');
    positionValue = position;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');

  /// Completed by tests to end a fade.
  Completer<void>? fade;

  @override
  Future<void> crossfadeTo(Track next, Duration fade) {
    calls.add('crossfade ${next.title} ${fade.inSeconds}s');
    loaded = next;
    return (this.fade = Completer<void>()).future;
  }

  /// Whether [canMixInto] says yes.
  bool mixable = true;

  /// The last planned transition; tests complete [mix] to end it and call
  /// [mixStart] when the next track becomes audible.
  TransitionPlan? mixPlan;
  Completer<bool>? mix;
  void Function()? mixStart;
  void Function(double)? mixProgress;

  @override
  Future<bool> canMixInto(Track next) async => mixable;

  @override
  Future<bool> transitionTo(
    Track next,
    TransitionPlan plan, {
    void Function()? onStart,
    void Function(double progress)? onProgress,
  }) {
    calls.add('mix ${next.title} ${plan.type.name}');
    mixPlan = plan;
    mixProgress = onProgress;
    mixStart = () {
      loaded = next;
      onStart?.call();
    };
    return (mix = Completer<bool>()).future;
  }

  @override
  Future<void> dispose() async {}
}
