import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:noir/integrations/local_audio/audio_deck.dart';
import 'package:noir/shared/models/playback.dart';

/// A deck on libmpv through media_kit directly (Windows, Linux), so the
/// mixer gets what just_audio hides: sample-exact positions (`audio-pts`,
/// which accounts for output latency) and smooth speed changes (mpv's
/// `speed` with scaletempo2, pitch preserved).
///
/// Filters are not used: the libmpv that media_kit_libs_windows_audio
/// bundles ships no highpass/lowpass, and its lavfi bridge rejects audio
/// graphs (channel-layout mismatch), so transitions are gain + speed only.
class MpvDeck implements AudioDeck {
  MpvDeck({String title = 'NOIR'})
    : _player = Player(configuration: PlayerConfiguration(title: title)) {
    _subs
      ..add(_player.stream.playing.listen((_) => _emit()))
      ..add(_player.stream.buffering.listen((_) => _emit()))
      ..add(_player.stream.completed.listen((_) => _emit()))
      ..add(
        _player.stream.duration.listen((d) {
          if (d > Duration.zero) _durations.add(d);
        }),
      )
      ..add(_player.stream.error.listen(_onError));
  }

  static const _openTimeout = Duration(seconds: 15);

  final Player _player;
  final _subs = <StreamSubscription<Object?>>[];
  final _status = StreamController<PlaybackStatus>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool _loaded = false;
  int _generation = 0;
  Completer<void>? _opening;
  PlaybackStatus? _last;
  double _level = -1;
  double _speed = 1;

  NativePlayer? get _native {
    final p = _player.platform;
    return p is NativePlayer ? p : null;
  }

  @override
  Stream<PlaybackStatus> get status => _status.stream;
  @override
  Stream<Duration?> get durations => _durations.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Duration get position => _player.state.position;

  @override
  Duration? get duration {
    final d = _player.state.duration;
    return _loaded && d > Duration.zero ? d : null;
  }

  @override
  bool get playing => _player.state.playing;

  @override
  Future<double> exactPosition() async {
    final native = _native;
    if (native != null && _loaded) {
      final pts = double.tryParse(await native.getProperty('audio-pts'));
      if (pts != null) return pts;
    }
    return _player.state.position.inMicroseconds / 1e6;
  }

  void _emit() {
    final s = _opening != null
        ? PlaybackStatus.loading
        : !_loaded
        ? PlaybackStatus.idle
        : _player.state.completed
        ? PlaybackStatus.completed
        : _player.state.buffering && _player.state.playing
        ? PlaybackStatus.buffering
        : _player.state.playing
        ? PlaybackStatus.playing
        : PlaybackStatus.paused;
    if (s == _last || _status.isClosed) return;
    _last = s;
    _status.add(s);
  }

  void _onError(String error) {
    debugPrint('mpv deck error');
    final opening = _opening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(DeckLoadException(error));
    } else if (_loaded && !_errors.isClosed) {
      _errors.add(error);
    }
  }

  @override
  Future<void> open(String path, {Duration start = Duration.zero}) async {
    final generation = ++_generation;
    final previous = _opening;
    if (previous != null && !previous.isCompleted) {
      previous.completeError(const DeckInterrupted());
    }
    final opening = _opening = Completer<void>();
    // Errors are read below; don't let an early one count as unhandled.
    opening.future.ignore();
    _loaded = false;
    _emit();
    try {
      if (await startsAsText(path)) {
        throw const DeckLoadException('not an audio file');
      }
      await _player.open(Media(path, start: start), play: false);
      // open() resets the duration; it is known again once the file loaded.
      final watch = Stopwatch()..start();
      while (!opening.isCompleted) {
        if (_player.state.duration > Duration.zero) {
          opening.complete();
          break;
        }
        if (watch.elapsed > _openTimeout) {
          opening.completeError(const DeckLoadException('timeout'));
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await opening.future;
      if (generation != _generation) throw const DeckInterrupted();
      _loaded = true;
    } finally {
      if (identical(_opening, opening)) _opening = null;
      _emit();
    }
  }

  /// Whether [path] begins like a text file rather than audio. A playlist,
  /// EDL or CUE sheet saved under an audio name would make mpv open what it
  /// points at, a network share or a URL included. Those are all text,
  /// while every audio container has binary bytes near its start.
  /// (`access-references=no` would stop mpv too, but media_kit hands each
  /// file to mpv through a playlist of its own.)
  @visibleForTesting
  static Future<bool> startsAsText(String path) async {
    final file = await File(path).open();
    try {
      final head = await file.read(512);
      if (head.isEmpty) return false;
      var start = 0;
      if (head.length >= 3 &&
          head[0] == 0xEF &&
          head[1] == 0xBB &&
          head[2] == 0xBF) {
        start = 3;
      }
      try {
        // A UTF-8 sequence cut off at the end of the sample is still text.
        const Utf8Decoder().convert(
          head.sublist(start, head.length - (head.length == 512 ? 3 : 0)),
        );
      } on FormatException {
        return false;
      }
      for (var i = start; i < head.length; i++) {
        final b = head[i];
        if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return false;
        if (b == 0x7F) return false;
      }
      return true;
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    _generation++;
    final opening = _opening;
    if (opening != null && !opening.isCompleted) {
      opening.completeError(const DeckInterrupted());
    }
    _loaded = false;
    await _player.stop();
    _emit();
  }

  /// mpv's software volume is cubic, so the amplitude gain is applied as
  /// its cube root; the user's volume keeps the mapping it always had.
  @override
  Future<void> setLevel(double volume, {double gain = 1}) async {
    final level =
        100 * volume.clamp(0.0, 1.0) * math.pow(gain.clamp(0.0, 1.0), 1 / 3);
    if ((level - _level).abs() < 0.05) return;
    _level = level;
    await _player.setVolume(level);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if ((speed - _speed).abs() < 1e-5) return;
    _speed = speed;
    await _player.setRate(speed);
  }

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
