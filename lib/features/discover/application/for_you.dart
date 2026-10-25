import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

// ------------------------------------------------------------- play log --

final youTubePlayLogProvider = Provider<YouTubePlayLog>(
  (ref) => YouTubePlayLog(ref.watch(settingsRepositoryProvider)),
);

/// One YouTube song played in NOIR.
@immutable
class YouTubePlay {
  const YouTubePlay(this.track, this.at);

  final Track track;
  final DateTime at;
}

/// The YouTube songs played in NOIR, newest first, for "For you". Kept on
/// this device only (like the local listening history) and never sent
/// anywhere: recommendations ask YouTube Music anonymously about single
/// songs.
class YouTubePlayLog {
  YouTubePlayLog(this._settings);

  final SettingsRepository _settings;

  static const storageKey = 'youtube_play_log';
  static const maxEntries = 300;

  Future<void> record(Track track) async {
    if (track.source != MediaSource.youtube || track.uri.isEmpty) return;
    final plays = await read();
    final next = [YouTubePlay(track, DateTime.now()), ...plays];
    await _settings.writeJson(storageKey, {
      'plays': [
        for (final p in next.take(maxEntries))
          {
            'v': p.track.uri,
            't': p.track.title,
            'a': p.track.artist,
            'at': p.at.toIso8601String(),
          },
      ],
    });
  }

  Future<List<YouTubePlay>> read() async {
    final json = await _settings.readJson(storageKey);
    final raw = json?['plays'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e case {
          'v': final String v,
          't': final String t,
          'at': final String at,
        })
          if (DateTime.tryParse(at) case final playedAt?)
            YouTubePlay(
              Track(
                id: 'yt:$v',
                source: MediaSource.youtube,
                title: t,
                uri: v,
                artist: e['a'] as String?,
                artworkUrl: YouTubeCover.thumbnail(v),
              ),
              playedAt,
            ),
    ];
  }

  Future<void> clear() => _settings.delete(storageKey);
}

// --------------------------------------------------------- listen again --

/// Home's first shelf, like YouTube Music's "Listen again": the songs the
/// user played most (and most recently) in NOIR, YouTube and local alike.
/// Rebuilt after each play.
final listenAgainProvider = FutureProvider<List<Track>>((ref) async {
  final plays = await ref.read(youTubePlayLogProvider).read();
  final local = await ref.read(historyRepositoryProvider).recentTracks();
  return listenAgain(plays, local, DateTime.now());
});

/// [plays] ranked like [tasteSeeds] does (each play counts, fading over two
/// weeks), with the recently played local songs taking turns with them.
List<Track> listenAgain(
  List<YouTubePlay> plays,
  List<Track> local,
  DateTime now, {
  int length = 20,
}) {
  final youTube = [
    for (final s in tasteSeeds(
      plays: plays,
      likes: const [],
      playlistTracks: const [],
      now: now,
    ))
      s.track,
  ];
  return [
    for (var i = 0; i < max(youTube.length, local.length); i++) ...[
      if (i < youTube.length) youTube[i],
      if (i < local.length) local[i],
    ],
  ].take(length).toList();
}

// ---------------------------------------------------------------- seeds --

/// A song recommendations start from, and how much it says about the
/// user's taste.
@immutable
class TasteSeed {
  const TasteSeed(this.track, this.weight);

  final Track track;
  final double weight;
}

/// Weighs what the user plays and keeps: every play counts, fading over two
/// weeks; liked songs count by how recently they were liked; songs in
/// their playlists count a little.
List<TasteSeed> tasteSeeds({
  required List<YouTubePlay> plays,
  required List<Track> likes,
  required List<Track> playlistTracks,
  required DateTime now,
}) {
  final weights = <String, double>{};
  final tracks = <String, Track>{};
  void add(Track t, double w) {
    if (t.uri.isEmpty) return;
    tracks.putIfAbsent(t.uri, () => t);
    weights[t.uri] = (weights[t.uri] ?? 0) + w;
  }

  for (final p in plays) {
    final days = now.difference(p.at).inHours / 24;
    add(p.track, exp(-days / 14));
  }
  for (final (i, t) in likes.indexed) {
    add(t, 0.8 * exp(-i / 40));
  }
  for (final t in playlistTracks) {
    add(t, 0.15);
  }
  return [for (final e in weights.entries) TasteSeed(tracks[e.key]!, e.value)]
    ..sort((a, b) => b.weight.compareTo(a.weight));
}

/// Draws [count] seeds, likelier the heavier they are, at most one per
/// artist. The same [random] seed draws the same songs (one draw per day).
List<Track> pickSeeds(List<TasteSeed> seeds, int count, Random random) {
  final pool = [...seeds];
  final picked = <Track>[];
  final artists = <String>{};
  while (picked.length < count && pool.isNotEmpty) {
    final total = pool.fold<double>(0, (sum, s) => sum + s.weight);
    var r = random.nextDouble() * total;
    var i = 0;
    while (i < pool.length - 1 && r >= pool[i].weight) {
      r -= pool[i].weight;
      i++;
    }
    final seed = pool.removeAt(i);
    final artist = seed.track.artist?.toLowerCase() ?? '';
    if (artist.isNotEmpty && !artists.add(artist)) continue;
    picked.add(seed.track);
  }
  return picked;
}

