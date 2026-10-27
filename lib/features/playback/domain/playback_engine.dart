import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Low-level events an engine reports to the playback controller.
sealed class EngineEvent {
  const EngineEvent();
}

final class EngineStatusChanged extends EngineEvent {
  const EngineStatusChanged(this.status);
  final PlaybackStatus status;
}

/// The current item reached its end naturally.
final class EngineCompleted extends EngineEvent {
  const EngineCompleted();
}

final class EngineFailed extends EngineEvent {
  const EngineFailed(this.message, {this.unplayable});

  /// User-facing explanation, free of diagnostic details.
  final String message;

  /// Set when the fault is this track's own (removed, or not allowed here),
  /// so trying it again won't help.
  final Track? unplayable;
}

/// One way of producing sound for one media source. The controller owns the
/// queue; an engine only plays what it is told to.
abstract interface class PlaybackEngine {
  PlaybackCapabilities get capabilities;

  Stream<EngineEvent> get events;

  /// Throttled position of the current item.
  Stream<Duration> get position;
  Duration get currentPosition;

  Stream<Duration?> get duration;
  Duration? get currentDuration;

  /// Prepares [track] paused at [start]. Returns false when it cannot be
  /// played; the reason is reported as an [EngineFailed] event.
  Future<bool> load(Track track, {Duration start = Duration.zero});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// 0.0–1.0. Only meaningful when [PlaybackCapabilities.canControlVolume].
  Future<void> setVolume(double volume);

  /// Starts [next] and blends it with the current item over [fade]. After the
  /// returned future completes, [next] is the current item.
  /// Only valid when [PlaybackCapabilities.canCrossfade].
  Future<void> crossfadeTo(Track next, Duration fade);

  Future<void> dispose();
}

/// An engine that can perform a planned transition itself (beat-matched
/// blends, tempo ramps, scheduled gapless starts).
abstract interface class MixingEngine {
  /// Whether [next] would be mixed on this engine (same player as the
  /// current item).
  Future<bool> canMixInto(Track next);

  /// Hands over from the current item to [next] as [plan] says. [onStart]
  /// fires when [next] becomes audible — from then on it is the current
  /// item (position, duration and events are its own). [onProgress] reports
  /// the blend's progress, 0–1.
  ///
  /// Completes with true once the transition is over, or false when it
  /// was abandoned before [next] started (a user action, or [next] cannot
  /// be played); the current item then simply keeps playing.
  Future<bool> transitionTo(
    Track next,
    TransitionPlan plan, {
    void Function()? onStart,
    void Function(double progress)? onProgress,
  });
}
