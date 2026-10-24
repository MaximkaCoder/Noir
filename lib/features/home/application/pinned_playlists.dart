import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/settings/data/settings_repository.dart';

enum PinKind { local, youtube, youtubeLiked, favorites }

/// A collection pinned to Home.
@immutable
class PinnedRef {
  const PinnedRef(this.kind, [this.id = '']);

  factory PinnedRef.fromJson(Map<String, Object?> json) => PinnedRef(
    PinKind.values.byName(json['kind']! as String),
    json['id'] as String? ?? '',
  );

  static const favorites = PinnedRef(PinKind.favorites);
  static const youtubeLiked = PinnedRef(PinKind.youtubeLiked);

  final PinKind kind;
  final String id;

  /// Route of the collection's page.
  String get location => switch (kind) {
    PinKind.local => '/library/playlist/$id',
    PinKind.youtube => '/library/youtube/$id',
    PinKind.youtubeLiked => '/library/youtube/liked',
    PinKind.favorites => '/library/favorites',
  };

  Map<String, Object?> toJson() => {'kind': kind.name, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is PinnedRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

final pinnedProvider = NotifierProvider<PinnedController, List<PinnedRef>>(
  PinnedController.new,
);

/// Collections pinned to Home, most recent first. Stored on this device.
class PinnedController extends Notifier<List<PinnedRef>> {
  static const _key = 'pinned_collections';

  @override
  List<PinnedRef> build() {
    unawaited(_load());
    return const [];
  }

  bool isPinned(PinnedRef ref) => state.contains(ref);

  /// Pins or unpins; returns true when the item is now pinned.
  bool toggle(PinnedRef item) {
    final pinned = !state.contains(item);
    state = pinned ? [item, ...state] : [...state.where((r) => r != item)];
    unawaited(_save());
    return pinned;
  }

  Future<void> _load() async {
    final json = await ref.read(settingsRepositoryProvider).readJson(_key);
    final items = json?['items'] as List<Object?>?;
    if (items == null) return;
    try {
      state = [
        for (final i in items) PinnedRef.fromJson(i! as Map<String, Object?>),
      ];
    } on Object {
      state = const []; // Unreadable pins are not worth an error.
    }
  }

  Future<void> _save() => ref.read(settingsRepositoryProvider).writeJson(_key, {
    'items': [for (final r in state) r.toJson()],
  });
}
