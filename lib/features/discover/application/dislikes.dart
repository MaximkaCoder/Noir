import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_pending_edits.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';

/// A YouTube song the user does not want recommended.
@immutable
class DislikedSong {
  const DislikedSong(this.videoId, this.title, this.artist);

  final String videoId;
  final String title;
  final String? artist;
}

/// What the user does not want to hear in recommendations: single songs
/// and whole artists. Applies to For you, Listen again, Home shelves and
/// radio, not to search or the user's own playlists.
@immutable
class Dislikes {
  const Dislikes({this.songs = const {}, this.artists = const {}});

  factory Dislikes.fromJson(Map<String, Object?> json) => Dislikes(
    songs: {
      for (final e in json['songs'] as List<Object?>? ?? const [])
        if (e case {'v': final String v, 't': final String t})
          v: DislikedSong(v, t, e['a'] as String?),
    },
    artists: {
      for (final a in json['artists'] as List<Object?>? ?? const [])
        if (a is String) _key(a): a,
    },
  );

  /// Video id → song, most recent last.
  final Map<String, DislikedSong> songs;

  /// Lowercased artist → name as shown.
  final Map<String, String> artists;

  static String _key(String? artist) => artist?.trim().toLowerCase() ?? '';

  bool get isEmpty => songs.isEmpty && artists.isEmpty;

  /// Whether [track] must not be recommended.
  bool hides(Track track) =>
      songs.containsKey(track.uri) || artists.containsKey(_key(track.artist));

  /// Disliked songs by [track]'s artist: each makes the artist rarer.
  int strikes(Track track) {
    final key = _key(track.artist);
    if (key.isEmpty) return 0;
    return songs.values.where((s) => _key(s.artist) == key).length;
  }

  Map<String, Object?> toJson() => {
    'songs': [
      for (final s in songs.values)
        {'v': s.videoId, 't': s.title, 'a': ?s.artist},
    ],
    'artists': artists.values.toList(),
  };
}

final dislikesProvider = NotifierProvider<DislikesController, Dislikes>(
  DislikesController.new,
);

/// Stores [Dislikes] on this device. A disliked song is also disliked on
/// YouTube when the account allows it (the same permission as playlist
/// edits); without an account it stays a NOIR-only choice.
class DislikesController extends Notifier<Dislikes> {
  static const storageKey = 'dislikes';

  bool _changed = false;

  @override
  Dislikes build() {
    unawaited(_load());
    return const Dislikes();
  }

  /// Hides [track] from recommendations and skips it when it is playing.
  /// Returns whether YouTube got the dislike too.
  Future<bool> dislikeSong(Track track) async {
    _set(
      Dislikes(
        songs: {
          ...state.songs,
          track.uri: DislikedSong(track.uri, track.title, track.artist),
        },
        artists: state.artists,
      ),
    );
    await _skipIfPlaying(track);
    return await _rate(track.uri, YtRating.dislike);
  }

  Future<void> undoSong(String videoId) async {
    if (!state.songs.containsKey(videoId)) return;
    _set(
      Dislikes(
        songs: {...state.songs}..remove(videoId),
        artists: state.artists,
      ),
    );
    await _rate(videoId, YtRating.none);
  }

  /// Never recommends [artist] again; skips the playing song if it is theirs.
  Future<void> blockArtist(String artist, {Track? playing}) async {
    _set(
      Dislikes(
        songs: state.songs,
        artists: {...state.artists, Dislikes._key(artist): artist},
      ),
    );
    if (playing != null) await _skipIfPlaying(playing);
  }

  void unblockArtist(String artist) => _set(
    Dislikes(
      songs: state.songs,
      artists: {...state.artists}..remove(Dislikes._key(artist)),
    ),
  );

  void _set(Dislikes next) {
    _changed = true;
    state = next;
    unawaited(
      ref.read(settingsRepositoryProvider).writeJson(storageKey, next.toJson()),
    );
  }

  Future<void> _skipIfPlaying(Track track) async {
    // Nothing plays before the player exists; do not start it here.
    if (!ref.exists(playbackProvider)) return;
    final playback = ref.read(playbackProvider);
    final index = playback.index;
    if (index == null || playback.queue[index].track.uri != track.uri) return;
    await ref.read(playbackProvider.notifier).next();
  }

  /// Sends [rating] when the account may rate; failures stay quiet (the
  /// NOIR side already applies).
  Future<bool> _rate(String videoId, YtRating rating) async {
    final account = ref.read(accountServiceProvider).current;
    if (!account.isConnected || !account.canSaveToPlaylists) return false;
    try {
      await ref.read(youTubeApiProvider).rate(videoId, rating);
    } on YouTubeApiException catch (e) {
      debugPrint('YouTube rating failed: ${e.kind.name}');
      return false;
    }
    // A dislike replaces a like on YouTube.
    if (rating == YtRating.dislike &&
        await ref.read(youTubeRepositoryProvider).removeLike(videoId) != null) {
      ref.read(youTubePendingEditsProvider).removed(likedVideosId, videoId);
    }
    return true;
  }

  Future<void> _load() async {
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(storageKey);
    // A change made while loading wins over the stored list.
    if (json == null || _changed || !ref.mounted) return;
    try {
      state = Dislikes.fromJson(json);
    } on Object {
      // Unreadable: start over rather than fail.
    }
  }
}
