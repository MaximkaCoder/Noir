import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/integrations/local_audio/audio_deck.dart';
import 'package:noir/integrations/local_audio/just_audio_deck.dart';
import 'package:noir/integrations/local_audio/mix_runner.dart';
import 'package:noir/integrations/local_audio/mpv_deck.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Plays user-owned local files (and cached audio of other sources) on two
/// decks — libmpv on Windows/Linux, just_audio elsewhere — so the next
/// track can be mixed in while the current one plays out. Only the active
/// deck's events and position are forwarded.
class LocalAudioEngine implements PlaybackEngine, MixingEngine {
  LocalAudioEngine({
    AudioDeck Function()? deckFactory,
    MixClock? clock,
    MixRunnerFactory? runner,
  }) : _clock = clock ?? RealMixClock(),
       _makeRunner = runner ?? CrossfadeRunner.new {
    final make = deckFactory ?? defaultDeck;
    _active = make();
    _standby = make();
    _bind(_active);
    _ticker = Timer.periodic(_positionPeriod, (_) => _emitPosition());
    if (deckFactory == null) unawaited(_configureSession());
  }

  /// The libmpv deck where media_kit runs it, just_audio elsewhere.
  static AudioDeck defaultDeck() =>
      Platform.isWindows || Platform.isLinux ? MpvDeck() : JustAudioDeck();

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

  static const _positionPeriod = Duration(milliseconds: 250);

  late AudioDeck _active;
  late AudioDeck _standby;
  final MixClock _clock;
  final _timing = MixTiming();
  late final Timer _ticker;

  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  StreamSubscription<void>? _noisySub;

  double _volume = 1;
  PlaybackStatus? _lastStatus;
  Duration? _lastPosition;

  final MixRunnerFactory _makeRunner;
  MixRunner? _runner;
  Future<bool>? _running;

  /// Every tick of the running transition, for diagnostics.
  void Function(MixSample sample)? onMixSample;

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

  /// Latencies learned from earlier transitions.
  MixTiming get timing => _timing;

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

  void _bind(AudioDeck deck) {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs
      ..clear()
      ..add(deck.status.listen(_onStatus))
      ..add(deck.errors.listen(_fail))
      ..add(deck.durations.listen(_duration.add));
    // Deck streams don't replay; the new current item's length is known.
    if (deck.duration != null) _duration.add(deck.duration);
    _lastPosition = null;
    _emitPosition();
  }

  void _emitPosition() {
    final p = _active.position;
    if (p == _lastPosition || _position.isClosed) return;
    _lastPosition = p;
    _position.add(p);
  }

  void _onStatus(PlaybackStatus status) {
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
  bool _checkFile(Track track) {
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
    await _settle();
    _lastStatus = null;
    if (!_checkFile(track)) return false;
    try {
      await _active.setSpeed(1);
      await _active.setLevel(_volume);
      await _active.open(track.uri, start: start);
      return true;
    } on DeckLoadException catch (e) {
      _fail(e);
      return false;
    } on DeckInterrupted {
      // Superseded by a newer load; nothing to report.
      return false;
    }
  }

  @override
  Future<void> play() async {
    await _settle();
    await _active.play();
  }

  @override
  Future<void> pause() async {
    await _settle();
    await _active.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _settle();
    await _active.seek(position);
    _emitPosition();
  }

  @override
  Future<void> stop() async {
    await _settle();
    await _active.stop();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    // A running transition picks the new volume up on its next tick.
    if (_runner == null) await _active.setLevel(_volume);
  }

  @override
  Future<bool> canMixInto(Track next) async => true;

  @override
  Future<void> crossfadeTo(Track next, Duration fade) async {
    await _settle();
    if (!_checkFile(next)) return;
    final at = await _active.exactPosition();
    final seconds = fade.inMicroseconds / 1e6;
    await transitionTo(
      next,
      TransitionPlan(
        type: TransitionType.simpleCrossfade,
        startInA: at,
        endInA: at + seconds,
        entryInB: 0,
        reason: 'crossfade',
      ),
    );
  }

  @override
  Future<bool> transitionTo(
    Track next,
    TransitionPlan plan, {
    void Function()? onStart,
    void Function(double progress)? onProgress,
  }) async {
    await _settle();
    if (!File(next.uri).existsSync()) return false;
    final runner = _runner = _makeRunner(
      outgoing: _active,
      incoming: _standby,
      plan: plan,
      volume: () => _volume,
      timing: _timing,
      clock: _clock,
      onSample: (s) => onMixSample?.call(s),
      onProgress: onProgress,
      onStart: () {
        // From now on the incoming deck is the current item.
        final outgoing = _active;
        _active = _standby;
        _standby = outgoing;
        _lastStatus = null;
        _bind(_active);
        _onStatus(
          _active.playing ? PlaybackStatus.playing : PlaybackStatus.paused,
        );
        onStart?.call();
      },
    );
    final running = _running = runner.run(next.uri);
    try {
      return await running;
    } on Object catch (e) {
      debugPrint('Transition failed: $e');
      return runner.started;
    } finally {
      if (identical(_runner, runner)) {
        _runner = null;
        _running = null;
      }
    }
  }

  /// Any user action during a transition ends it first: one still waiting
  /// is dropped, a running one jumps to its end state.
  Future<void> _settle() async {
    final runner = _runner;
    final running = _running;
    if (runner == null || running == null) return;
    runner.settle();
    try {
      await running;
    } on Object catch (_) {
      // Reported by transitionTo.
    }
  }

  @override
  Future<void> dispose() async {
    _ticker.cancel();
    _runner?.settle();
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
