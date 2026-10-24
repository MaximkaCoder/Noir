import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

/// Settings loaded before `runApp` so the first frame already uses the
/// persisted theme and effects. Overridden in bootstrap and tests.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

/// Applies changes immediately and persists them in the background.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  void update(AppSettings Function(AppSettings current) change) {
    final next = change(state);
    if (next == state) return;
    state = next;
    unawaited(ref.read(settingsRepositoryProvider).saveSettings(next));
  }
}