// ----------------------------------------------------------------- feed --

@immutable
class ForYouFeed {
  const ForYouFeed({required this.shelves, required this.fetchedAt});

  final List<YtmShelf> shelves;
  final DateTime fetchedAt;
}

/// Radio for each seed: the seed → the songs YouTube Music suggests after it.
typedef SeedRadio = ({Track seed, List<Track> tracks});

/// "Mixed for you" (every seed's suggestions taking turns) and, for the
/// first [becauseCount] seeds, "Because you listen to …" shelves. Songs in
/// [known] (the user's own) and repeats are left out.
List<YtmShelf> composeForYou(
  List<SeedRadio> radios,
  Set<String> known, {
  int mixLength = 40,
  int becauseCount = 3,
  int shelfLength = 20,
}) {
  final fresh = [
    for (final r in radios)
      (
        seed: r.seed,
        tracks: [
          for (final t in r.tracks)
            if (t.uri != r.seed.uri && !known.contains(t.uri)) t,
        ],
      ),
  ];
  final seen = <String>{};
  final mix = <Track>[];
  for (var i = 0; mix.length < mixLength; i++) {
    var any = false;
    for (final r in fresh) {
      if (i >= r.tracks.length) continue;
      any = true;
      if (seen.add(r.tracks[i].uri)) mix.add(r.tracks[i]);
      if (mix.length == mixLength) break;
    }
    if (!any) break;
  }
  return [
    if (mix.isNotEmpty)
      YtmShelf(
        title: 'Mixed for you',
        strapline: 'From what you play and like',
        items: [for (final t in mix) YtmTrackItem(t)],
      ),
    for (final r in fresh.take(becauseCount))
      if (r.tracks.length >= 6)
        YtmShelf(
          title: r.seed.artist == null
              ? r.seed.title
              : '${r.seed.title} · ${r.seed.artist}',
          strapline: 'Because you listen to',
          items: [for (final t in r.tracks.take(shelfLength)) YtmTrackItem(t)],
        ),
  ];
}

final forYouProvider = AsyncNotifierProvider<ForYouController, ForYouFeed>(
  ForYouController.new,
  retry: (_, _) => null,
);

/// Recommendations from the user's own taste without their account:
/// seeds come from local data (plays in NOIR, the synced likes and
/// playlists), and YouTube Music is asked anonymously for each seed's
/// radio. The seeds change once a day.
class ForYouController extends AsyncNotifier<ForYouFeed> {
  static const maxAge = Duration(hours: 6);
  static const seedCount = 6;

  int _generation = 0;

  @override
  Future<ForYouFeed> build() => _fetch(DateTime.now());

  /// Rebuilds when older than [maxAge], or always with [force] (new seeds).
  Future<void> refresh({bool force = false}) async {
    final current = state.value;
    if (!force &&
        current != null &&
        DateTime.now().difference(current.fetchedAt) < maxAge) {
      return;
    }
    final generation = ++_generation;
    final feed = await _fetch(DateTime.now(), reshuffle: force);
    // Offline: every radio failed. Keep what is shown.
    if (feed.shelves.isEmpty && (current?.shelves.isNotEmpty ?? false)) return;
    if (ref.mounted && generation == _generation) state = AsyncData(feed);
  }

  int _reshuffles = 0;

  Future<ForYouFeed> _fetch(DateTime now, {bool reshuffle = false}) async {
    if (reshuffle) _reshuffles++;
    final repo = ref.read(youTubeRepositoryProvider);
    final plays = await ref.read(youTubePlayLogProvider).read();
    final likes = await repo.likes(musicOnly: true);
    final playlistTracks = await repo.allPlaylistTracks();
    final seeds = pickSeeds(
      tasteSeeds(
        plays: plays,
        likes: likes,
        playlistTracks: playlistTracks,
        now: now,
      ),
      seedCount,
      Random(now.year * 10000 + now.month * 100 + now.day + _reshuffles),
    );
    final client = ref.read(innerTubeClientProvider);
    final radios = await Future.wait([
      for (final seed in seeds)
        client
            .radio(seed.uri)
            .then<SeedRadio?>((page) => (seed: seed, tracks: page.tracks))
            // One seed failing leaves the others.
            .catchError(
              (Object _) => null,
              test: (e) => e is InnerTubeException,
            ),
    ]);
    final known = {
      ...await repo.referencedVideoIds(),
      for (final p in plays.take(50)) p.track.uri,
    };
    return ForYouFeed(
      shelves: composeForYou([...radios.nonNulls], known),
      fetchedAt: DateTime.now(),
    );
  }
}
