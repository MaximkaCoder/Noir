import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/presentation/save_target_picker.dart';
import 'package:noir/shared/models/media.dart';

/// Heart for a YouTube song: saves it to (or removes it from) the playlist
/// chosen in Settings → Accounts. Never a YouTube like. Hidden for local
/// tracks and while no Google account is connected.
class YouTubeSaveButton extends ConsumerWidget {
  const YouTubeSaveButton(
    this.track, {
    this.size = 18,
    this.showWhenUnsaved = true,
    super.key,
  });

  final Track track;
  final double size;

  /// False hides the empty heart (rows show it on hover); a filled heart is
  /// always shown.
  final bool showWhenUnsaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (track.source != MediaSource.youtube) return const SizedBox.shrink();
    final account =
        ref.watch(accountConnectionProvider).value ??
        ref.watch(accountServiceProvider).current;
    if (!account.isConnected) return const SizedBox.shrink();

    final saved = ref.watch(youTubeSavedProvider(track.uri));
    final title = ref.watch(saveTargetTitleProvider);
    final visible = saved || showWhenUnsaved;
    final fx = NoirEffects.of(context);
    final tooltip = saved
        ? 'Remove from $title'
        : title == null
        ? 'Save to a YouTube playlist'
        : 'Save to $title';

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: fx.motion(NoirMotion.fast),
        child: Semantics(
          toggled: saved,
          child: AnimatedSwitcher(
            duration: fx.motion(NoirMotion.fast),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: NoirIconButton(
              key: ValueKey(saved),
              icon: saved
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              tooltip: tooltip,
              active: saved,
              size: size,
              onPressed: () =>
                  unawaited(toggleYouTubeSave(context, ref, track)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Runs the heart: asks for a target playlist or the playlist permission
/// when needed, then saves or removes [track] and reports it in a toast.
Future<void> toggleYouTubeSave(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final ctrl = ref.read(youTubeSaveProvider.notifier);
  var outcome = await ctrl.toggle(track);
  // At most two detours: choose a playlist, then allow access.
  for (var detours = 0; detours < 2; detours++) {
    if (!context.mounted) return;
    final bool ready;
    if (outcome.result == SaveResult.needsTarget) {
      ready = await pickSaveTarget(context, ref) != null;
    } else if (outcome.result == SaveResult.needsPermission) {
      ready = await askForWriteAccess(context, ref);
    } else {
      break;
    }
    if (!ready || !context.mounted) return;
    outcome = await ctrl.toggle(track);
  }
  final message = outcome.message;
  if (message != null && context.mounted) showToast(context, message);
}

/// True when NOIR may edit the user's playlists, asking for it first.
Future<bool> ensureWriteAccess(BuildContext context, WidgetRef ref) async {
  if (ref.read(accountServiceProvider).current.canSaveToPlaylists) return true;
  return await askForWriteAccess(context, ref);
}

/// Explains the playlist permission, then runs Google's consent in the
/// browser. Returns true when granted; otherwise tells the user why.
Future<bool> askForWriteAccess(BuildContext context, WidgetRef ref) async {
  final ok = await confirm(
    context,
    title: 'Allow NOIR to edit your playlists?',
    message:
        'Hearting a YouTube song adds it to a playlist you choose on your '
        'YouTube account. For that, Google asks you once to let NOIR manage '
        'your YouTube account. NOIR only adds and removes songs in that '
        'playlist (and creates it if you ask), or likes and unlikes songs '
        'when you use Liked music. It never deletes anything else. Your '
        'browser opens next.',
    confirmLabel: 'Continue',
  );
  if (!ok || !context.mounted) return false;
  showToast(context, 'Continue in your browser');
  final result = await ref
      .read(youTubeSaveProvider.notifier)
      .requestWriteAccess();
  if (!result.granted && result.message != null && context.mounted) {
    showToast(context, result.message!);
  }
  return result.granted;
}
