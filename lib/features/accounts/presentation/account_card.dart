import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';

/// Google / YouTube connection status with an honest summary of what the
/// official APIs allow (see docs/youtube-capability-matrix.md).
class AccountConnectionCard extends ConsumerWidget {
  const AccountConnectionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final status =
        ref.watch(accountConnectionProvider).value?.status ??
        AccountStatus.notConfigured;

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

    return GlassSurface(
      blur: 0,
      padding: const EdgeInsets.all(NoirSpacing.lg),
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
                    Text(
                      status == AccountStatus.notConfigured
                          ? 'Not available in this version'
                          : status.name,
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NoirSpacing.md),
          Text(
            'Connecting a Google account is planned for a later version. '
            "Here is what YouTube's official APIs will and won't allow:",
            style: t.bodySmall?.copyWith(color: c.textPrimary),
          ),
          const SizedBox(height: NoirSpacing.xs),
          line(
            Icons.check_rounded,
            'Your YouTube playlists, liked videos and subscriptions '
            '(read-only by default).',
          ),
          line(
            Icons.check_rounded,
            'Playback through the official YouTube player, with the '
            'video visible.',
          ),
          line(
            Icons.check_rounded,
            'YouTube search, limited to a small daily quota shared by '
            'all NOIR users.',
          ),
          line(
            Icons.close_rounded,
            'YouTube Music library (saved albums, songs, artists) — '
            'no official API.',
          ),
          line(
            Icons.close_rounded,
            'Background, screen-off or audio-only YouTube playback — '
            'not permitted.',
          ),
          line(
            Icons.close_rounded,
            'Downloading YouTube content for offline use — not '
            'permitted.',
          ),
          const SizedBox(height: NoirSpacing.md),
          Text(
            'NOIR will never ask for your Google password; sign-in happens in '
            'your browser and you can revoke access at any time at '
            'myaccount.google.com/permissions.',
            style: t.labelSmall,
          ),
        ],
      ),
    );
  }
}
