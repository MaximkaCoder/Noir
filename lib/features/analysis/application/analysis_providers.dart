import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/analysis/data/analysis_store.dart';
import 'package:noir/features/analysis/domain/track_analysis.dart';
import 'package:noir/features/analysis/domain/track_analyzer.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/integrations/audio_decode/audio_decoder.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:path/path.dart' as p;

/// Decodes and analyses an audio file off the UI isolate.
typedef AnalysisRunner = Future<TrackAnalysis> Function(String path);

/// Decodes [path] and analyses it in a short-lived background isolate; only
/// the small result crosses back. Throws `AudioDecodeException` when the
/// file cannot be decoded.
Future<TrackAnalysis> analyzeFileInBackground(String path) => Isolate.run(() {
  final watch = Stopwatch()..start();
  final analysis = analyzePcm(decodeAudioFile(path));
  return analysis.copyWith(
    analyzedAt: DateTime.now(),
    elapsedMs: watch.elapsedMilliseconds,
  );
}, debugName: 'track-analysis');

final analysisStoreProvider = Provider<AnalysisStore>(
  (ref) => AnalysisStore(
    Directory(
      p.join(ref.watch(appDirectoriesProvider).artwork.parent.path, 'analysis'),
    ),
  ),
);

final analysisRunnerProvider = Provider<AnalysisRunner>(
  (ref) => analyzeFileInBackground,
);

/// The audio file to analyse for a track, or null when there is none (yet).
/// Local tracks are their file; a cache of streamed audio can extend this.
final analysisPathResolverProvider = Provider<String? Function(Track)>(
  (ref) =>
      (track) => track.source == MediaSource.local ? track.uri : null,
);

/// Pacing of the background queue.
class AnalysisQueueConfig {
  const AnalysisQueueConfig({
    this.librarySweepDelay = const Duration(seconds: 20),
    this.gap = const Duration(milliseconds: 750),
  });

  /// Wait after start-up before walking the whole library.
  final Duration librarySweepDelay;

  /// Idle time between two analyses so the queue never hogs a core.
  final Duration gap;
}

final analysisQueueConfigProvider = Provider<AnalysisQueueConfig>(
  (ref) => const AnalysisQueueConfig(),
);

/// The stored analysis of a track; refreshed when the queue finishes it.
final trackAnalysisProvider = FutureProvider.family<TrackAnalysis?, String>(
  (ref, trackId) => ref.watch(analysisStoreProvider).read(trackId),
);

final analysisQueueProvider =
    NotifierProvider<AnalysisQueue, AnalysisQueueState>(AnalysisQueue.new);

@immutable
class AnalysisQueueState {
  const AnalysisQueueState({
    this.currentTrackId,
    this.pending = 0,
    this.completed = 0,
    this.failed = 0,
    this.paused = false,
  });

  /// Track being analysed right now, null when idle.
  final String? currentTrackId;

  /// Jobs waiting (not counting the current one).
  final int pending;

  /// Analyses finished / failed since start-up.
  final int completed;
  final int failed;
  final bool paused;

  bool get isBusy => currentTrackId != null;

  AnalysisQueueState copyWith({
    String? Function()? currentTrackId,
    int? pending,
    int? completed,
    int? failed,
    bool? paused,
  }) => AnalysisQueueState(
    currentTrackId: currentTrackId == null
        ? this.currentTrackId
        : currentTrackId(),
    pending: pending ?? this.pending,
    completed: completed ?? this.completed,
    failed: failed ?? this.failed,
    paused: paused ?? this.paused,
  );
}

enum _Priority { request, playing, library }

class _Job {
  _Job(this.trackId, this.path, this.priority, {required this.persist});

  final String trackId;
  final String path;
  _Priority priority;
  final bool persist;
  final waiters = <Completer<TrackAnalysis?>>[];
}

/// Analyses tracks one at a time in the background: explicit requests
/// first, then the playing track and the next three in the queue, then the
/// rest of the local library. Waits while playback is loading a track and
/// whenever [pause] is in effect.
class AnalysisQueue extends Notifier<AnalysisQueueState> {
  final _jobs = <_Job>[];

  /// Tracks analysed (or found up to date) / failed this session; only an
  /// explicit [analyzeFile] request looks at them again.
  final _done = <String>{};
  final _failed = <String>{};
  bool _running = false;
  bool _paused = false;
  int _generation = 0;
  Timer? _sweep;
  Completer<void>? _wake;

  /// Upcoming queue items analysed ahead of the library.
  static const lookahead = 3;

  @override
  AnalysisQueueState build() {
    ref
      ..onDispose(() {
        _sweep?.cancel();
        _generation++;
        _finishAll();
        _wakeUp();
      })
      ..listen(playbackProvider, (_, next) => _prioritize(next));
    _sweep = Timer(
      ref.read(analysisQueueConfigProvider).librarySweepDelay,
      () => unawaited(_enqueueLibrary()),
    );
    scheduleMicrotask(() {
      if (ref.mounted) _prioritize(ref.read(playbackProvider));
    });
    return const AnalysisQueueState();
  }

  /// Analyses the audio file at [path] ahead of everything else. With a
  /// [trackId] the result is stored (and served by [trackAnalysisProvider])
  /// and an up-to-date stored result is returned without re-analysing.
  /// Completes with null when the file cannot be decoded or the queue is
  /// cancelled.
  Future<TrackAnalysis?> analyzeFile(String path, {String? trackId}) {
    final waiter = Completer<TrackAnalysis?>();
    final job = _enqueue(
      trackId ?? 'file:$path',
      path,
      _Priority.request,
      persist: trackId != null,
    );
    if (job == null) {
      waiter.complete(null);
    } else {
      job.waiters.add(waiter);
    }
    return waiter.future;
  }

