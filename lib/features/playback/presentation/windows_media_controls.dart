import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/features/playback/application/media_commands.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Implemented by the Windows runner (windows/runner/smtc_bridge.cpp).
const smtcChannel = MethodChannel('noir/smtc');

/// Connects NOIR to Windows' System Media Transport Controls: the media
/// flyout shows the current track, and media keys work while the window is
/// unfocused or minimized. Like the mobile media session it only mirrors
/// state and forwards commands. Never throws: without SMTC, playback simply
/// works in-app only.
void startWindowsMediaControls(ProviderContainer container) {
  try {
    WindowsMediaControls(container).start();
  } on Object catch (e) {
    debugPrint('Windows media controls unavailable: $e');
  }
}

class WindowsMediaControls {
  WindowsMediaControls(
    this._container, {
    this._channel = smtcChannel,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// SMTC does not advance the position itself for every consumer, so it
  /// is refreshed this often while playing (Microsoft suggests ~5 s).
  static const heartbeat = Duration(seconds: 5);

  /// A position further than this from the expected one means a seek.
  static const seekTolerance = Duration(seconds: 2);

  final ProviderContainer _container;
  final MethodChannel _channel;
  final DateTime Function() _clock;

  final _subscriptions = <StreamSubscription<Object?>>[];
  ProviderSubscription<PlaybackState>? _stateSub;

  /// Album art lookup for the current YouTube track.
  ProviderSubscription<ResolvedArt?>? _artSub;
  String? _artVideoId;
  bool _failed = false;

  Map<String, Object?>? _metadata;
  Map<String, Object?>? _playback;
  ({String trackId, int durationMs, bool playing})? _timelineKey;
  Duration _timelinePosition = Duration.zero;
  DateTime _timelineAt = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    _channel.setMethodCallHandler(_onNativeCall);
    final engine = _container.read(playbackEngineProvider);
    _subscriptions
      ..add(engine.position.listen((_) => _syncTimeline()))
      ..add(engine.duration.listen((_) => _syncTimeline()));
    _stateSub = _container.listen<PlaybackState>(
      playbackProvider,
      (_, next) => _sync(next),
      fireImmediately: true,
    );
  }

  void dispose() {
    _stateSub?.close();
    _artSub?.close();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _channel.setMethodCallHandler(null);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'button') return;
    final command = switch (call.arguments) {
      'play' => MediaCommand.play,
      'pause' => MediaCommand.pause,
      'next' => MediaCommand.next,
      'previous' => MediaCommand.previous,
      'stop' => MediaCommand.stop,
      _ => null,
    };
    if (command == null) return;
    await _container
        .read(mediaCommandsProvider)
        .handle(command, MediaCommandSource.system);
  }

  void _sync(PlaybackState s) {
    final track = s.current?.track;
    if (track == null) {
      if (_metadata != null) {
        _metadata = _playback = _timelineKey = null;
        _send('clear');
      }
      return;
    }

    final metadata = <String, Object?>{
      'title': track.title,
      'artist': track.artist ?? '',
      'album': track.album ?? '',
      // Local file path or https image; the runner handles both.
      'artwork': _artworkFor(track),
    };
    if (!mapEquals(metadata, _metadata)) {
      _metadata = metadata;
      _send('metadata', metadata);
    }

    final playback = <String, Object?>{
      'status': switch (s.status) {
        PlaybackStatus.playing || PlaybackStatus.buffering => 'playing',
        PlaybackStatus.paused || PlaybackStatus.completed => 'paused',
        PlaybackStatus.loading => 'changing',
        PlaybackStatus.idle ||
        PlaybackStatus.error ||
        PlaybackStatus.unavailable => 'stopped',
      },
      'canPlay': true,
      'canPause': true,
      'canNext': s.capabilities.canSkip && s.hasNext,
      // "Previous" restarts the current track when there is none before it.
      'canPrevious': s.capabilities.canSkip,
      'canStop': true,
    };
    if (!mapEquals(playback, _playback)) {
      _playback = playback;
      _send('playback', playback);
    }
    _syncTimeline();
  }

  /// YouTube: the square album art (544 px) once it is found, the video
  /// thumbnail until then.
  String _artworkFor(Track track) {
    final videoId = track.source == MediaSource.youtube ? track.uri : null;
    if (videoId != _artVideoId) {
      _artSub?.close();
      _artSub = null;
      _artVideoId = videoId;
      if (videoId != null) {
        _artSub = _container.listen<ResolvedArt?>(
          resolvedArtProvider(videoId),
          (_, _) => _sync(_container.read(playbackProvider)),
        );
      }
    }
    return _artSub?.read()?.squareUrl(544) ?? track.artwork ?? '';
  }

  /// Sends the timeline when the track, duration or play state changed,
  /// after a seek, and every [heartbeat] while playing — never on every
  /// position tick.
  void _syncTimeline() {
    final s = _container.read(playbackProvider);
    final track = s.current?.track;
    if (track == null || _metadata == null) return;
    final engine = _container.read(playbackEngineProvider);
    final position = engine.currentPosition;
    final duration = engine.currentDuration ?? track.duration ?? Duration.zero;
    final key = (
      trackId: track.id,
      durationMs: duration.inMilliseconds,
      playing: s.isPlaying,
    );
    final now = _clock();
    final elapsed = now.difference(_timelineAt);

    if (key == _timelineKey) {
      final expected = key.playing
          ? _timelinePosition + elapsed
          : _timelinePosition;
      final seeked = (position - expected).abs() > seekTolerance;
      final due = key.playing && elapsed >= heartbeat;
      if (!seeked && !due) return;
      if (position == _timelinePosition) return;
    }
    _timelineKey = key;
    _timelinePosition = position;
    _timelineAt = now;
    _send('timeline', {
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
  }

  void _send(String method, [Map<String, Object?>? arguments]) {
    if (_failed) return;
    unawaited(_invoke(method, arguments));
  }

  Future<void> _invoke(String method, Map<String, Object?>? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object catch (e) {
      // One failure means SMTC is unusable here; stop instead of spamming.
      if (_failed) return;
      _failed = true;
      debugPrint('Windows media controls unavailable: $e');
    }
  }
}
