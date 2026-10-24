import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/routing_engine.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/integrations/local_audio/local_audio_engine.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/integrations/youtube_playback/youtube_embed_engine.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:path/path.dart' as p;

final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  final dirs = ref.watch(appDirectoriesProvider);
  final engine = RoutingEngine({
    MediaSource.local: LocalAudioEngine(),
    if (YouTubeEmbedEngine.isSupported)
      MediaSource.youtube: YouTubeEmbedEngine(
        pageDir: Directory(p.join(dirs.artwork.parent.path, 'yt_player')),
      ),
  });
  ref.onDispose(engine.dispose);
  return engine;
});

/// The embedded YouTube player, for the video layer. Null when this platform
/// has no YouTube engine (or in tests with a fake engine).
final youTubeEngineProvider = Provider<YouTubeEmbedEngine?>((ref) {
  final engine = ref.watch(playbackEngineProvider);
  return engine is RoutingEngine
      ? engine.engineFor(MediaSource.youtube) as YouTubeEmbedEngine?
      : null;
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

  /// Off until [restoreSession] has run (or the user starts something), so
  /// early engine events can't overwrite the saved session before it's read.
  bool _sessionReady = false;

  /// Keeps playback going past the end of the queue with YouTube Music radio
  /// (like its autoplay) when the queue holds a YouTube track and repeat is
  /// off. Tests switch it off.
  bool autoplayRadio = true;

  /// Radio tracks appended per request.
  static const radioBatch = 20;

  /// How long before the last track ends the next radio batch is fetched.
  static const radioLeadTime = Duration(seconds: 30);

  /// Where the radio left off: continuing after [_RadioCursor.anchorUid]
  /// uses its continuation instead of starting a new radio.
  _RadioCursor? _radio;
  Future<bool>? _radioFetch;

  /// Last queue item a lead-time radio fetch was attempted for, so a failed
  /// request is not repeated on every position tick.
  int? _radioTriedUid;

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

  /// Plays [seed], then YouTube Music radio based on it. A local seed is
  /// matched to a YouTube Music song by artist and title; without a match
  /// only the seed plays. Works regardless of [autoplayRadio].
  Future<void> startRadio(Track seed) async {
    _unshuffledUids = null;
    _radio = null;
    state = state.copyWith(
      queue: [_item(seed)],
      index: 0,
      shuffle: false,
      message: null,
    );
    final radio = _fetchRadio(seed: seed);
    await _loadCurrent(autoplay: true);
    await radio;
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
    try {
      await _restoreSession();
    } finally {
      _sessionReady = true;
    }
  }

  Future<void> _restoreSession() async {
    if (!_settings.resumeSession) return;
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(sessionKey);
    if (json == null) return;
    try {
      final saved = [
        for (final t in json['tracks']! as List<Object?>)
          Track.fromJson(t! as Map<String, Object?>),
      ];
      // Local tracks are re-read so deleted files and new favorites show up.
      final local = {
        for (final t in await ref.read(libraryRepositoryProvider).tracksByIds([
          for (final t in saved) ?t.localId,
        ]))
          t.id: t,
      };
      final tracks = [
        for (final t in saved)
          if (t.source == MediaSource.local) ?local[t.id] else t,
      ];
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
    if (!_sessionReady) return;
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
    unawaited(
      repo.writeJson(sessionKey, {
        'tracks': [for (final q in state.queue) q.track.toJson()],
        'index': state.index,
        'positionMs': _engine.currentPosition.inMilliseconds,
        'repeat': state.repeat.name,
      }),
    );
  }

  // ------------------------------------------------------------- internal --

  QueueItem _item(Track track) => QueueItem(uid: _nextUid++, track: track);

  void _setQueue(List<QueueItem> queue) {
    _sessionReady = true;
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
    _sessionReady = true;
    final item = state.current;
    if (item == null) return;
    _crossfading = false;
    state = state.copyWith(status: PlaybackStatus.loading);
    final ok = await _engine.load(item.track);
    // The engine may have switched source; controls follow its abilities.
    state = state.copyWith(capabilities: _engine.capabilities);
    if (!ok || state.current?.uid != item.uid) return; // Failed/superseded.
    // Saved before play(): the YouTube engine's play may take a while.
    _saveSession(force: true);
    if (autoplay) await _engine.play();
    _recordPlay(item.track);
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
    } else if (_radioEligible && await _extendWithRadio() && state.hasNext) {
      await next();
    } else {
      state = state.copyWith(status: PlaybackStatus.completed);
      _saveSession(force: true);
    }
  }

  void _onPosition(Duration position) {
    _saveSession();
    _maybePrefetchRadio(position);
    _maybeCrossfade(position);
  }

  // ---------------------------------------------------------------- radio --

  bool get _radioEligible =>
      autoplayRadio &&
      state.repeat == RepeatMode.off &&
      state.queue.any((q) => q.track.source == MediaSource.youtube);

  /// Fetches more radio while the last track still plays, so the next one
  /// is queued (and crossfades work) before it ends.
  void _maybePrefetchRadio(Duration position) {
    final index = state.index;
    final current = state.current;
    final duration = _engine.currentDuration;
    if (current == null ||
        index != state.queue.length - 1 ||
        current.uid == _radioTriedUid ||
        duration == null ||
        duration - position > radioLeadTime ||
        !_radioEligible) {
      return;
    }
    _radioTriedUid = current.uid;
    unawaited(_extendWithRadio());
  }

  /// Joins a radio request already in flight instead of starting another.
  Future<bool> _extendWithRadio() =>
      _radioFetch ??= _fetchRadio().whenComplete(() => _radioFetch = null);

  /// Appends up to [radioBatch] radio tracks not already queued, seeded by
  /// [seed] or else the last YouTube track in the queue. Returns whether
  /// anything was added. Never throws and never reports to the user: radio
  /// is a bonus and must not interrupt playback.
  Future<bool> _fetchRadio({Track? seed}) async {
    if (state.queue.isEmpty) return false;
    final anchor = state.queue.last.uid;
    try {
      final client = ref.read(innerTubeClientProvider);
      final seen = {
        for (final q in state.queue)
          if (q.track.source == MediaSource.youtube) q.track.uri,
      };
      final cursor = _radio;
      YtmTrackPage page;
      String? playlistId;
      if (seed == null &&
          cursor != null &&
          cursor.anchorUid == anchor &&
          cursor.continuation != null) {
        playlistId = cursor.playlistId;
        page = await client.radioMore(
          cursor.continuation!,
          playlistId: playlistId,
        );
      } else {
        final videoId = seed == null
            ? state.queue
                  .map((q) => q.track)
                  .where((t) => t.source == MediaSource.youtube)
                  .lastOrNull
                  ?.uri
            : await _youTubeIdFor(seed, client);
        if (videoId == null) return false;
        seen.add(videoId);
        page = await client.radio(videoId);
      }
      final fresh = <Track>[];
      // A page may only repeat what is queued; look a little further.
      for (var pages = 1; ; pages++) {
        fresh.addAll(
          page.tracks
              .where((t) => seen.add(t.uri))
              .take(radioBatch - fresh.length),
        );
        playlistId = page.playlistId ?? playlistId;
        final next = page.continuation;
        if (fresh.isNotEmpty || next == null || pages >= 3) break;
        page = await client.radioMore(next, playlistId: playlistId);
      }
      // The queue changed meanwhile (new list played, items added): drop.
      if (!ref.mounted ||
          state.queue.isEmpty ||
          state.queue.last.uid != anchor ||
          fresh.isEmpty) {
        return false;
      }
      _setQueue([...state.queue, for (final t in fresh) _item(t)]);
      _radio = _RadioCursor(
        anchorUid: state.queue.last.uid,
        continuation: page.continuation,
        playlistId: playlistId,
      );
      return true;
    } on Object catch (e) {
      debugPrint('Radio unavailable: ${e.runtimeType}');
      return false;
    }
  }

  /// The YouTube video id for [track]: its own, or the best YouTube Music
  /// song match for a local file.
  Future<String?> _youTubeIdFor(Track track, InnerTubeClient client) async {
    if (track.source == MediaSource.youtube) return track.uri;
    final query = [?track.artist, track.title].join(' ');
    final results = await client.search(query);
    return results.items.whereType<YtmTrackItem>().firstOrNull?.videoId;
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
    final next = state.queue[nextIndex];
    // No fades across sources (e.g. into a YouTube video).
    if (next.track.source != state.queue[index].track.source) return;

    _crossfading = true;
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

/// Where YouTube Music radio continues after the queue item [anchorUid].
@immutable
class _RadioCursor {
  const _RadioCursor({
    required this.anchorUid,
    this.continuation,
    this.playlistId,
  });

  final int anchorUid;
  final String? continuation;
  final String? playlistId;
}
