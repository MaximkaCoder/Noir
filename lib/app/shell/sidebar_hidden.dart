import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/settings/data/settings_repository.dart';

final sidebarHiddenProvider =
    NotifierProvider<SidebarHiddenController, Set<String>>(
      SidebarHiddenController.new,
    );

/// Routes of the collections (Favorites, playlists) the user took off the
/// sidebar. They stay in Library. Stored on this device.
class SidebarHiddenController extends Notifier<Set<String>> {
  static const storageKey = 'sidebar_hidden';

  bool _changed = false;

  @override
  Set<String> build() {
    unawaited(_load());
    return const {};
  }

  void setHidden(String route, {required bool hidden}) {
    _changed = true;
    state = hidden ? {...state, route} : ({...state}..remove(route));
    unawaited(
      ref.read(settingsRepositoryProvider).writeJson(storageKey, {
        'routes': state.toList(),
      }),
    );
  }

  Future<void> _load() async {
    final json = await ref
        .read(settingsRepositoryProvider)
        .readJson(storageKey);
    final routes = json?['routes'];
    // A change made while loading wins over the stored set.
    if (routes is! List || _changed || !ref.mounted) return;
    state = {
      for (final r in routes)
        if (r is String) r,
    };
  }
}
