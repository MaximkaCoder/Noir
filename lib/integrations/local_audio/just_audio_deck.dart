import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:noir/integrations/local_audio/audio_deck.dart';
import 'package:noir/shared/models/playback.dart';

/// A deck on just_audio, for platforms without the libmpv deck (Android,
/// Apple). Speed changes keep the pitch; positions are just_audio's
/// interpolated estimate, so beat alignment is looser than on mpv.
class JustAudioDeck implements AudioDeck {
  JustAudioDeck() {
    _subs
      ..add(
        _player.playerStateStream.listen(
          (s) => _status.add(switch (s.processingState) {
            ProcessingState.idle => PlaybackStatus.idle,
            ProcessingState.loading => PlaybackStatus.loading,
            ProcessingState.buffering => PlaybackStatus.buffering,
            ProcessingState.ready =>
              s.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
            ProcessingState.completed => PlaybackStatus.completed,
          }),
          onError: (Object e, StackTrace _) => _errors.add('$e'),
        ),
      )
      ..add(_player.durationStream.listen(_durations.add));
  }

  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  final _status = StreamController<PlaybackStatus>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _errors = StreamController<String>.broadcast();

  @override
  Stream<PlaybackStatus> get status => _status.stream;
  @override
  Stream<Duration?> get durations => _durations.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Duration get position => _player.position;
  @override
  Duration? get duration => _player.duration;
  @override
  bool get playing => _player.playing;

  @override
  Future<double> exactPosition() async => _player.position.inMicroseconds / 1e6;

  @override
  Future<void> open(String path, {Duration start = Duration.zero}) async {
    try {
      await _player.setFilePath(path, initialPosition: start);
    } on PlayerException catch (e) {
      throw DeckLoadException(e);
    } on PlayerInterruptedException {
      throw const DeckInterrupted();
    }
  }

  // Not awaited: just_audio's play() completes only when playback stops.
  @override
  Future<void> play() async => unawaited(_player.play());

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setLevel(double volume, {double gain = 1}) =>
      _player.setVolume((volume * gain).clamp(0.0, 1.0));

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    await _status.close();
    await _durations.close();
    await _errors.close();
  }
}
