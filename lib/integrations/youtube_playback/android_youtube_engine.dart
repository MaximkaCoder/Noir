import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/integrations/youtube_playback/embedded_player.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Plays YouTube videos through the official IFrame Player API inside the
/// Android System WebView: tracks start at once, before their audio file
/// is there (the Windows counterpart is `YouTubeEmbedEngine`).
///
/// The player page is loaded with `https://app.noir.player/` as its base
/// URL, so the embed carries a real origin and Referer (otherwise YouTube
/// answers with Error 153).
class AndroidYouTubeEngine implements EmbeddedYouTubePlayer {
  static const _origin = 'https://app.noir.player';

  static const _caps = PlaybackCapabilities(
    canSeek: true,
    canSkip: true,
    canControlVolume: true,
    canShuffle: true,
    canRepeat: true,
    supportsQueueMutation: true,
    requiresVisiblePlayer: true,
  );

  static bool get isSupported => Platform.isAndroid;

  late final WebViewController _controller;

  final _events = StreamController<EngineEvent>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();

  @override
  final ValueNotifier<bool> ready = ValueNotifier(false);
  Completer<void>? _initializing;

  Duration _currentPosition = Duration.zero;
  Duration? _currentDuration;
  PlaybackStatus? _lastStatus;
  Track? _track;
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
      final controller = WebViewController();
      final android = controller.platform;
      if (android is AndroidWebViewController) {
        // Playback starts from NOIR's own buttons, outside the web page.
        await android.setMediaPlaybackRequiresUserGesture(false);
      }
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.black);
      await controller.addJavaScriptChannel(
        'NoirChannel',
        onMessageReceived: (m) => _onMessage(m.message),
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          // The page itself never goes anywhere else; the YouTube frame
          // inside it may load what it needs.
          onNavigationRequest: (request) =>
              !request.isMainFrame || request.url.startsWith('$_origin/')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
      _controller = controller;
      final apiReady = Completer<void>();
      void onReady() {
        if (ready.value && !apiReady.isCompleted) apiReady.complete();
      }

      ready.addListener(onReady);
      await controller.loadHtmlString(_page, baseUrl: '$_origin/');
      await apiReady.future.timeout(const Duration(seconds: 20));
      ready.removeListener(onReady);
      done.complete();
    } on Object catch (e) {
      debugPrint('YouTube player failed to start: ${e.runtimeType}');
      _initializing = null;
      done.completeError(e);
    }
  }

  void _onMessage(String raw) {
    final Map<String, Object?> m;
    try {
      m = jsonDecode(raw) as Map<String, Object?>;
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
        final code = m['data'];
        _events.add(
          EngineFailed(
            _errorMessage(code),
            unplayable: const {2, 100, 101, 150}.contains(code) ? _track : null,
          ),
        );
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
    await _controller.runJavaScript(script);
  }

  @override
  Widget buildView(BuildContext context) =>
      WebViewWidget(controller: _controller);

  @override
  Future<bool> load(Track track, {Duration start = Duration.zero}) async {
    try {
      await _ensureReady();
    } on Object {
      _events.add(
        const EngineFailed(
          "The YouTube player couldn't start. Check that you are online.",
        ),
      );
      return false;
    }
    _lastStatus = null;
    _track = track;
    _currentPosition = start;
    _currentDuration = track.duration;
    // Only video ids from YouTube reach here; encode defensively.
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
  function send(m){ NoirChannel.postMessage(JSON.stringify(m)); }
  var player = null, timer = null;
  // playVideo() right after cueVideoById() is lost when the cue finishes
  // later, so a pending play is retried then; the first play() of a freshly
  // cued video loads it with autoplay instead (see the Windows engine).
  var wantPlay = false, cued = null;
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
          if (e.data === 5 && wantPlay) { player.playVideo(); return; }
          if (e.data === 1) { wantPlay = false; cued = null; }
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
    cue: function(id, s){
      wantPlay = false; cued = {videoId: id, startSeconds: s};
      player.cueVideoById(cued);
    },
    play: function(){
      wantPlay = true;
      if (cued) { var c = cued; cued = null; player.loadVideoById(c); }
      else player.playVideo();
    },
    pause: function(){ wantPlay = false; player.pauseVideo(); },
    stop: function(){ wantPlay = false; player.stopVideo(); },
    seek: function(s){ if (cued) cued.startSeconds = s; player.seekTo(s, true); tick(); },
    volume: function(v){ player.setVolume(v); }
  };
</script>
</body></html>
''';
}
