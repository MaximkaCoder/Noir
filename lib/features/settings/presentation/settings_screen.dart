import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/shell/sidebar_hidden.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_press.dart';
import 'package:noir/features/accounts/presentation/account_card.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/playlists/application/playlist_providers.dart';
import 'package:noir/features/search/data/search_history_repository.dart';
import 'package:noir/features/settings/application/maintenance.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/privacy_notice.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';

/// Extra settings sections contributed by optional modules, shown after
/// Playback. Empty by default.
final settingsExtensionsProvider = Provider<List<WidgetBuilder>>(
  (ref) => const [],
);

/// Only settings with a real effect are shown.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    void set(AppSettings Function(AppSettings) f) => ctrl.update(f);

    return PageScaffold(
      title: 'Settings',
      slivers: [
        SliverToBoxAdapter(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Section('Appearance'),
                _ThemePicker(
                  value: s.themeMode,
                  onChanged: (m) => set((s) => s.copyWith(themeMode: m)),
                ),
                const SizedBox(height: NoirSpacing.md),
                _ChoiceTile<Density>(
                  icon: Icons.density_medium_rounded,
                  title: 'Density',
                  value: s.density,
                  options: const {
                    Density.comfortable: 'Comfortable',
                    Density.compact: 'Compact',
                  },
                  onChanged: (d) => set((s) => s.copyWith(density: d)),
                ),
                const _Section('Effects'),
                _ToggleTile(
                  icon: Icons.blur_on_rounded,
                  title: 'Liquid Glass',
                  subtitle:
                      'Translucent, blurred surfaces. Turn off for solid '
                      'surfaces and lower GPU use.',
                  value: s.liquidGlass,
                  onChanged: (v) => set((s) => s.copyWith(liquidGlass: v)),
                ),
                _SliderTile(
                  label: 'Glass',
                  value: s.glassLevel.toDouble(),
                  max: 100,
                  display: '${s.glassLevel}',
                  // Clearer glass: less tint and frost, more color and
                  // refraction. Only meaningful while Liquid Glass is on.
                  onChanged: s.liquidGlass
                      ? (v) => set((s) => s.copyWith(glassLevel: v.round()))
                      : null,
                ),
                _ToggleTile(
                  icon: Icons.animation_rounded,
                  title: 'Animations',
                  subtitle: MediaQuery.disableAnimationsOf(context)
                      ? 'Your system asks for reduced motion, so decorative '
                            'motion stays off.'
                      : 'Decorative motion and transitions.',
                  value: s.animations,
                  onChanged: (v) => set((s) => s.copyWith(animations: v)),
                ),
                _ToggleTile(
                  icon: Icons.speed_rounded,
                  title: 'Performance mode',
                  subtitle:
                      'Lighter blur and no ambient effects — for '
                      'integrated graphics and battery life.',
                  value: s.performanceMode == PerformanceMode.performance,
                  onChanged: (v) => set(
                    (s) => s.copyWith(
                      performanceMode: v
                          ? PerformanceMode.performance
                          : PerformanceMode.balanced,
                    ),
                  ),
                ),
                const _Section('Sound'),
                _SliderTile(
                  label: 'Volume at startup',
                  value: s.defaultVolume,
                  display: '${(s.defaultVolume * 100).round()}%',
                  onChanged: (v) => set((s) => s.copyWith(defaultVolume: v)),
                ),
                const _Section('Playback'),
                _ToggleTile(
                  icon: Icons.history_rounded,
                  title: 'Resume previous session',
                  subtitle: 'Reopen your queue where you left off (paused).',
                  value: s.resumeSession,
                  onChanged: (v) => set((s) => s.copyWith(resumeSession: v)),
                ),
                _ChoiceTile<PlayBehavior>(
                  icon: Icons.queue_music_rounded,
                  title: 'Playing a song from a list',
                  value: s.playBehavior,
                  options: const {
                    PlayBehavior.playContext: 'Queue the whole list',
                    PlayBehavior.playSingle: 'Play only that song',
                  },
                  onChanged: (b) => set((s) => s.copyWith(playBehavior: b)),
                ),
                _ChoiceTile<LyricsMode>(
                  icon: Icons.format_quote_rounded,
                  title: 'Lyrics style',
                  value: s.lyricsMode,
                  options: const {
                    LyricsMode.lines: 'Lines',
                    LyricsMode.karaoke: 'Karaoke',
                  },
                  onChanged: (m) => set((s) => s.copyWith(lyricsMode: m)),
                ),
                for (final section in ref.watch(settingsExtensionsProvider))
                  Builder(builder: section),
                const _Section('Accounts'),
                const AccountConnectionCard(),
                const _Section('Library'),
                const _LibrarySettings(),
                const _Section('Recommendations'),
                const _RecommendationSettings(),
                const _Section('Storage'),
                const _StorageSettings(),
                const _Section('About'),
                const _About(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: NoirSpacing.md),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.value, required this.onChanged});

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const options = [
      (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
      (ThemeMode.light, Icons.light_mode_outlined, 'Light'),
      (ThemeMode.system, Icons.desktop_windows_outlined, 'System'),
    ];
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final fx = NoirEffects.of(context);
    return Row(
      children: [
        for (final (mode, icon, label) in options) ...[
          Semantics(
            button: true,
            selected: value == mode,
            label: '$label theme',
            child: GestureDetector(
              onTap: () => onChanged(mode),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: LiquidPress(
                  pressedScale: 0.95,
                  bubbleScale: 1.06,
                  child: GlassSurface(
                    interactive: true,
                    selected: value == mode,
                    borderOpacity: value == mode ? 2.5 : 1,
                    child: SizedBox(
                      width: 104,
                      height: 76,
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TweenAnimationBuilder<Color?>(
                              tween: ColorTween(
                                end: value == mode
                                    ? c.textPrimary
                                    : c.textSecondary,
                              ),
                              duration: fx.motion(NoirMotion.medium),
                              builder: (_, color, _) =>
                                  Icon(icon, size: 20, color: color),
                            ),
                            const SizedBox(height: 6),
                            AnimatedDefaultTextStyle(
                              duration: fx.motion(NoirMotion.medium),
                              style: t.labelMedium!.copyWith(
                                color: value == mode ? c.textPrimary : null,
                              ),
                              child: Text(label),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: NoirSpacing.md),
        ],
      ],
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: context.noir.hover,
      border: Border.all(color: context.noir.glassBorder),
    ),
    child: Icon(icon, size: 18, color: context.noir.textSecondary),
  );
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: NoirRadii.mdAll,
        hoverDuration: NoirEffects.of(context).motion(NoirMotion.fast),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: NoirSpacing.sm,
            horizontal: NoirSpacing.xs,
          ),
          child: Row(
            children: [
              _IconBadge(icon),
              const SizedBox(width: NoirSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.bodyMedium),
                    const SizedBox(height: 2),
                    Text(subtitle, style: t.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: NoirSpacing.md),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: NoirSpacing.sm,
        horizontal: NoirSpacing.xs,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: NoirSpacing.md,
        runSpacing: NoirSpacing.sm,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _IconBadge(icon),
              const SizedBox(width: NoirSpacing.md),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.bodyMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: t.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            spacing: NoirSpacing.xs,
            children: [
              for (final MapEntry(:key, value: label) in options.entries)
                PillChip(
                  label: label,
                  selected: key == value,
                  onSelected: () => onChanged(key),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.display,
    required this.onChanged,
    this.max = 1,
  });

  final String label;
  final double value;
  final String display;

  /// Null disables the slider.
  final ValueChanged<double>? onChanged;
  final double max;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 52, right: NoirSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: onChanged == null
                  ? t.bodySmall?.copyWith(color: context.noir.textTertiary)
                  : t.bodySmall,
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              max: max,
              label: display,
              semanticFormatterCallback: (_) => display,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(display, style: t.bodySmall, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

class _LibrarySettings extends ConsumerWidget {
  const _LibrarySettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final folders = ref.watch(libraryFoldersProvider).value ?? const [];
    final scan = ref.watch(libraryScanProvider);
    final ctrl = ref.read(libraryScanProvider.notifier);
    final hidden = ref.watch(sidebarHiddenProvider).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ActionTile(
          icon: Icons.folder_outlined,
          title: 'Your music',
          subtitle: switch (folders.length) {
            _ when !LibraryScanController.supportsFolders =>
              'Add audio files from this device.',
            0 => 'Add a folder and NOIR keeps it in sync.',
            1 => '1 folder',
            final n => '$n folders',
          },
          trailing: Wrap(
            spacing: NoirSpacing.sm,
            children: [
              if (LibraryScanController.supportsFolders)
                PillButton(
                  label: 'Add folder',
                  icon: Icons.create_new_folder_outlined,
                  onPressed: scan is Scanning
                      ? null
                      : () => unawaited(ctrl.addFolder()),
                ),
              PillButton(
                label: 'Add files',
                icon: Icons.library_add_outlined,
                onPressed: scan is Scanning
                    ? null
                    : () => unawaited(ctrl.importFiles()),
              ),
            ],
          ),
        ),
        for (final f in folders)
          Padding(
            // Lines up with the tile's title.
            padding: const EdgeInsets.only(left: 52),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    f.path,
                    style: t.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                NoirIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Remove folder from library',
                  size: 16,
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Remove folder?',
                      message:
                          'Its songs leave your library. The files stay on '
                          'disk.',
                      confirmLabel: 'Remove',
                    );
                    if (ok) await ctrl.removeFolder(f.path);
                  },
                ),
              ],
            ),
          ),
        if (folders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 52, top: NoirSpacing.xs),
            child: PillButton(
              label: scan is Scanning ? 'Scanning…' : 'Rescan',
              icon: Icons.refresh_rounded,
              onPressed: scan is Scanning
                  ? null
                  : () => unawaited(ctrl.rescanAll()),
            ),
          ),
        _ActionTile(
          icon: Icons.visibility_off_outlined,
          title: 'Sidebar',
          subtitle: hidden == 0
              ? 'All your playlists are shown. Right-click one to hide it.'
              : '$hidden hidden from the sidebar, still in Library.',
          trailing: PillButton(
            label: 'Choose',
            onPressed: () => unawaited(
              showGlassDialog<void>(
                context,
                builder: (_) => const _SidebarDialog(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Recommendations: what the user said no to, and the listening history
/// they are built from.
class _RecommendationSettings extends ConsumerWidget {
  const _RecommendationSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dislikes = ref.watch(dislikesProvider);
    final songs = dislikes.songs.length;
    final artists = dislikes.artists.length;
    return Column(
      children: [
        _ActionTile(
          icon: Icons.thumb_down_alt_outlined,
          title: 'Not interested',
          subtitle: dislikes.isEmpty
              ? 'Songs and artists you hide from For you, Home and radio.'
              : [
                  if (songs == 1) '1 song' else if (songs > 1) '$songs songs',
                  if (artists == 1)
                    '1 artist'
                  else if (artists > 1)
                    '$artists artists',
                ].join(' · '),
          trailing: PillButton(
            label: 'Manage',
            onPressed: dislikes.isEmpty
                ? null
                : () => unawaited(
                    showGlassDialog<void>(
                      context,
                      builder: (_) => const _DislikesDialog(),
                    ),
                  ),
          ),
        ),
        _ActionTile(
          icon: Icons.history_rounded,
          title: 'Listening history',
          subtitle: 'Used for Recently played, Listen again and For you.',
          trailing: PillButton(
            label: 'Clear',
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Clear listening history?',
                message:
                    'Recently played will be empty until you play again, and '
                    'For you will rely on your likes and playlists only.',
                confirmLabel: 'Clear',
                destructive: true,
              );
              if (!ok) return;
              await ref.read(historyRepositoryProvider).clear();
              await ref.read(youTubePlayLogProvider).clear();
            },
          ),
        ),
      ],
    );
  }
}

/// Space NOIR uses on this device, and what it remembers.
class _StorageSettings extends ConsumerWidget {
  const _StorageSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.watch(artworkCacheSizeProvider);
    return Column(
      children: [
        _ActionTile(
          icon: Icons.storage_rounded,
          title: 'Artwork cache',
          subtitle: switch (cache) {
            AsyncData(:final value) => '${formatBytes(value)} of covers',
            _ => '…',
          },
          trailing: PillButton(
            label: 'Clear',
            onPressed: () async {
              final ok = await confirm(
                context,
                title: 'Clear artwork cache?',
                message:
                    'Covers are extracted again from your music folders. This '
                    'can take a while for large libraries.',
                confirmLabel: 'Clear',
              );
              if (ok) await clearArtworkCache(ref);
            },
          ),
        ),
        _ActionTile(
          icon: Icons.search_rounded,
          title: 'Search history',
          subtitle: 'Recent searches, kept on this device.',
          trailing: PillButton(
            label: 'Clear',
            onPressed: () async {
              await ref.read(searchHistoryRepositoryProvider).clear();
              if (context.mounted) showToast(context, 'Search history cleared');
            },
          ),
        ),
      ],
    );
  }
}

/// A setting with an action instead of a switch: same layout as the
/// toggles, with [trailing] (usually a pill button) on the right.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: NoirSpacing.sm,
        horizontal: NoirSpacing.xs,
      ),
      child: Row(
        children: [
          _IconBadge(icon),
          const SizedBox(width: NoirSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.bodyMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: t.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: NoirSpacing.md),
          trailing,
        ],
      ),
    );
  }
}

