import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:noir/integrations/local_audio/mpv_deck.dart';

import '../helpers/wav.dart';

/// The libmpv a Windows build of this checkout bundles; the test skips
/// without it.
String? _libmpv() {
  final env = Platform.environment['LIBMPV_LIBRARY_PATH'];
  if (env != null && File(env).existsSync()) return env;
  for (final mode in ['Release', 'Debug', 'Profile']) {
    final dll = File('build/windows/x64/runner/$mode/libmpv-2.dll');
    if (dll.existsSync()) return dll.absolute.path;
  }
  return null;
}

// A library file may be a playlist, EDL or CUE sheet under an audio name.
// Playing it must not open what it points at (a share, a URL).
void main() {
  final libmpv = _libmpv();

  test(
    'playing a file does not follow references inside it',
    skip: libmpv == null ? 'libmpv not available' : null,
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized(libmpv: libmpv);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final hits = <String>[];
      server.listen((r) {
        hits.add(r.uri.path);
        r.response.statusCode = HttpStatus.notFound;
        unawaited(r.response.close());
      });
      final url = 'http://127.0.0.1:${server.port}';
      final dir = Directory.systemTemp.createTempSync('noir_deck_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final deck = MpvDeck();
      addTearDown(deck.dispose);
      final files = {
        'edl.mp3': '# mpv EDL v0\n$url/edl.mp3\n',
        'cue.mp3':
            'FILE "$url/cue.mp3" MP3\nTRACK 01 AUDIO\n  INDEX 01 00:00:00\n',
        'm3u.mp3': '#EXTM3U\n$url/m3u.mp3\n',
      };
      for (final MapEntry(:key, :value) in files.entries) {
        final file = File('${dir.path}/$key')..writeAsStringSync(value);
        try {
          await deck.open(file.path).timeout(const Duration(seconds: 5));
        } on Object {
          // Not audio: failing to load is the expected outcome.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(hits, isEmpty);

      // A real audio file still opens.
      final tone = File('${dir.path}/tone.wav');
      writeSineWav(tone);
      await deck.open(tone.path);
      expect(deck.duration, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  group('text sniffing', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('noir_sniff_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<bool> sniff(List<int> bytes) {
      final file = File('${dir.path}/x.mp3')..writeAsBytesSync(bytes);
      return MpvDeck.startsAsText(file.path);
    }

    test('playlists, EDL and CUE sheets are text', () async {
      for (final body in [
        '#EXTM3U\nhttp://x/a.mp3\n',
        '# mpv EDL v0\n\\\\host\\share\\a.mp3\n',
        'FILE "a.mp3" MP3\r\nTRACK 01 AUDIO\r\n',
        '\uFEFF[playlist]\nFile1=http://x/a\n',
        'ünïcödé ' * 100,
      ]) {
        expect(await sniff(utf8.encode(body)), isTrue, reason: body);
      }
    });

    test('audio is not', () async {
      final tone = File('${dir.path}/tone.wav');
      writeSineWav(tone);
      expect(await MpvDeck.startsAsText(tone.path), isFalse);
      // ID3 tag, a bare MPEG frame, FLAC, Ogg, MP4.
      for (final head in [
        [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00],
        [0xFF, 0xFB, 0x90, 0x64, 0x41, 0x42, 0x43, 0x44],
        [...ascii.encode('fLaC'), 0x00, 0x00, 0x00, 0x22],
        [...ascii.encode('OggS'), 0x00, 0x02],
        [0x00, 0x00, 0x00, 0x20, ...ascii.encode('ftypM4A ')],
      ]) {
        expect(await sniff([...head, ...List.filled(64, 0x41)]), isFalse);
      }
      expect(await sniff([]), isFalse);
    });
  });
}
