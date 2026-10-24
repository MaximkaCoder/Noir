import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Plays user-owned local files with just_audio (media_kit on Windows).
///
/// Two players are kept so the next track can fade in while the current one
/// fades out. Only the active player's streams are forwarded.
class LocalAudioEngine implements PlaybackEngine {
  LocalAudioEngine() {
    _bind(_active);
    unawaited(_configureSession());
  }

  static const _caps = PlaybackCapabilities(
    canSeek: true,
    canSkip: true,
    canControlVolume: true,
    canShuffle: true,
    canRepeat: true,
    canCrossfade: true,
    supportsBackgroundPlayback: true,
    supportsQueueMutation: true,
  );

  static const _rampStep = Duration(milliseconds: 50);

  AudioPlayer _active = AudioPlayer();
  AudioPlayer _standby = AudioPlayer();

  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  StreamSubscription<void>? _noisySub;

  double _volume = 1;
  Timer? _ramp;
  Completer<void>? _fadeDone;
  PlaybackStatus? _lastStatus;

  @override
  PlaybackCapabilities get capabilities => _caps;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Duration get currentPosition => _active.position;

  @override
  Stream<Duration?> get duration => _duration.stream;

  @override
  Duration? get currentDuration => _active.duration;

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      // Headphones unplugged: pause instead of blasting through speakers.
      _noisySub = session.becomingNoisyEventStream.listen((_) => pause());
    } on Object catch (e) {
      // Not every desktop platform implements audio sessions.
      debugPrint('Audio session unavailable: ${e.runtimeType}');
    }
  }

  void _bind(AudioPlayer player) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..add(
        player.playerStateStream.listen(
          _onPlayerState,
          onError: (Object e, StackTrace _) => _fail(e),
        ),
      )
      ..add(
        player
            .createPositionStream(
              steps: 400,
              maxPeriod: const Duration(milliseconds: 500),
            )
            .listen(_position.add),
      )
      ..add(player.durationStream.listen(_duration.add));
  }

  void _onPlayerState(PlayerState s) {
    final status = switch (s.processingState) {
      ProcessingState.idle => PlaybackStatus.idle,
      ProcessingState.loading => PlaybackStatus.loading,
      ProcessingState.buffering => PlaybackStatus.buffering,
      ProcessingState.ready =>
        s.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
      ProcessingState.completed => PlaybackStatus.completed,
    };
    if (status == _lastStatus) return;
    _lastStatus = status;
    if (status == PlaybackStatus.completed) {
      _events.add(const EngineCompleted());
    } else {
      _events.add(EngineStatusChanged(status));
    }
  }

  void _fail(Object error) {
    debugPrint('Local playback error: ${error.runtimeType}');
    _events.add(
      const EngineFailed(
        "This file can't be played. It may be damaged or in an unsupported "
        'format.',
      ),
    );
  }

  /// Returns false (and reports why) when the file is gone.
  Future<bool> _checkFile(Track track) async {
    if (File(track.uri).existsSync()) return true;
    _events.add(
      const EngineFailed(
        'This file is no longer available. It may have been moved or '
        'deleted. Rescan your library folders in Settings.',
      ),
    );
    return false;
  }

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async {
    _cancelFade();
    _lastStatus = null;
    if (!await _checkFile(track)) return false;
    try {
      await _active.setVolume(_volume);
      await _active.setFilePath(track.uri, initialPosition: start);
      return true;
    } on PlayerException catch (e) {
      _fail(e);
      return false;
    } on PlayerInterruptedException {
      // Superseded by a newer load; nothing to report.
      return false;
    }
  }

  @override
  Future<void> play() async {
    _cancelFade();
    // Not awaited: just_audio's play() completes only when playback stops.
    unawaited(_active.play());
  }

  @override
  Future<void> pause() async {
    _cancelFade();
    await _active.pause();
  }

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> stop() async {
    _cancelFade();
    await _active.stop();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    if (_ramp == null) await _active.setVolume(_volume);
  }

  @override
  Future<void> crossfadeTo(Track next, Duration fade) async {
    _cancelFade();
    if (!await _checkFile(next)) return;
    final outgoing = _active;
    final incoming = _standby;
    try {
      await incoming.setVolume(0);
      await incoming.setFilePath(next.uri);
    } on PlayerException catch (e) {
      _fail(e);
      return;
    }
    unawaited(incoming.play());

    // From now on the incoming player is the current item.
    _active = incoming;
    _standby = outgoing;
    _lastStatus = null;
    _bind(_active);

    final done = _fadeDone = Completer<void>();
    final started = DateTime.now();
    _ramp = Timer.periodic(_rampStep, (timer) {
      final t =
          (DateTime.now().difference(started).inMilliseconds /
                  fade.inMilliseconds)
              .clamp(0.0, 1.0);
      unawaited(incoming.setVolume(_volume * t));
      unawaited(outgoing.setVolume(_volume * (1 - t)));
      if (t >= 1) _finishFade();
    });
    await done.future;
  }

  void _finishFade() {
    _ramp?.cancel();
    _ramp = null;
    unawaited(_standby.stop());
    unawaited(_active.setVolume(_volume));
    final done = _fadeDone;
    _fadeDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Any user action during a fade jumps straight to its end state.
  void _cancelFade() {
    if (_ramp != null) _finishFade();
  }

  @override
  Future<void> dispose() async {
    _ramp?.cancel();
    await _noisySub?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _active.dispose();
    await _standby.dispose();
    await _events.close();
    await _position.close();
    await _duration.close();
  }
}