/// Checkboxes for every collection the sidebar can show.
class _SidebarDialog extends ConsumerWidget {
  const _SidebarDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final hidden = ref.watch(sidebarHiddenProvider);
    final ctrl = ref.read(sidebarHiddenProvider.notifier);
    final likes = ref.watch(youTubeLikesProvider).value ?? const [];
    final playlists = ref.watch(playlistsProvider).value ?? const [];
    final ytPlaylists = ref.watch(youTubePlaylistsProvider).value ?? const [];
    final entries = <(String, String)>[
      ('/library/favorites', 'Favorites'),
      for (final p in playlists) ('/library/playlist/${p.id}', p.name),
      if (likes.isNotEmpty) ('/library/youtube/liked', likedMusicTitle),
      for (final p in ytPlaylists) ('/library/youtube/${p.id}', p.title),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Show in sidebar', style: t.titleMedium),
        const SizedBox(height: NoirSpacing.sm),
        Text('Hidden playlists stay in Library.', style: t.bodySmall),
        const SizedBox(height: NoirSpacing.md),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (route, label) in entries)
                CheckboxListTile(
                  value: !hidden.contains(route),
                  onChanged: (v) => ctrl.setHidden(route, hidden: v != true),
                  title: Text(
                    label,
                    style: t.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
        const SizedBox(height: NoirSpacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

/// The songs and artists hidden from recommendations, each with a way back.
class _DislikesDialog extends ConsumerWidget {
  const _DislikesDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final dislikes = ref.watch(dislikesProvider);
    final ctrl = ref.read(dislikesProvider.notifier);

    Widget row(String title, String? subtitle, VoidCallback onUndo) => Padding(
      padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: t.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) Text(subtitle, style: t.bodySmall),
              ],
            ),
          ),
          TextButton(
            onPressed: onUndo,
            style: TextButton.styleFrom(foregroundColor: c.textPrimary),
            child: const Text('Allow'),
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Not interested', style: t.titleMedium),
        const SizedBox(height: NoirSpacing.sm),
        Text(
          "NOIR doesn't recommend these. Allowing a song also removes its "
          'dislike on YouTube.',
          style: t.bodySmall,
        ),
        const SizedBox(height: NoirSpacing.md),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final artist in dislikes.artists.values)
                row(artist, 'Artist', () => ctrl.unblockArtist(artist)),
              for (final song in dislikes.songs.values.toList().reversed)
                row(
                  song.title,
                  song.artist,
                  () => unawaited(ctrl.undoSong(song.videoId)),
                ),
            ],
          ),
        ),
        const SizedBox(height: NoirSpacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }
}

