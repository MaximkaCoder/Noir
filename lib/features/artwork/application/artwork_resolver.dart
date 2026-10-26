import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:noir/features/artwork/data/artwork_cache_store.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

/// The YouTube Music lookups the resolver needs.
abstract interface class ArtworkLookup {
  /// `music/get_queue` for up to [InnerTubeClient.queueBatchSize] ids.
  Future<Map<String, YtmQueueEntry>> queue(List<String> videoIds);

  /// Song search results for [query], best match first.
  Future<List<Track>> songs(String query);
}

/// [ArtworkLookup] over the anonymous InnerTube client.
class InnerTubeArtworkLookup implements ArtworkLookup {
  const InnerTubeArtworkLookup(this._client);

  final InnerTubeClient _client;

  @override
  Future<Map<String, YtmQueueEntry>> queue(List<String> videoIds) =>
      _client.queue(videoIds);

  @override
  Future<List<Track>> songs(String query) async {
    final page = await _client.search(query);
    return [
      for (final item in page.items)
        if (item is YtmTrackItem && !item.isVideo) item.track,
    ];
  }
}

/// Finds square album art for YouTube videos, the way YouTube Music shows
/// it, instead of crops of 16:9 video thumbnails.
///
/// - Songs ("Art Tracks", "Artist - Topic") get their googleusercontent
///   art from `music/get_queue`, asked for in batches: requests made within
///   [batchWindow] are collected and deduplicated, one batch is in flight
///   at a time.
/// - Music videos get the art of their audio twin: the top song search
///   result, accepted only if it is clearly the same recording
///   ([acceptsCounterpart]). At most [maxSearches] searches run at once,
///   [searchSpacing] apart.
/// - Failures back off exponentially; nothing is cached for them.
/// - Answers persist in [ArtworkCacheStore] (at most [maxEntries]); "no
///   square art" answers expire after [noArtTtl] so they are retried.
class ArtworkResolver {
  ArtworkResolver({
    required ArtworkLookup this._lookup,
    this._store,
    DateTime Function()? clock,
    this.batchWindow = const Duration(milliseconds: 150),
    this.searchSpacing = const Duration(milliseconds: 250),
    this.maxSearches = 2,
    this.saveDelay = const Duration(seconds: 2),
    this.maxEntries = 10000,
    this.noArtTtl = const Duration(days: 14),
    this.retryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now {
    if (_store != null) unawaited(_ensureLoaded());
  }

  /// Resolves nothing: every video keeps its thumbnail (or [seed]).
  ArtworkResolver.offline([Map<String, ResolvedArt> seed = const {}])
    : this._offline(seed);

  ArtworkResolver._offline(Map<String, ResolvedArt> seed)
    : _lookup = null,
      _store = null,
      _clock = DateTime.now,
      batchWindow = Duration.zero,
      searchSpacing = Duration.zero,
      maxSearches = 0,
      saveDelay = Duration.zero,
      maxEntries = 10000,
      noArtTtl = const Duration(days: 14),
      retryDelay = Duration.zero,
      maxRetryDelay = Duration.zero {
    _entries.addAll(seed);
  }

  final ArtworkLookup? _lookup;
  final ArtworkCacheStore? _store;
  final DateTime Function() _clock;

  final Duration batchWindow;
  final Duration searchSpacing;
  final int maxSearches;
  final Duration saveDelay;
  final int maxEntries;
  final Duration noArtTtl;
  final Duration retryDelay;
  final Duration maxRetryDelay;

  /// Tries per video and session before giving up on failing lookups.
  static const _maxAttempts = 3;

  /// Answers in least-recently-resolved order (for eviction).
  final _entries = <String, ResolvedArt>{};
  final _listeners = <String, List<ValueChanged<ResolvedArt>>>{};

  /// Waiting for the next get_queue batch.
  final _queued = <String>{};

  /// In a get_queue batch or waiting for / running a counterpart search.
  final _working = <String>{};
  final _attempts = <String, int>{};
  final _searches = Queue<YtmQueueEntry>();
  int _searching = 0;

  Timer? _batchTimer;
  bool _batchRunning = false;
  Timer? _searchTimer;
  int _failures = 0;
  DateTime? _pausedUntil;

  Future<void>? _loaded;
  Timer? _saveTimer;
  Future<void>? _saving;
  bool _dirty = false;
  bool _disposed = false;

  // ------------------------------------------------------------- public --

  /// What is known about [videoId] so far (possibly an expired "none").
  ResolvedArt? peek(String videoId) => _entries[videoId];

  /// URL for a square of [px] physical pixels: the album art when known,
  /// otherwise the YouTube thumbnail to crop it from.
  String url(String videoId, double px) =>
      _entries[videoId]?.squareUrl(px) ??
      youtubeFrameUrl(videoId, youtubeFrame(px));

  /// Calls [onResolved] whenever art for [videoId] is found or changes,
  /// and looks it up if it is unknown or expired. Returns a canceller.
  VoidCallback listen(String videoId, ValueChanged<ResolvedArt> onResolved) {
    (_listeners[videoId] ??= []).add(onResolved);
    request(videoId);
    return () {
      final list = _listeners[videoId];
      if (list == null) return;
      list.remove(onResolved);
      if (list.isEmpty) _listeners.remove(videoId);
    };
  }

  /// Looks [videoId] up unless a fresh answer is known or one is pending.
  void request(String videoId) {
    if (_lookup == null || _disposed) return;
    if (_isFresh(videoId) || _working.contains(videoId)) return;
    if ((_attempts[videoId] ?? 0) >= _maxAttempts) return;
    if (_queued.add(videoId)) _scheduleBatch();
  }

  /// Saves pending changes and stops all work.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _batchTimer?.cancel();
    _searchTimer?.cancel();
    _saveTimer?.cancel();
    _listeners.clear();
    if (_dirty) unawaited(_save());
    await _saving;
  }

  // ------------------------------------------------------------ batches --

  bool _isFresh(String videoId) {
    final art = _entries[videoId];
    if (art == null) return false;
    return !art.isVideoThumb || _clock().difference(art.checkedAt) < noArtTtl;
  }

  Duration _untilResumed() {
    final until = _pausedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  void _scheduleBatch() {
    if (_disposed || _batchRunning || _batchTimer != null) return;
    if (_queued.isEmpty) return;
    final wait = _untilResumed();
    _batchTimer = Timer(wait > batchWindow ? wait : batchWindow, _runBatch);
  }

  Future<void> _runBatch() async {
    _batchTimer = null;
    if (_disposed) return;
    _batchRunning = true;
    try {
      await _ensureLoaded();
      if (_disposed) return;
      _queued.removeWhere(_isFresh);
      final ids = _queued.take(InnerTubeClient.queueBatchSize).toList();
      if (ids.isEmpty) return;
      _queued.removeAll(ids);
      _working.addAll(ids);
      final Map<String, YtmQueueEntry> found;
      try {
        found = await _lookup!.queue(ids);
      } on Object catch (e) {
        _failed(ids, e);
        return;
      }
      _failures = 0;
      if (_disposed) return;
      for (final id in ids) {
        final entry = found[id];
        final square = entry == null ? null : squareArtOf(entry);
        if (entry != null && square != null) {
          _resolve(id, _answer(entry, square));
        } else if (entry != null && counterpartQuery(entry) != null) {
          _searches.add(entry);
        } else {
          // Unknown to YouTube Music (private, removed) or untitled.
          _resolve(id, ResolvedArt.none(checkedAt: _clock()));
        }
      }
      _pumpSearches();
    } finally {
      _batchRunning = false;
      _scheduleBatch();
    }
  }

  // ----------------------------------------------------------- searches --

  void _pumpSearches() {
    if (_disposed || _searchTimer != null) return;
    if (_searches.isEmpty || _searching >= maxSearches) return;
    final wait = _untilResumed();
    if (wait > Duration.zero) {
      _searchTimer = Timer(wait, () {
        _searchTimer = null;
        _pumpSearches();
      });
      return;
    }
    _searching++;
    unawaited(_search(_searches.removeFirst()));
    // The next one starts a little later, never in a burst.
    _searchTimer = Timer(searchSpacing, () {
      _searchTimer = null;
      _pumpSearches();
    });
  }

  Future<void> _search(YtmQueueEntry video) async {
    final id = video.videoId;
    try {
      final songs = await _lookup!.songs(counterpartQuery(video)!);
      _failures = 0;
      final top = songs.firstOrNull;
      final art = top != null && acceptsCounterpart(video, top)
          ? googleArtBase(top.artworkUrl!)
          : null;
      _resolve(id, _answer(video, art));
    } on Object catch (e) {
      _failed([id], e);
    } finally {
      _searching--;
      _pumpSearches();
    }
  }

  // ------------------------------------------------------------ results --

  ResolvedArt _answer(YtmQueueEntry entry, String? squareBase) => ResolvedArt(
    squareBase: squareBase,
    checkedAt: _clock(),
    links: entry.links,
    videoType: entry.videoType,
  );

  void _failed(List<String> ids, Object error) {
    _failures++;
    final delay = retryDelay * math.pow(2, _failures - 1).toInt();
    _pausedUntil = _clock().add(delay > maxRetryDelay ? maxRetryDelay : delay);
    debugPrint('Artwork lookup failed ($error); retrying later.');
    _working.removeAll(ids);
    for (final id in ids) {
      _attempts[id] = (_attempts[id] ?? 0) + 1;
      request(id);
    }
  }

  void _resolve(String videoId, ResolvedArt art) {
    _working.remove(videoId);
    if (_disposed) return;
    _entries
      ..remove(videoId)
      ..[videoId] = art;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    for (final listener in [...?_listeners[videoId]]) {
      listener(art);
    }
    _dirty = true;
    _saveTimer ??= Timer(saveDelay, () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  // -------------------------------------------------------- persistence --

  Future<void> _ensureLoaded() => _loaded ??= _load();

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    final saved = await store.load();
    final now = _clock();
    // Saved answers go first (older), anything resolved meanwhile wins.
    final merged = <String, ResolvedArt>{};
    for (final e in saved.entries) {
      final art = e.value;
      if (art.isVideoThumb && now.difference(art.checkedAt) >= noArtTtl) {
        continue;
      }
      merged[e.key] = art;
    }
    for (final e in _entries.entries) {
      merged
        ..remove(e.key)
        ..[e.key] = e.value;
    }
    _entries
      ..clear()
      ..addAll(merged);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    for (final id in [..._listeners.keys]) {
      final art = saved[id];
      if (art != null && _entries[id] == art) {
        for (final listener in [...?_listeners[id]]) {
          listener(art);
        }
      }
    }
  }

  /// Queues a save after any running one, so writes never overlap.
  Future<void> _save() => _saving = (_saving ?? Future.value()).then((_) async {
    final store = _store;
    if (store == null) return;
    await _ensureLoaded();
    _dirty = false;
    await store.save(Map.of(_entries));
  });
}
