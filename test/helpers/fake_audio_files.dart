import 'dart:async';

import 'package:noir/features/playback/domain/audio_source_provider.dart';
import 'package:noir/shared/models/media.dart';

/// Scriptable [AudioFileProvider]: answers from [files] (keyed by track
/// uri) and records prefetch hints.
class FakeAudioFiles implements AudioFileProvider {
  final files = <String, String>{};
  final prefetched = <List<String>>[];

  /// When set, lookups throw this instead of answering.
  Exception? error;

  /// When set, lookups wait for it before answering.
  Completer<void>? gate;

  @override
  Future<String?> cachedFile(Track track) async {
    if (error case final e?) throw e;
    await gate?.future;
    return files[track.uri];
  }

  @override
  void prefetch(List<Track> next) =>
      prefetched.add([for (final t in next) t.title]);

  @override
  Stream<AudioFileStatus> get status => const Stream.empty();
}
