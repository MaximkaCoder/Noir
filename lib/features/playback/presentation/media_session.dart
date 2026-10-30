import 'dart:async';

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

/// Connects NOIR's single playback controller to the OS media session
/// (Android notification / lock screen, iOS & macOS Now Playing). The
/// session only mirrors state and forwards commands — it never plays audio.
Future<void> startMediaSession(ProviderContainer container) async {
  try {
    await svc.AudioService.init(
      builder: () => _NoirAudioHandler(container),
      config: const svc.AudioServiceConfig(
        androidNotificationChannelId: 'app.noir.player.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
      ),
    );
  } on Object catch (e) {
    // Playback still works in-app without system media controls.
    debugPrint('Media session unavailable: ${e.runtimeType}');
  }
}

class _NoirAudioHandler extends svc.BaseAudioHandler with svc.SeekHandler {
  _NoirAudioHandler(this._container) {
    _container.listen<PlaybackState>(
      playbackProvider,
      (_, next) => _publish(next),
      fireImmediately: true,
    );
    // Re-anchor the OS position after seeks; it extrapolates in between.
    _positionSub = _container
        .read(playbackEngineProvider)
        .position
        .listen(_onPosition);
  }

  final ProviderContainer _container;
  late final StreamSubscription<Duration> _positionSub;

  /// Album art lookup for the current YouTube track.
  ProviderSubscription<ResolvedArt?>? _artSub;
  String? _artVideoId;
  Duration _lastPublished = Duration.zero;
  DateTime _lastPublishedAt = DateTime.now();

  PlaybackController get _ctrl => _container.read(playbackProvider.notifier);

  void _onPosition(Duration position) {
    final s = _container.read(playbackProvider);
    final expected = s.isPlaying
        ? _lastPublished + DateTime.now().difference(_lastPublishedAt)
        : _lastPublished;
    if ((position - expected).abs() > const Duration(seconds: 2)) _publish(s);
  }

  void _publish(PlaybackState s) {
    final track = s.current?.track;
    if (track == null) {
      mediaItem.add(null);
      playbackState.add(svc.PlaybackState());
      return;
    }
    final item = svc.MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      artUri: _artFor(track),
    );
    if (mediaItem.value != item) mediaItem.add(item);

    final position = _container.read(playbackEngineProvider).currentPosition;
    _lastPublished = position;
    _lastPublishedAt = DateTime.now();
    playbackState.add(
      svc.PlaybackState(
        controls: [
          if (s.capabilities.canSkip) svc.MediaControl.skipToPrevious,
          if (s.isPlaying) svc.MediaControl.pause else svc.MediaControl.play,
          if (s.capabilities.canSkip) svc.MediaControl.skipToNext,
        ],
        systemActions: {if (s.capabilities.canSeek) svc.MediaAction.seek},
        androidCompactActionIndices: s.capabilities.canSkip
            ? const [0, 1, 2]
            : const [0],
        processingState: switch (s.status) {
          PlaybackStatus.idle => svc.AudioProcessingState.idle,
          PlaybackStatus.loading => svc.AudioProcessingState.loading,
          PlaybackStatus.buffering => svc.AudioProcessingState.buffering,
          PlaybackStatus.playing ||
          PlaybackStatus.paused => svc.AudioProcessingState.ready,
          PlaybackStatus.completed => svc.AudioProcessingState.completed,
          PlaybackStatus.error ||
          PlaybackStatus.unavailable => svc.AudioProcessingState.error,
        },
        playing: s.isPlaying,
        updatePosition: position,
        queueIndex: s.index,
      ),
    );
  }

  /// YouTube: the square album art (544 px) once it is found, the video
  /// thumbnail until then; the art file of a local track.
  Uri? _artFor(Track track) {
    final videoId = track.source == MediaSource.youtube ? track.uri : null;
    if (videoId != _artVideoId) {
      _artSub?.close();
      _artSub = null;
      _artVideoId = videoId;
      if (videoId != null) {
        _artSub = _container.listen<ResolvedArt?>(
          resolvedArtProvider(videoId),
          (_, _) => _publish(_container.read(playbackProvider)),
        );
      }
    }
    final art = _artSub?.read()?.squareUrl(544) ?? track.artwork;
    if (art == null) return null;
    return isRemoteImage(art) ? Uri.tryParse(art) : Uri.file(art);
  }

  @override
  Future<void> play() => _ctrl.resume();

  @override
  Future<void> pause() => _ctrl.pause();

  @override
  Future<void> skipToNext() => _ctrl.next();

  @override
  Future<void> skipToPrevious() => _ctrl.previous();

  @override
  Future<void> seek(Duration position) => _ctrl.seek(position);

  @override
  Future<void> stop() async {
    await _ctrl.pause();
    await _positionSub.cancel();
    _artSub?.close();
    await super.stop();
  }
}