  /// Holds the queue after the current analysis (e.g. during a transition).
  void pause() {
    _paused = true;
    _update();
  }

  void resume() {
    _paused = false;
    _update();
    _wakeUp();
  }

  /// Drops every waiting job; the analysis in flight finishes in its
  /// isolate but its result is discarded.
  void cancel() {
    _generation++;
    _sweep?.cancel();
    _finishAll();
    _update(currentTrackId: () => null);
  }

  void _prioritize(PlaybackState playback) {
    final items = [?playback.current, ...playback.upcoming.take(lookahead)];
    final resolve = ref.read(analysisPathResolverProvider);
    for (final item in items) {
      final path = resolve(item.track);
      if (path != null) {
        _enqueue(item.track.id, path, _Priority.playing, persist: true);
      }
    }
  }

  Future<void> _enqueueLibrary() async {
    final generation = _generation;
    final List<Track> tracks;
    try {
      tracks = await ref
          .read(libraryRepositoryProvider)
          .watchTracks(sort: TrackSort.recentlyAdded)
          .first;
    } on Object catch (e) {
      debugPrint('Analysis: cannot list library: $e');
      return;
    }
    final store = ref.read(analysisStoreProvider);
    final resolve = ref.read(analysisPathResolverProvider);
    for (final track in tracks) {
      if (!ref.mounted || generation != _generation) return;
      final path = resolve(track);
      // Up to date for the current algorithm: changed files are caught when
      // they come up for playback (that path checks the fingerprint).
      if (path == null || await store.isFresh(track.id, null)) continue;
      _enqueue(track.id, path, _Priority.library, persist: true);
    }
  }

  _Job? _enqueue(
    String trackId,
    String path,
    _Priority priority, {
    required bool persist,
  }) {
    if (!ref.mounted) return null;
    if (priority != _Priority.request &&
        (_done.contains(trackId) || _failed.contains(trackId))) {
      return null;
    }
    var job = _jobs.where((j) => j.trackId == trackId).firstOrNull;
    if (job != null && job.path == path) {
      if (priority.index < job.priority.index) job.priority = priority;
    } else {
      job = _Job(trackId, path, priority, persist: persist);
      _jobs.add(job);
    }
    _update();
    _wakeUp();
    if (!_running) unawaited(_pump());
    return job;
  }

  _Job? _takeNext() {
    if (_jobs.isEmpty) return null;
    var best = _jobs.first;
    for (final j in _jobs) {
      if (j.priority.index < best.priority.index) best = j;
    }
    _jobs.remove(best);
    return best;
  }

  bool get _mustWait {
    if (_paused) return true;
    final status = ref.read(playbackProvider).status;
    return status == PlaybackStatus.loading ||
        status == PlaybackStatus.buffering;
  }

  Future<void> _pump() async {
    _running = true;
    final config = ref.read(analysisQueueConfigProvider);
    try {
      while (ref.mounted) {
        if (_mustWait) {
          _wake = Completer<void>();
          // Re-checks playback status at least once a second.
          await _wake!.future.timeout(
            const Duration(seconds: 1),
            onTimeout: () {},
          );
          continue;
        }
        final job = _takeNext();
        if (job == null) break;
        await _run(job);
        if (_jobs.isNotEmpty && config.gap > Duration.zero) {
          await Future<void>.delayed(config.gap);
        }
      }
    } finally {
      _running = false;
      if (ref.mounted) _update(currentTrackId: () => null);
    }
  }

  Future<void> _run(_Job job) async {
    final generation = _generation;
    final store = ref.read(analysisStoreProvider);
    TrackAnalysis? result;
    var ok = false;
    final fingerprint = await _fingerprint(job.path);
    if (fingerprint != null) {
      if (job.persist && await store.isFresh(job.trackId, fingerprint)) {
        result = await store.read(job.trackId);
        ok = result != null;
      }
      if (!ok) {
        _update(currentTrackId: () => job.trackId);
        try {
          result = (await ref.read(analysisRunnerProvider)(job.path))
              .copyWith(source: fingerprint);
          ok = true;
          if (job.persist && ref.mounted && generation == _generation) {
            await store.write(job.trackId, result);
            if (ref.mounted) ref.invalidate(trackAnalysisProvider(job.trackId));
          }
        } on Object catch (e) {
          debugPrint('Analysis of ${job.trackId} failed: $e');
        }
      }
    }
    if (!ref.mounted || generation != _generation) {
      for (final w in job.waiters) {
        if (!w.isCompleted) w.complete(null);
      }
      return;
    }
    (ok ? _done : _failed).add(job.trackId);
    for (final w in job.waiters) {
      w.complete(ok ? result : null);
    }
    _update(
      currentTrackId: () => null,
      completed: state.completed + (ok ? 1 : 0),
      failed: state.failed + (ok ? 0 : 1),
    );
  }

  static Future<String?> _fingerprint(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  void _finishAll() {
    for (final job in _jobs) {
      for (final w in job.waiters) {
        if (!w.isCompleted) w.complete(null);
      }
    }
    _jobs.clear();
  }

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _update({
    String? Function()? currentTrackId,
    int? completed,
    int? failed,
  }) {
    if (!ref.mounted) return;
    state = state.copyWith(
      currentTrackId: currentTrackId,
      pending: _jobs.length,
      completed: completed,
      failed: failed,
      paused: _paused,
    );
  }
}
