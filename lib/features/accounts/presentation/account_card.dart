import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/presentation/save_target_picker.dart';
import 'package:noir/integrations/google_auth/google_oauth_config.dart';
import 'package:url_launcher/url_launcher.dart';

/// Google / YouTube connection: status, what is shared, sync, disconnect.
/// Explains the permissions before the browser opens.
class AccountConnectionCard extends ConsumerWidget {
  const AccountConnectionCard({super.key});

  static final _permissionsPage = Uri.https(
    'myaccount.google.com',
    '/permissions',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final service = ref.watch(accountServiceProvider);
    final account =
        ref.watch(accountConnectionProvider).value ?? service.current;
    final sync = ref.watch(youTubeSyncProvider);

    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: c.textSecondary),
          const SizedBox(width: NoirSpacing.sm),
          Expanded(child: Text(text, style: t.bodySmall)),
        ],
      ),
    );

    final status = switch (account.status) {
      AccountStatus.notConfigured => 'Not available in this build',
      AccountStatus.disconnected => 'Not connected',
      AccountStatus.connecting => 'Waiting for your browser…',
      AccountStatus.connected =>
        account.email ?? account.displayName ?? 'Connected',
      AccountStatus.needsReconnect => 'Session ended — connect again',
    };

    final actions = <Widget>[
      if (account.status == AccountStatus.disconnected ||
          account.status == AccountStatus.needsReconnect)
        PillButton(
          label: account.status == AccountStatus.needsReconnect
              ? 'Reconnect'
              : 'Connect Google account',
          icon: Icons.login_rounded,
          filled: true,
          onPressed: () => unawaited(service.connect()),
        ),
      if (account.status == AccountStatus.connecting)
        PillButton(
          label: 'Cancel',
          icon: Icons.close_rounded,
          onPressed: service.cancelConnect,
        ),
      if (account.status == AccountStatus.connected) ...[
        PillButton(
          label: sync.status == SyncStatus.syncing ? 'Syncing…' : 'Sync now',
          icon: Icons.sync_rounded,
          onPressed: sync.status == SyncStatus.syncing
              ? null
              : () => unawaited(
                  ref.read(youTubeSyncProvider.notifier).sync(force: true),
                ),
        ),
        PillButton(
          label: 'Disconnect',
          icon: Icons.logout_rounded,
          onPressed: () async {
            final ok = await confirm(
              context,
              title: 'Disconnect Google account?',
              message:
                  'NOIR revokes its access at Google and deletes every '
                  'YouTube playlist and video it saved on this device. '
                  'Nothing changes on YouTube.',
              confirmLabel: 'Disconnect',
              destructive: true,
            );
            if (ok) await service.disconnect();
          },
        ),
      ],
    ];

    final fx = NoirEffects.of(context);
    return GlassSurface(
      blur: 0,
      padding: const EdgeInsets.all(NoirSpacing.lg),
      // Connecting / connected swap whole sections; let the card resize.
      child: AnimatedSize(
        duration: fx.motion(NoirMotion.medium),
        curve: NoirMotion.standard,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: c.hover,
                  child: Icon(
                    Icons.play_circle_outline_rounded,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(width: NoirSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Google / YouTube', style: t.titleSmall),
                      AnimatedSwitcher(
                        duration: fx.motion(NoirMotion.medium),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [...previous, ?current],
                        ),
                        child: Text(
                          status,
                          key: ValueKey(status),
                          style: t.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (account.message != null) ...[
              const SizedBox(height: NoirSpacing.md),
              Text(
                account.message!,
                style: t.bodySmall?.copyWith(color: c.destructive),
              ),
            ],
            if (account.status == AccountStatus.connected) ...[
              const SizedBox(height: NoirSpacing.md),
              line(
                Icons.schedule_rounded,
                sync.lastSyncAt == null
                    ? 'Not synced yet'
                    : 'Last synced ${_ago(sync.lastSyncAt!)} · updates every '
                          '15 minutes while NOIR is open',
              ),
              if (sync.status == SyncStatus.failed && sync.message != null)
                line(Icons.error_outline_rounded, sync.message!),
              line(
                Icons.lock_outline_rounded,
                account.grantedScopes.contains(
                      GoogleOAuthConfig.playlistWriteScope,
                    )
                    ? 'Access: view and manage your YouTube account'
                    : 'Access: view your YouTube account (read-only)',
              ),
              if (account.canSaveToPlaylists)
                line(Icons.check_rounded, 'Can save to playlists'),
              const SizedBox(height: NoirSpacing.lg),
              const SaveTargetSetting(),
            ] else ...[
              const SizedBox(height: NoirSpacing.md),
              Text(
                'Connecting lets NOIR read your YouTube account. Here is what '
                "YouTube's official APIs allow:",
                style: t.bodySmall?.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: NoirSpacing.xs),
              line(
                Icons.check_rounded,
                'Your playlists (also those made in YouTube Music), liked '
                'videos and subscriptions — read-only.',
              ),
              line(
                Icons.check_rounded,
                'Playback through the official YouTube player, with the video '
                'visible.',
              ),
              line(
                Icons.close_rounded,
                'Saved albums, songs and artists from the YouTube Music '
                'library — no official API.',
              ),
              line(
                Icons.close_rounded,
                'Background, screen-off, audio-only or offline YouTube '
                'playback — not permitted.',
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: NoirSpacing.lg),
              Wrap(
                spacing: NoirSpacing.sm,
                runSpacing: NoirSpacing.sm,
                children: actions,
              ),
            ],
            const SizedBox(height: NoirSpacing.md),
            Text(
              'Sign-in happens in your browser — NOIR never sees your Google '
              'password. You can also revoke access at any time in your Google '
              'Account.',
              style: t.labelSmall,
            ),
            if (account.status != AccountStatus.notConfigured)
              TextButton(
                onPressed: () => unawaited(
                  launchUrl(
                    _permissionsPage,
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: c.textSecondary,
                  padding: EdgeInsets.zero,
                  textStyle: t.labelSmall,
                ),
                child: const Text('Open Google Account permissions'),
              ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
