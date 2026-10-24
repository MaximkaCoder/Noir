import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/reveal.dart';
import 'package:noir/features/accounts/presentation/account_card.dart';
import 'package:noir/features/home/data/history_repository.dart';
import 'package:noir/features/library/application/library_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/search/data/search_history_repository.dart';
import 'package:noir/features/settings/application/maintenance.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/privacy_notice.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/widgets/page_scaffold.dart';

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
                _ToggleTile(
                  icon: Icons.graphic_eq_rounded,
                  title: 'Crossfade',
                  subtitle:
                      'Smooth transition between tracks. Local music only.',
                  value: s.crossfadeSeconds > 0,
                  onChanged: (v) =>
                      set((s) => s.copyWith(crossfadeSeconds: v ? 6 : 0)),
                ),
                Reveal(
                  visible: s.crossfadeSeconds > 0,
                  child: _SliderTile(
                    label: 'Crossfade length',
                    value: s.crossfadeSeconds.toDouble(),
                    min: 1,
                    max: 12,
                    divisions: 11,
                    display: '${s.crossfadeSeconds} s',
                    onChanged: (v) =>
                        set((s) => s.copyWith(crossfadeSeconds: v.round())),
                  ),
                ),
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
                const _Section('Accounts'),
                const AccountConnectionCard(),
                const _Section('Library'),
                const _LibrarySettings(),
                const _Section('Experimental'),
                _ToggleTile(
                  icon: Icons.visibility_off_outlined,
                  title: 'Hide YouTube player',
                  subtitle:
                      'Plays YouTube as audio only and keeps playing when the '
                      "window is hidden. This breaks YouTube's API policies; "
                      "Google may revoke NOIR's access (your account is not "
                      'affected). For personal testing only.',
                  value: s.hideYouTubePlayer,
                  onChanged: (v) =>
                      set((s) => s.copyWith(hideYouTubePlayer: v)),
                ),
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
                child: GlassSurface(
                  interactive: true,
                  selected: value == mode,
                  blur: 0,
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
  });

  final IconData icon;
  final String title;
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
              Text(title, style: t.bodyMedium),
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
    this.min = 0,
    this.max = 1,
    this.divisions,
  });

  final String label;
  final double value;
  final String display;

  /// Null disables the slider.
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;

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
              min: min,
              max: max,
              divisions: divisions,
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
    final cache = ref.watch(artworkCacheSizeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (LibraryScanController.supportsFolders) ...[
          Text('Music folders', style: t.bodyMedium),
          const SizedBox(height: NoirSpacing.xs),
          if (folders.isEmpty)
            Text('No folders yet.', style: t.bodySmall)
          else
            for (final f in folders)
              Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: NoirSpacing.sm),
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
                            'Its songs leave your NOIR library. The files on '
                            'disk are not deleted.',
                        confirmLabel: 'Remove',
                      );
                      if (ok) await ctrl.removeFolder(f.path);
                    },
                  ),
                ],
              ),
          const SizedBox(height: NoirSpacing.md),
        ],
        Wrap(
          spacing: NoirSpacing.sm,
          runSpacing: NoirSpacing.sm,
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
            if (folders.isNotEmpty)
              PillButton(
                label: scan is Scanning ? 'Scanning…' : 'Rescan',
                icon: Icons.refresh_rounded,
                onPressed: scan is Scanning
                    ? null
                    : () => unawaited(ctrl.rescanAll()),
              ),
          ],
        ),
        const SizedBox(height: NoirSpacing.lg),
        _ActionRow(
          title: 'Artwork cache',
          detail: switch (cache) {
            AsyncData(:final value) => formatBytes(value),
            _ => '…',
          },
          action: 'Clear',
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
        _ActionRow(
          title: 'Search history',
          detail: 'Stored on this device',
          action: 'Clear',
          onPressed: () async {
            await ref.read(searchHistoryRepositoryProvider).clear();
            if (context.mounted) showToast(context, 'Search history cleared');
          },
        ),
        _ActionRow(
          title: 'Listening history',
          detail: 'Used for Recently played',
          action: 'Clear',
          onPressed: () async {
            final ok = await confirm(
              context,
              title: 'Clear listening history?',
              message: 'Recently played will be empty until you play again.',
              confirmLabel: 'Clear',
              destructive: true,
            );
            if (ok) await ref.read(historyRepositoryProvider).clear();
          },
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.detail,
    required this.action,
    required this.onPressed,
  });

  final String title;
  final String detail;
  final String action;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.bodyMedium),
                Text(detail, style: t.bodySmall),
              ],
            ),
          ),
          TextButton(
            onPressed: () => unawaited(onPressed()),
            style: TextButton.styleFrom(
              foregroundColor: context.noir.textPrimary,
            ),
            child: Text(action),
          ),
        ],
      ),
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
