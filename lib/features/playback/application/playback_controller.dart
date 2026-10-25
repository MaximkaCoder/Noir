import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/transition_log.dart';
import 'package:noir/features/playback/application/transition_status.dart';
import 'package:noir/features/playback/domain/audio_source_provider.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/features/playback/domain/routing_engine.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/features/playback/domain/transition_planner.dart';
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

/// Optional local files for non-local tracks; none by default.
final audioFilesProvider = Provider<AudioFileProvider>(
  (ref) => const NoAudioFiles(),
);

final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  final dirs = ref.watch(appDirectoriesProvider);
  final engine = RoutingEngine({
    MediaSource.local: LocalAudioEngine(),
    if (YouTubeEmbedEngine.isSupported)
      MediaSource.youtube: YouTubeEmbedEngine(
        pageDir: Directory(p.join(dirs.artwork.parent.path, 'yt_player')),
      ),
  }, files: ref.watch(audioFilesProvider));
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

  /// Queue item found not to share the current engine, so it isn't
  /// re-checked on every position tick.
  int? _noFadeUid;

  /// The smart transition being prepared for the current -> next pair.
  _SmartPrep? _smart;

  /// Why the current track can't hand over with a transition, for the log.
  String? _whyNot;
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

  Future<void> togglePlayPause() => state.isPlaying ? pause() : resume();

  Future<void> resume() async {
    if (state.current == null) return;
    if (state.status == PlaybackStatus.completed) {
      await _engine.seek(Duration.zero);
    }
    await _engine.play();
  }

  Future<void> pause() async {
    _userAction();
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
      _userAction();
      await _engine.seek(Duration.zero);
    } else {
      await _startAt(index - 1);
    }
  }

  Future<void> seek(Duration position) {
    _userAction();
    return _engine.seek(position);
  }

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
      // The restored item may play on another engine than the default.
      state = state.copyWith(capabilities: _engine.capabilities);
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
    _hintUpcoming();
    _saveSession(force: true);
  }

  /// Tells the audio file provider what is likely to play next.
  void _hintUpcoming() {
    if (state.index == null) return;
    final next = state.upcoming.take(2).map((q) => q.track).toList();
    if (next.isNotEmpty) ref.read(audioFilesProvider).prefetch(next);
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
    _whyNot = null;
    if (_smart != null) {
      _smart = null;
      _setTransition(null);
    }
    state = state.copyWith(status: PlaybackStatus.loading);
    final ok = await _engine.load(item.track);
    // The engine may have switched source; controls follow its abilities.
    state = state.copyWith(capabilities: _engine.capabilities);
    if (!ok || state.current?.uid != item.uid) return; // Failed/superseded.
    _hintUpcoming();
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
    if (_settings.transitionMode != TransitionMode.off &&
        state.repeat != RepeatMode.one &&
        state.hasNext) {
      _log(
        '"${state.current?.track.title}" ended without a transition: '
        '${_whyNoTransition()}',
      );
    }
    _whyNot = null;
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
    _maybeTransition(position);
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

  void _maybeTransition(Duration position) {
    final mode = _settings.transitionMode;
    final duration = _engine.currentDuration;
    final index = state.index;
    if (mode == TransitionMode.off ||
        _crossfading ||
        state.repeat == RepeatMode.one ||
        !state.isPlaying ||
        duration == null ||
        index == null) {
      return;
    }
    if (!_engine.capabilities.canCrossfade) {
      _whyNot =
          'the current track plays on a player that cannot mix '
          '(${state.queue[index].track.source.name}, not cached)';
      return;
    }
    final nextIndex = index + 1 < state.queue.length
        ? index + 1
        : (state.repeat == RepeatMode.all ? 0 : null);
    if (nextIndex == null) {
      _whyNot = 'nothing queued after it';
      return;
    }
    final next = state.queue[nextIndex];
    if (next.uid == _noFadeUid) return;
    if (mode == TransitionMode.smart && _engine is MixingEngine) {
      _maybeSmart(position, duration, index, next);
      return;
    }

    final fade = Duration(seconds: _settings.crossfadeSeconds.clamp(1, 12));
    // Skip very short items: a fade longer than half the track sounds wrong.
    if (duration < fade * 2 || duration - position > fade) return;
    _crossfading = true;
    unawaited(_crossfadeInto(index, next, fade));
  }

  /// The plan is made this long before the end, so a beat-matched blend can
  /// start on a phrase well before the outro. Inputs are gathered as soon
  /// as the track plays.
  static const _smartPlanAt = Duration(seconds: 70);

  /// The engine gets the plan this long before its start, to load and
  /// lock the next track.
  static const _smartPrepare = 4.0;

  /// Below this much time left, plans start almost at once (a seek near
  /// the end) instead of leaving [transitionLead] to prepare.
  static const _shortOnTime = 20.0;

  /// Planning without analyses (plain crossfade) once this little is left.
  static const _lastCall = 12.0;

  /// A next track found not to be on the mixing player is checked again
  /// after this much playback (its audio may get cached meanwhile).
  static const _recheckEvery = 5.0;

  void _maybeSmart(
    Duration position,
    Duration duration,
    int index,
    QueueItem next,
  ) {
    final current = state.queue[index];
    final at = position.inMicroseconds / 1e6;
    final remaining = (duration - position).inMicroseconds / 1e6;
    var prep = _smart;
    if (prep == null || prep.fromUid != current.uid || prep.toUid != next.uid) {
      prep = _smart = _SmartPrep(current, next);
      _setTransition(null);
      unawaited(_gatherSmart(prep, at));
    }
    if (prep.mixable == false && at - prep.checkedAt >= _recheckEvery) {
      unawaited(_checkMixable(prep, at));
    }
    if (prep.mixable != true) {
      _whyNot = prep.mixable == null
          ? 'still checking whether "${next.track.title}" plays on the '
                'mixing player'
          : '"${next.track.title}" is not on the mixing player (not cached)';
      return;
    }
    if (prep.plan == null) {
      var sides = prep.sides;
      if (remaining > _smartPlanAt.inSeconds) return;
      if (sides == null) {
        if (remaining > _lastCall) {
          _whyNot = 'analyses not loaded yet';
          return;
        }
        sides = (_bareSide(current.track), _bareSide(next.track));
        _log('${_pair(prep)}: analyses not loaded in time, plain fade');
      }
      final plan = prep.plan = planTransition(
        sides.$1.withLyrics(prep.vocalsA),
        sides.$2.withLyrics(prep.vocalsB),
        fadeSeconds: _settings.crossfadeSeconds.toDouble(),
        earliestStart: at + (remaining > _shortOnTime ? transitionLead : 1.0),
      );
      prep.plannedWithLyrics = prep.lyricsDone;
      _log(
        '${_pair(prep)}: plan ${plan.type.name}'
        '${plan.quick ? ' (quick)' : ''} at ${_s(plan.startInA)} for '
        '${_s(plan.seconds)} (A ends ${_s(plan.endInA)}, B from '
        '${_s(plan.entryInB)}${plan.bars == null ? '' : ', ${plan.bars} bars'}'
        ') — ${plan.reason}; now ${_s(at)} of ${_s(at + remaining)}; '
        'analysis A ${sides.$1.analysis != null ? 'yes' : 'no'}, B '
        '${sides.$2.analysis != null ? 'yes' : 'no'}; vocals out '
        '${_s(plan.vocalOutA)} (${plan.vocalSourceA.name}), in '
        '${_s(plan.vocalInB)} (${plan.vocalSourceB.name}); A tail skipped '
        '${_s(plan.skippedA)}',
      );
      for (final (i, alt) in plan.alternatives.indexed) {
        _log('  ${i == 0 ? 'chosen' : 'also  '} $alt');
      }
      _setTransition(
        TransitionStatus(plan: plan, phase: TransitionPhase.planned),
      );
    }
    final plan = prep.plan!;
    // Seeked past the planned start: plan again from here.
    if (at > plan.startInA - 1 && !plan.quick) {
      _log(
        '${_pair(prep)}: dropped ${plan.type.name} at ${_s(plan.startInA)}, '
        'position jumped to ${_s(at)}; planning again',
      );
      prep.plan = null;
      _maybeSmart(position, duration, index, next);
      return;
    }
    if (at < plan.startInA - _smartPrepare) return;
    _crossfading = true;
    unawaited(_mixInto(next, plan, prep));
  }

  TransitionSide _bareSide(Track track) => TransitionSide(
    duration: track.duration == null
        ? null
        : track.duration!.inMicroseconds / 1e6,
    album: track.album,
    artist: track.artist,
    trackNumber: track.trackNumber,
  );

  /// Gathers both sides as soon as the pair is known: whether the next
  /// track plays on the mixing player, the stored analyses (fast) and the
  /// lyrics' vocal timing (slow; a plan made before it arrives is redone
  /// if there is still time).
  Future<void> _gatherSmart(_SmartPrep prep, double at) async {
    await _checkMixable(prep, at);
    final load = ref.read(transitionSideLoaderProvider);
    final sides = await Future.wait([
      load(prep.from.track),
      load(prep.to.track),
    ]);
    if (!ref.mounted || !identical(_smart, prep)) return;
    prep.sides = (sides[0], sides[1]);
    final vocals = ref.read(vocalTimingLoaderProvider);
    final timings = await Future.wait([
      vocals(prep.from.track),
      vocals(prep.to.track),
    ]);
    if (!ref.mounted || !identical(_smart, prep)) return;
    prep
      ..vocalsA = timings[0]
      ..vocalsB = timings[1]
      ..lyricsDone = true;
    if (prep.plan != null && !prep.handedOver && !prep.plannedWithLyrics) {
      prep.plan = null; // Plan again with the vocal timing.
    }
  }

  Future<void> _checkMixable(_SmartPrep prep, double at) async {
    prep.checkedAt = at;
    final engine = _engine;
    final mixer = engine is MixingEngine ? engine as MixingEngine : null;
    final ok = mixer != null && await mixer.canMixInto(prep.to.track);
    if (!ref.mounted || !identical(_smart, prep)) return;
    if (prep.mixable != ok) {
      _log(
        '${_pair(prep)}: next track ${ok ? 'is' : 'is not'} on the mixing '
        'player (${prep.to.track.source.name})',
      );
    }
    prep.mixable = ok;
  }

  /// Runs [plan] into [next]. The queue moves on when the engine says
  /// [next] became audible.
  Future<void> _mixInto(
    QueueItem next,
    TransitionPlan plan,
    _SmartPrep prep,
  ) async {
    final engine = _engine as MixingEngine;
    var started = false;
    prep
      ..handedOver = true
      ..userAction = false;
    final ok = await engine.transitionTo(
      next.track,
      plan,
      onStart: () {
        if (!ref.mounted) return;
        started = true;
        var nextIndex = state.queue.indexWhere((q) => q.uid == next.uid);
        if (nextIndex < 0) {
          // Removed from the queue while being prepared: it plays anyway,
          // so it goes back right after the item it follows.
          final queue = [...state.queue]..insert((state.index ?? -1) + 1, next);
          state = state.copyWith(queue: queue);
          nextIndex = queue.indexWhere((q) => q.uid == next.uid);
        }
        state = state.copyWith(index: nextIndex, message: null);
        _recordPlay(next.track);
        _hintUpcoming();
        _setTransition(
          TransitionStatus(plan: plan, phase: TransitionPhase.mixing),
        );
      },
      onProgress: (t) {
        if (!ref.mounted || !started) return;
        _setTransition(
          TransitionStatus(
            plan: plan,
            phase: TransitionPhase.mixing,
            progress: t,
          ),
        );
      },
    );
    if (!ref.mounted) return;
    _crossfading = false;
    prep.handedOver = false;
    if (ok) {
      _log('${_pair(prep)}: ${plan.type.name} done');
      if (identical(_smart, prep)) _smart = null;
    } else if (prep.userAction) {
      // A pause or seek: the plan is retried while there is time for it,
      // or made again from the new position.
      _log(
        '${_pair(prep)}: waiting ${plan.type.name} dropped by a pause '
        'or seek',
      );
      prep.userAction = false;
    } else if (++prep.failures >= 3) {
      _log('${_pair(prep)}: the player gave up 3 times; no transition');
      if (identical(_smart, prep)) _noFadeUid = prep.toUid;
    } else {
      _log(
        '${_pair(prep)}: the player could not start ${plan.type.name}; '
        'retrying',
      );
    }
    _setTransition(null);
    _saveSession(force: true);
  }

  /// For the log: why the current track is ending without a transition.
  String _whyNoTransition() {
    final prep = _smart;
    if (prep == null || prep.fromUid != state.current?.uid) {
      return _whyNot ?? 'nothing was prepared (not playing near the end?)';
    }
    final next = '"${prep.to.track.title}"';
    if (prep.mixable == null) {
      return 'still checking whether $next plays on the mixing player';
    }
    if (prep.mixable == false) {
      return '$next is not on the mixing player (not cached)';
    }
    final plan = prep.plan;
    if (plan == null) {
      return prep.sides == null ? 'analyses not loaded' : 'not planned yet';
    }
    return 'the ${plan.type.name} planned at ${_s(plan.startInA)} '
        'never started';
  }

  /// The smart transition (if any) is about to be disturbed by the user.
  void _userAction() => _smart?.userAction = true;

  void _log(String message) => ref.read(transitionLogProvider).add(message);

  static String _s(double? seconds) =>
      seconds == null ? '-' : '${seconds.toStringAsFixed(1)}s';

  static String _pair(_SmartPrep prep) =>
      '"${prep.from.track.title}" → "${prep.to.track.title}"';

  void _setTransition(TransitionStatus? status) {
    final notifier = ref.read(transitionStatusProvider.notifier);
    if (status != null || ref.read(transitionStatusProvider) != null) {
      notifier.set(status);
    }
  }

  /// Fades into [next] (at the queue position after [from]) when both play
  /// on the same engine; never across engines (e.g. into a YouTube video).
  Future<void> _crossfadeInto(int from, QueueItem next, Duration fade) async {
    final engine = _engine;
    final current = state.queue[from].track;
    final same = engine is RoutingEngine
        ? await engine.canCrossfadeTo(next.track)
        : next.track.source == current.source;
    final nextIndex = state.queue.indexWhere((q) => q.uid == next.uid);
    if (!same || state.index != from || nextIndex < 0 || !state.isPlaying) {
      if (!same) _noFadeUid = next.uid;
      _crossfading = false;
      return;
    }
    state = state.copyWith(index: nextIndex);
    _recordPlay(next.track);
    _hintUpcoming();
    await _engine.crossfadeTo(next.track, fade).whenComplete(() {
      _crossfading = false;
      _saveSession(force: true);
    });
  }
}

/// A smart transition being prepared between two queue items.
class _SmartPrep {
  _SmartPrep(this.from, this.to);

  final QueueItem from;
  final QueueItem to;

  int get fromUid => from.uid;
  int get toUid => to.uid;

  /// Whether [to] plays on the same, mixing player; null while checking.
  bool? mixable;

  /// Outgoing position of the last [mixable] check.
  double checkedAt = 0;

  /// Planner inputs without lyrics (outgoing, incoming), once loaded.
  (TransitionSide, TransitionSide)? sides;

  /// Vocal timing from lyrics, once [lyricsDone].
  VocalTiming? vocalsA;
  VocalTiming? vocalsB;
  bool lyricsDone = false;
  bool plannedWithLyrics = false;

  TransitionPlan? plan;

  /// The engine has the plan.
  bool handedOver = false;

  /// The user paused or seeked while the engine had the plan.
  bool userAction = false;

  /// Times the engine abandoned the transition by itself.
  int failures = 0;
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