class _About extends ConsumerWidget {
  const _About();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final info = ref.watch(packageInfoProvider).value;
    final fx = NoirEffects.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          info == null
              ? 'Version'
              : 'Version ${info.version} (${info.buildNumber})',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 2),
        Text('Less interface. More music.', style: t.bodySmall),
        const SizedBox(height: NoirSpacing.md),
        Wrap(
          spacing: NoirSpacing.sm,
          runSpacing: NoirSpacing.sm,
          children: [
            PillButton(
              label: 'Privacy',
              icon: Icons.privacy_tip_outlined,
              onPressed: () => unawaited(showPrivacyNotice(context)),
            ),
            PillButton(
              label: 'Open-source licenses',
              icon: Icons.description_outlined,
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'NOIR',
                applicationVersion: info?.version,
              ),
            ),
            PillButton(
              label: 'Export diagnostics',
              icon: Icons.bug_report_outlined,
              onPressed: () => unawaited(_exportDiagnostics(context, ref)),
            ),
          ],
        ),
        if (!fx.animations && MediaQuery.disableAnimationsOf(context))
          Padding(
            padding: const EdgeInsets.only(top: NoirSpacing.md),
            child: Text('Reduced motion is on.', style: t.labelSmall),
          ),
      ],
    );
  }

  Future<void> _exportDiagnostics(BuildContext context, WidgetRef ref) async {
    final report = await buildDiagnostics(ref);
    final bytes = utf8.encode(report);
    Uri? saved;
    try {
      saved = await FilePicker.saveFile(
        dialogTitle: 'Save diagnostics',
        fileName: 'noir-diagnostics.json',
        mimeType: 'application/json',
        bytes: bytes,
      );
    } on Object {
      await Clipboard.setData(ClipboardData(text: report));
      if (context.mounted) {
        showToast(context, 'Diagnostics copied to clipboard');
      }
      return;
    }
    if (saved != null && context.mounted) {
      showToast(context, 'Diagnostics saved. They contain no personal data.');
    }
  }
}
