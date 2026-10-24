import 'package:flutter/foundation.dart';
import 'package:noir/shared/models/media.dart';

/// Optional extension point: supplies a local audio file for a track that
/// otherwise plays through a remote player, so it can play on the local
/// engine instead (full seek, crossfade, background playback).
///
/// NOIR ships with [NoAudioFiles], which never supplies anything.
abstract interface class AudioFileProvider {
  /// A playable local file for [track], or null when there is none right
  /// now. Consulted on every load, so it must answer quickly.
  Future<String?> cachedFile(Track track);

  /// Hint: [next] is likely to play soon, most likely first.
  void prefetch(List<Track> next);

  Stream<AudioFileStatus> get status;
}

/// What an [AudioFileProvider] is doing, for display.
@immutable
class AudioFileStatus {
  const AudioFileStatus({this.busy = false, this.message});

  static const idle = AudioFileStatus();

  final bool busy;

  /// Short user-facing note, e.g. the last problem; null when all is well.
  final String? message;
}

/// The default: supplies no files, so every track plays as it always has.
class NoAudioFiles implements AudioFileProvider {
  const NoAudioFiles();

  @override
  Future<String?> cachedFile(Track track) async => null;

  @override
  void prefetch(List<Track> next) {}

  @override
  Stream<AudioFileStatus> get status => const Stream.empty();
}
