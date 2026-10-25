import 'package:noir/shared/models/playback.dart';

/// One player of the local engine. The engine keeps two so the next track
/// can be mixed in while the current one plays out.
abstract interface class AudioDeck {
  /// idle / loading / buffering / playing / paused / completed.
  Stream<PlaybackStatus> get status;
  Stream<Duration?> get durations;

  /// Playback failures after a successful [open].
  Stream<String> get errors;

  /// Position of what is heard now (cheap, may lag by a few ms).
  Duration get position;
  Duration? get duration;
  bool get playing;

  /// Position of what is heard right now, as exactly as the backend can
  /// tell (accounting for output latency), in seconds.
  Future<double> exactPosition();

  /// Loads [path] paused at [start]. Throws [DeckLoadException] when it
  /// cannot be played and [DeckInterrupted] when a newer open() or stop()
  /// superseded it.
  Future<void> open(String path, {Duration start = Duration.zero});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// [volume] is the user's 0–1 setting (mapped the way this backend always
  /// has), [gain] a linear amplitude factor from the mixer.
  Future<void> setLevel(double volume, {double gain = 1});

  /// Playback rate with pitch preserved.
  Future<void> setSpeed(double speed);

  Future<void> dispose();
}

class DeckLoadException implements Exception {
  const DeckLoadException(this.cause);

  final Object cause;

  @override
  String toString() => 'DeckLoadException($cause)';
}

class DeckInterrupted implements Exception {
  const DeckInterrupted();
}
