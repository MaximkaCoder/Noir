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
  const EngineFailed(this.message);

  /// User-facing explanation, free of diagnostic details.
  final String message;
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
