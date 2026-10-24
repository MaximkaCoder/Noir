import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

/// Plays YouTube videos through the official IFrame Player API inside
/// WebView2 (Windows).
///
/// The player page is served from `https://app.noir.player/` via WebView2
/// virtual-host mapping, so the embed carries a real origin/Referer
/// (required since 2025; otherwise Error 153). See docs/spikes/yt-embed.md.
///
/// Policy constraints this engine honors: the player must stay visible
/// (≥200×200) while playing — the UI pauses it when hidden — there is no
/// background or audio-only playback, and the player is never modified
/// beyond documented parameters.
class YouTubeEmbedEngine implements PlaybackEngine {
  YouTubeEmbedEngine({required this._pageDir});

  static const host = 'app.noir.player';

  static const _caps = PlaybackCapabilities(
    canSeek: true,
    canSkip: true,
    canControlVolume: true,
    canShuffle: true,
    canRepeat: true,
    supportsQueueMutation: true,
    requiresVisiblePlayer: true,
  );

  static bool get isSupported => Platform.isWindows;

  final Directory _pageDir;
  final controller = WebviewController();

  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  /// True once the WebView and the IFrame API are ready.
  final ready = ValueNotifier<bool>(false);
  Completer<void>? _initializing;
  StreamSubscription<dynamic>? _messages;

  Duration _currentPosition = Duration.zero;
  Duration? _currentDuration;
  PlaybackStatus? _lastStatus;
  double _volume = 1;

  @override
  PlaybackCapabilities get capabilities => _caps;
  @override
  Stream<EngineEvent> get events => _events.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Duration get currentPosition => _currentPosition;
  @override
  Stream<Duration?> get duration => _duration.stream;
  @override
  Duration? get currentDuration => _currentDuration;

  Future<void> _ensureReady() {
    final init = _initializing;
    if (init != null) return init.future;
    final completer = _initializing = Completer<void>();
    unawaited(_init(completer));
    return completer.future;
  }

  Future<void> _init(Completer<void> done) async {
    try {
      try {
        // Playback starts from NOIR's own buttons, which are outside the
        // web page, so WebView2 would otherwise treat it as autoplay.
        await WebviewController.initializeEnvironment(
          additionalArguments: '--autoplay-policy=no-user-gesture-required',
        );
      } on Object {
        // Environment already initialized (e.g. hot restart).
      }
      await _pageDir.create(recursive: true);
      await File(p.join(_pageDir.path, 'player.html')).writeAsString(_page);
      await controller.initialize();
      await controller.setBackgroundColor(Colors.black);
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      _messages = controller.webMessage.listen(_onMessage);
      await controller.addVirtualHostNameMapping(
        host,
        _pageDir.path,
        WebviewHostResourceAccessKind.allow,
      );
      final apiReady = Completer<void>();
      void onReady() {
        if (ready.value && !apiReady.isCompleted) apiReady.complete();
      }

      ready.addListener(onReady);
      await controller.loadUrl('https://$host/player.html');
      await apiReady.future.timeout(const Duration(seconds: 20));
      ready.removeListener(onReady);
      done.complete();
    } on Object catch (e) {
      debugPrint('YouTube player failed to start: ${e.runtimeType}');
      _initializing = null;
      done.completeError(e);
    }
  }

  void _onMessage(dynamic raw) {
    final Map<String, Object?> m;
    try {
      m = jsonDecode(raw as String) as Map<String, Object?>;
    } on Object {
      return;
    }
    switch (m['event']) {
      case 'ready':
        ready.value = true;
      case 'time':
        _currentPosition = _seconds(m['t']);
        final d = _seconds(m['d']);
        if (d > Duration.zero && d != _currentDuration) {
          _currentDuration = d;
          _duration.add(d);
        }
        _position.add(_currentPosition);
      case 'state':
        final status = switch (m['data']) {
          0 => PlaybackStatus.completed,
          1 => PlaybackStatus.playing,
          2 => PlaybackStatus.paused,
          3 => PlaybackStatus.buffering,
          5 => PlaybackStatus.paused, // cued
          _ => PlaybackStatus.loading, // -1 unstarted
        };
        if (status == _lastStatus) return;
        _lastStatus = status;
        _events.add(
          status == PlaybackStatus.completed
              ? const EngineCompleted()
              : EngineStatusChanged(status),
        );
      case 'error':
        _events.add(EngineFailed(_errorMessage(m['data'])));
    }
  }

