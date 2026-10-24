// Spike: can the official YouTube IFrame Player API run inside WebView2 on
// Windows with a valid embedder identity (no Error 153)?
//
// MODE=mapped  -> page served from https://app.noir.player/ via WebView2
//                 virtual host mapping (expected: works).
// MODE=string  -> same page loaded with NavigateToString, no origin
//                 (control: expected Error 153).
//
// Every player event is printed as `SPIKE: ...`; the app exits after 30 s.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

const _mode = String.fromEnvironment('MODE', defaultValue: 'mapped');
const _videoId = String.fromEnvironment('VIDEO', defaultValue: 'dQw4w9WgXcQ');
const _host = 'app.noir.player';

String _playerHtml(String origin) => '''
<!doctype html>
<html><head><meta charset="utf-8">
<style>html,body{margin:0;background:#090909;overflow:hidden}</style>
</head><body>
<div id="player"></div>
<script>
  function send(m){ window.chrome.webview.postMessage(JSON.stringify(m)); }
  send({event:'page', origin: location.origin, href: location.href});
  var tag = document.createElement('script');
  tag.src = 'https://www.youtube.com/iframe_api';
  document.head.appendChild(tag);
  var player;
  function onYouTubeIframeAPIReady() {
    player = new YT.Player('player', {
      width: 480, height: 270, videoId: '$_videoId',
      playerVars: { playsinline: 1, controls: 0, rel: 0 $origin },
      events: {
        onReady: function(){ send({event:'ready'}); },
        onStateChange: function(e){
          send({event:'state', data:e.data, t: player.getCurrentTime()});
          if (e.data === 5 && window.wantPlay) player.playVideo();
          if (e.data === 1) window.wantPlay = false;
        },
        onError: function(e){ send({event:'error', data:e.data}); }
      }
    });
    setInterval(function(){
      if (player && player.getCurrentTime) send({event:'time', t: player.getCurrentTime()});
    }, 3000);
  }
</script>
</body></html>
''';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  final _controller = WebviewController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
    Timer(const Duration(seconds: 30), () {
      stdout.writeln('SPIKE: done');
      exit(0);
    });
  }

  Future<void> _init() async {
    stdout.writeln('SPIKE: mode=$_mode webview=${await WebviewController.getWebViewVersion()}');
    if (const bool.fromEnvironment('FLAG')) {
      await WebviewController.initializeEnvironment(
          additionalArguments: '--autoplay-policy=no-user-gesture-required');
      stdout.writeln('SPIKE: flag set');
    }
    await _controller.initialize();
    _controller.webMessage.listen((m) => stdout.writeln('SPIKE: $m'));
    if (_mode == 'mapped') {
      final dir = Directory('${Directory.systemTemp.path}\\noir_yt_spike')
        ..createSync(recursive: true);
      File('${dir.path}\\player.html')
          .writeAsStringSync(_playerHtml(", origin: 'https://$_host'"));
      await _controller.addVirtualHostNameMapping(
          _host, dir.path, WebviewHostResourceAccessKind.allow);
      await _controller.loadUrl('https://$_host/player.html');
    } else {
      await _controller.loadStringContent(_playerHtml(''));
    }
    setState(() => _ready = true);
    // Like NOIR: cue, then play from outside the page (no user gesture).
    Timer(const Duration(seconds: 6), () async {
      await _controller.executeScript("player.cueVideoById({videoId:'$_videoId',startSeconds:0})");
      await _controller.executeScript('window.wantPlay = true; player.playVideo()');
      stdout.writeln('SPIKE: play sent');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF090909),
        body: Center(
          child: SizedBox(
            width: 480,
            height: 270,
            child: _ready ? Webview(_controller) : const SizedBox(),
          ),
        ),
      ),
    );
  }
}
