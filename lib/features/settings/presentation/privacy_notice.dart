import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/dialogs.dart';

/// Concise in-app privacy notice. Full text: docs/privacy.md.
Future<void> showPrivacyNotice(BuildContext context) => showGlassDialog<void>(
  context,
  builder: (context) {
    final t = Theme.of(context).textTheme;
    Widget p(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: NoirSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 2),
          Text(body, style: t.bodySmall),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Privacy', style: t.titleMedium),
        const SizedBox(height: NoirSpacing.lg),
        p(
          'Stored on this device',
          'Your library index, artwork extracted from your files, playlists, '
              'favorites, listening and search history, and settings.',
        ),
        p(
          'Sent anywhere',
          'Nothing. This version makes no network requests with your data, '
              'has no telemetry and no third-party tracking.',
        ),
        p(
          'Google / YouTube (future)',
          'When account support arrives, NOIR will talk only to Google, with '
              'your consent, and you will be able to disconnect and revoke '
              'access at any time.',
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ),
      ],
    );
  },
);
