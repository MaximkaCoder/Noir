import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:noir/shared/models/media.dart';

part 'playback.freezed.dart';

enum PlaybackStatus {
  idle,
  loading,
  playing,
  paused,
  buffering,
  completed,
  error,

  /// The active source cannot play this item at all.
  unavailable,
}

enum RepeatMode { off, all, one }

/// What the active playback engine can actually do. The UI hides controls
/// whose flag is false instead of showing inert buttons.
@freezed
abstract class PlaybackCapabilities with _$PlaybackCapabilities {
  const factory PlaybackCapabilities({
    @Default(false) bool canSeek,
    @Default(false) bool canSkip,
    @Default(false) bool canControlVolume,
    @Default(false) bool canShuffle,
    @Default(false) bool canRepeat,
    @Default(false) bool canCrossfade,
    @Default(false) bool supportsBackgroundPlayback,
    @Default(false) bool supportsQueueMutation,

    /// True for embedded video players that must stay visible (YouTube).
    @Default(false) bool requiresVisiblePlayer,
  }) = _PlaybackCapabilities;

  static const none = PlaybackCapabilities();
}

/// One entry in NOIR's local queue. [uid] is unique per insertion so the
/// same track can appear twice and still have a stable widget key.
@freezed
abstract class QueueItem with _$QueueItem {
  const factory QueueItem({required int uid, required Track track}) =
      _QueueItem;
}

@freezed
abstract class PlaybackState with _$PlaybackState {
  const factory PlaybackState({
    @Default(PlaybackStatus.idle) PlaybackStatus status,
    @Default(<QueueItem>[]) List<QueueItem> queue,
    int? index,
    @Default(false) bool shuffle,
    @Default(RepeatMode.off) RepeatMode repeat,
    @Default(1.0) double volume,
    @Default(PlaybackCapabilities.none) PlaybackCapabilities capabilities,

    /// User-facing explanation when [status] is error or unavailable.
    String? message,
  }) = _PlaybackState;

  const PlaybackState._();

  QueueItem? get current =>
      index != null && index! >= 0 && index! < queue.length
      ? queue[index!]
      : null;

  List<QueueItem> get upcoming =>
      index == null ? queue : queue.sublist(index! + 1);

  bool get isPlaying =>
      status == PlaybackStatus.playing || status == PlaybackStatus.buffering;

  bool get hasNext =>
      index != null && (index! + 1 < queue.length || repeat == RepeatMode.all);

  bool get hasPrevious => index != null && index! > 0;
}
