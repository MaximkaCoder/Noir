import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/shared/models/media.dart';

/// YouTube videos that failed to play here for a reason of their own
/// (removed, or the owner allows them only on YouTube).
@immutable
class UnplayableTracks {
  const UnplayableTracks([this._found = const {}]);

  factory UnplayableTracks.fromJson(Map<String, Object?> json, DateTime now) =>
      UnplayableTracks({
        for (final e in json['tracks'] as List<Object?>? ?? const [])
          if (e case {
            'v': final String v,
            'm': final String m,
            'at': final String at,
          })
            if (DateTime.tryParse(at) case final found?
                when now.difference(found) <
                    UnplayableTracksController.retryAfter)
              v: (message: m, at: found),
      });

  /// Video id → why it can't play, and when that was found.
  final Map<String, ({String message, DateTime at})> _found;

  /// Why [track] can't play, or null when it may.
  String? reasonFor(Track track) =>
      track.source == MediaSource.youtube ? _found[track.uri]?.message : null;

  Map<String, Object?> toJson() => {
    'tracks': [
      for (final MapEntry(key: v, value: e) in _found.entries)
        {'v': v, 'm': e.message, 'at': e.at.toIso8601String()},
    ],
  };
}

final unplayableTracksProvider =
    NotifierProvider<UnplayableTracksController, UnplayableTracks>(
      UnplayableTracksController.new,
    );

/// Remembers [UnplayableTracks] on this device so lists can grey them out
/// and the queue can pass over them.
class UnplayableTracksController extends Notifier<UnplayableTracks> {
  static const storageKey = 'unplayable_tracks';

  /// Owners change their minds; such a video is tried again after this.
  static const retryAfter = Duration(days: 30);

  bool _changed = false;

  @override
  UnplayableTracks build() {
    unawaited(_load());
    return const UnplayableTracks();
  }

  Future<void> _load() async {
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(storageKey);
    if (json == null || _changed || !ref.mounted) return;
    state = UnplayableTracks.fromJson(json, DateTime.now());
  }

  void add(Track track, String message) {
    if (track.source != MediaSource.youtube) return;
    _changed = true;
    state = UnplayableTracks({
      ...state._found,
      track.uri: (message: message, at: DateTime.now()),
    });
    unawaited(
      ref
          .read(settingsRepositoryProvider)
          .writeJson(storageKey, state.toJson()),
    );
  }
}
