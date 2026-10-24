import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';

/// Pins a collection to (or unpins it from) Home.
class PinButton extends ConsumerWidget {
  const PinButton(this.item, {super.key});

  final PinnedRef item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedProvider).contains(item);
    return NoirIconButton(
      icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
      tooltip: pinned ? 'Unpin from Home' : 'Pin to Home',
      active: pinned,
      onPressed: () {
        final now = ref.read(pinnedProvider.notifier).toggle(item);
        showToast(context, now ? 'Pinned to Home' : 'Removed from Home');
      },
    );
  }
}