  static Duration _seconds(Object? v) =>
      Duration(milliseconds: (((v as num?) ?? 0) * 1000).round());

  static String _errorMessage(Object? code) => switch (code) {
    101 || 150 =>
      "The owner doesn't allow this video to be played outside YouTube. "
          'Open it in YouTube Music instead.',
    100 => 'This video is no longer available.',
    2 => "This video link isn't valid.",
    153 => "YouTube didn't accept NOIR's player identification.",
    _ => "This video can't be played right now.",
  };

  Future<void> _js(String script) async {
    await _ensureReady();
    await controller.executeScript(script);
  }

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async {
    try {
      await _ensureReady();
    } on Object {
      _events.add(
        const EngineFailed(
          "The YouTube player couldn't start. Check that Microsoft Edge "
          'WebView2 is installed and that you are online.',
        ),
      );
      return false;
    }
    _lastStatus = null;
    _currentPosition = start;
    _currentDuration = track.duration;
    // Only video ids from the YouTube API reach here; encode defensively.
    await _js(
      'noir.cue(${jsonEncode(track.uri)}, ${start.inMilliseconds / 1000})',
    );
    await _js('noir.volume(${(_volume * 100).round()})');
    return true;
  }

  @override
  Future<void> play() => _js('noir.play()');

  @override
  Future<void> pause() async {
    if (ready.value) await _js('noir.pause()');
  }

  @override
  Future<void> seek(Duration position) =>
      _js('noir.seek(${position.inMilliseconds / 1000})');

  @override
  Future<void> stop() async {
    if (ready.value) await _js('noir.stop()');
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    if (ready.value) await _js('noir.volume(${(_volume * 100).round()})');
  }

  /// Not supported: two YouTube players at once are against the RMF.
  @override
  Future<void> crossfadeTo(Track next, Duration fade) async {
    if (await load(next)) await play();
  }

  @override
  Future<void> dispose() async {
    await _messages?.cancel();
    await controller.dispose();
    await _events.close();
    await _position.close();
    await _duration.close();
  }

  static const _page = '''
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
</head><body>
<div id="player"></div>
<script>
  function send(m){ window.chrome.webview.postMessage(JSON.stringify(m)); }
  var player = null, timer = null;
  var tag = document.createElement('script');
  tag.src = 'https://www.youtube.com/iframe_api';
  document.head.appendChild(tag);
  function tick(){
    if (player && player.getCurrentTime) {
      send({event:'time', t: player.getCurrentTime(), d: player.getDuration()});
    }
  }
  function onYouTubeIframeAPIReady() {
    player = new YT.Player('player', {
      width: '100%', height: '100%',
      playerVars: { playsinline: 1, controls: 0, rel: 0,
                    origin: 'https://app.noir.player' },
      events: {
        onReady: function(){ send({event:'ready'}); },
        onStateChange: function(e){
          send({event:'state', data: e.data});
          clearInterval(timer);
          if (e.data === 1) timer = setInterval(tick, 250);
          tick();
        },
        onError: function(e){ send({event:'error', data: e.data}); }
      }
    });
  }
  window.noir = {
    cue: function(id, s){ player.cueVideoById({videoId: id, startSeconds: s}); },
    play: function(){ player.playVideo(); },
    pause: function(){ player.pauseVideo(); },
    stop: function(){ player.stopVideo(); },
    seek: function(s){ player.seekTo(s, true); tick(); },
    volume: function(v){ player.setVolume(v); }
  };
</script>
</body></html>
''';
}
