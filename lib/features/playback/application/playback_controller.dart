import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/integrations/local_audio/local_audio_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  final engine = LocalAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

final playbackProvider = NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);

/// Position is a separate stream so only progress widgets rebuild on ticks.
final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(playbackEngineProvider).position,
);

final durationProvider = StreamProvider<Duration?>(
  (ref) => ref.watch(playbackEngineProvider).duration,
);

/// Single source of truth for what NOIR is playing. Owns NOIR's local queue,
/// which is never synchronized to any provider playlist.
class PlaybackController extends Notifier<PlaybackState> {
  static const sessionKey = 'playback_session';
  static const _restartThreshold = Duration(seconds: 3);
  static const _sessionSaveInterval = Duration(seconds: 10);

  late PlaybackEngine _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  final _random = Random();
  int _nextUid = 0;

  /// Queue order before shuffle was enabled, to restore it afterwards.
  List<int>? _unshuffledUids;
  bool _crossfading = false;
  DateTime _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);

  AppSettings get _settings => ref.read(settingsProvider);

  @override
  PlaybackState build() {
    _engine = ref.watch(playbackEngineProvider);
    _subs
      ..add(_engine.events.listen(_onEngineEvent))
      ..add(_engine.position.listen(_onPosition));
    ref.onDispose(() {
      for (final s in _subs) {
        unawaited(s.cancel());
      }
      _subs.clear();
    });
    final volume = _settings.defaultVolume;
    unawaited(_engine.setVolume(volume));
    return PlaybackState(volume: volume, capabilities: _engine.capabilities);
  }

  // ---------------------------------------------------------------- queue --

  /// Plays [tracks] starting at [startIndex], honoring the "play behavior"
  /// setting (whole list vs. single track).
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    final selection = _settings.playBehavior == PlayBehavior.playSingle
        ? [tracks[startIndex]]
        : tracks;
    final start = _settings.playBehavior == PlayBehavior.playSingle
        ? 0
        : startIndex;
    _unshuffledUids = null;
    state = state.copyWith(
      queue: [for (final t in selection) _item(t)],
      index: start,
      shuffle: false,
      message: null,
    );
    await _loadCurrent(autoplay: true);
  }

  /// Plays [tracks] in random order.
  Future<void> shuffleTracks(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final shuffled = [...tracks]..shuffle(_random);
    _unshuffledUids = null;
    state = state.copyWith(
      queue: [for (final t in shuffled) _item(t)],
      index: 0,
      shuffle: false,
      message: null,
    );
    await _loadCurrent(autoplay: true);
  }

  void playNext(Track track) {
    final insertAt = state.index == null ? 0 : state.index! + 1;
    _setQueue([...state.queue]..insert(insertAt, _item(track)));
    if (state.index == null) unawaited(_startAt(0));
  }

  void addToQueue(List<Track> tracks) {
    final wasEmpty = state.index == null;
    _setQueue([...state.queue, for (final t in tracks) _item(t)]);
    if (wasEmpty && tracks.isNotEmpty) unawaited(_startAt(0));
  }

  Future<void> jumpTo(int index) => _startAt(index);

  void removeAt(int index) {
    if (index == state.index) return; // The current item cannot be removed.
    final queue = [...state.queue]..removeAt(index);
    final current = state.index;
    state = state.copyWith(
      queue: queue,
      index: current != null && index < current ? current - 1 : current,
    );
    _unshuffledUids?.removeWhere((uid) => !queue.any((q) => q.uid == uid));
    _saveSession();
  }

  /// Moves the item at [oldIndex] so it ends up at [newIndex].
  void move(int oldIndex, int newIndex) {
    final target = newIndex;
    if (target == oldIndex) return;
    final queue = [...state.queue];
    final item = queue.removeAt(oldIndex);
    queue.insert(target, item);
    final currentUid = state.current?.uid;
    state = state.copyWith(
      queue: queue,
      index: currentUid == null
          ? null
          : queue.indexWhere((q) => q.uid == currentUid),
    );
    _saveSession();
  }

  /// Removes everything except the item currently playing.
  void clearUpcoming() {
    final current = state.current;
    _unshuffledUids = null;
    state = state.copyWith(
      queue: current == null ? const [] : [current],
      index: current == null ? null : 0,
    );
    _saveSession();
  }

  // ------------------------------------------------------------ transport --

  Future<void> togglePlayPause() =>
      state.isPlaying ? _engine.pause() : resume();

  Future<void> resume() async {
    if (state.current == null) return;
    if (state.status == PlaybackStatus.completed) {
      await _engine.seek(Duration.zero);
    }
    await _engine.play();
  }

  Future<void> pause() async {
    await _engine.pause();
    _saveSession(force: true);
  }

  Future<void> next() async {
    final index = state.index;
    if (index == null) return;
    if (index + 1 < state.queue.length) {
      await _startAt(index + 1);
    } else if (state.repeat == RepeatMode.all && state.queue.isNotEmpty) {
      await _startAt(0);
    }
  }

  /// Restarts the current item when past a few seconds, like most players.
  Future<void> previous() async {
    final index = state.index;
    if (index == null) return;
    if (_engine.currentPosition > _restartThreshold || index == 0) {
      await _engine.seek(Duration.zero);
    } else {
      await _startAt(index - 1);
    }
  }

  Future<void> seek(Duration position) => _engine.seek(position);

  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume.clamp(0, 1));
    await _engine.setVolume(state.volume);
  }

  void cycleRepeat() {
    state = state.copyWith(
      repeat: RepeatMode.values[(state.repeat.index + 1) % 3],
    );
    _saveSession();
  }

  /// Shuffles the upcoming items; turning it off restores their order.
  void toggleShuffle() {
    final index = state.index;
    if (!state.shuffle) {
      _unshuffledUids = [for (final q in state.queue) q.uid];
      final head = index == null
          ? <QueueItem>[]
          : state.queue.sublist(0, index + 1);
      final tail = (index == null ? [...state.queue] : state.upcoming.toList())
        ..shuffle(_random);
      state = state.copyWith(queue: [...head, ...tail], shuffle: true);
    } else {
      final order = _unshuffledUids;
      final currentUid = state.current?.uid;
      if (order != null) {
        final byUid = {for (final q in state.queue) q.uid: q};
        final restored = [
          for (final uid in order) ?byUid.remove(uid),
          ...byUid.values, // Items added while shuffled keep their place last.
        ];
        state = state.copyWith(
          queue: restored,
          index: currentUid == null
              ? null
              : restored.indexWhere((q) => q.uid == currentUid),
        );
      }
      _unshuffledUids = null;
      state = state.copyWith(shuffle: false);
    }
    _saveSession();
  }

  /// Local favorite. Never synchronized to any provider.
  Future<void> toggleFavorite(Track track) async {
    final id = track.localId;
    if (id == null) return;
    final favorite = !track.isFavorite;
    await ref
        .read(libraryRepositoryProvider)
        .setFavorite(id, favorite: favorite);
    state = state.copyWith(
      queue: [
        for (final q in state.queue)
          if (q.track.id == track.id)
            q.copyWith(track: q.track.copyWith(isFavorite: favorite))
          else
            q,
      ],
    );
  }

  // -------------------------------------------------------------- session --

  /// Restores the last queue paused at its last position.
  Future<void> restoreSession() async {
    if (!_settings.resumeSession) return;
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(sessionKey);
    if (json == null) return;
    try {
      final ids = (json['trackIds']! as List<Object?>).cast<int>();
      final tracks = await ref.read(libraryRepositoryProvider).tracksByIds(ids);
      if (tracks.isEmpty) return;
      final index = (json['index']! as int).clamp(0, tracks.length - 1);
      state = state.copyWith(
        queue: [for (final t in tracks) _item(t)],
        index: index,
        repeat: RepeatMode.values.byName(json['repeat']! as String),
      );
      await _engine.load(
        tracks[index],
        start: Duration(milliseconds: json['positionMs']! as int),
      );
    } on Object catch (e) {
      debugPrint('Playback session could not be restored: ${e.runtimeType}');
    }
  }

  void _saveSession({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSessionSave) < _sessionSaveInterval) {
      return;
    }
    _lastSessionSave = now;
    final repo = ref.read(settingsRepositoryProvider);
    final current = state.current;
    if (current == null) {
      unawaited(repo.delete(sessionKey));
      return;
    }
    final ids = [for (final q in state.queue) ?q.track.localId];
    unawaited(
      repo.writeJson(sessionKey, {
        'trackIds': ids,
        'index': ids.indexOf(current.track.localId ?? -1).clamp(0, ids.length),
        'positionMs': _engine.currentPosition.inMilliseconds,
        'repeat': state.repeat.name,
      }),
    );
  }

  // ------------------------------------------------------------- internal --

  QueueItem _item(Track track) => QueueItem(uid: _nextUid++, track: track);

  void _setQueue(List<QueueItem> queue) {
    final currentUid = state.current?.uid;
    state = state.copyWith(
      queue: queue,
      index: currentUid == null
          ? null
          : queue.indexWhere((q) => q.uid == currentUid),
    );
    if (_unshuffledUids != null) {
      final known = _unshuffledUids!.toSet();
      _unshuffledUids!.addAll(queue.map((q) => q.uid).where(known.add));
    }
    _saveSession(force: true);
  }

  Future<void> _startAt(int index) async {
    state = state.copyWith(index: index, message: null);
    await _loadCurrent(autoplay: true);
  }

  Future<void> _loadCurrent({required bool autoplay}) async {
    final item = state.current;
    if (item == null) return;
    _crossfading = false;
    state = state.copyWith(status: PlaybackStatus.loading);
    final ok = await _engine.load(item.track);
    if (!ok || state.current?.uid != item.uid) return; // Failed/superseded.
    if (autoplay) await _engine.play();
    _recordPlay(item.track);
    _saveSession(force: true);
  }

  void _recordPlay(Track track) {
    final id = track.localId;
    if (id != null) unawaited(ref.read(historyRepositoryProvider).record(id));
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case EngineStatusChanged(:final status):
        state = state.copyWith(status: status);
      case EngineCompleted():
        unawaited(_onCompleted());
      case EngineFailed(:final message):
        state = state.copyWith(status: PlaybackStatus.error, message: message);
    }
  }

  Future<void> _onCompleted() async {
    if (_crossfading) return;
    if (state.repeat == RepeatMode.one) {
      await _engine.seek(Duration.zero);
      await _engine.play();
    } else if (state.hasNext) {
      await next();
    } else {
      state = state.copyWith(status: PlaybackStatus.completed);
      _saveSession(force: true);
    }
  }

  void _onPosition(Duration position) {
    _saveSession();
    _maybeCrossfade(position);
  }

  void _maybeCrossfade(Duration position) {
    final seconds = _settings.crossfadeSeconds;
    final duration = _engine.currentDuration;
    final index = state.index;
    if (seconds == 0 ||
        _crossfading ||
        !_engine.capabilities.canCrossfade ||
        state.repeat == RepeatMode.one ||
        !state.isPlaying ||
        duration == null ||
        index == null) {
      return;
    }
    final fade = Duration(seconds: seconds);
    // Skip very short items: a fade longer than half the track sounds wrong.
    if (duration < fade * 2 || duration - position > fade) return;
    final nextIndex = index + 1 < state.queue.length
        ? index + 1
        : (state.repeat == RepeatMode.all ? 0 : null);
    if (nextIndex == null) return;

    _crossfading = true;
    final next = state.queue[nextIndex];
    state = state.copyWith(index: nextIndex);
    _recordPlay(next.track);
    unawaited(
      _engine.crossfadeTo(next.track, fade).whenComplete(() {
        _crossfading = false;
        _saveSession(force: true);
      }),
    );
  }
}
