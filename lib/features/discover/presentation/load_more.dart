import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';

/// Put as the last item of a lazily built list: when it is built (scrolled
/// near), it asks for the next page and shows [placeholder] meanwhile. If
/// that fails it offers a "Show more" button instead of retrying on its own.
///
/// Give it a key that changes with the item count so every new page gets a
/// fresh trigger.
class LoadMoreTrigger extends StatefulWidget {
  const LoadMoreTrigger({
    required this.onLoadMore,
    required this.placeholder,
    super.key,
  });

  /// Returns whether a page was added.
  final Future<bool> Function() onLoadMore;
  final Widget placeholder;

  @override
  State<LoadMoreTrigger> createState() => _LoadMoreTriggerState();
}

class _LoadMoreTriggerState extends State<LoadMoreTrigger> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // After the frame: providers must not change while widgets build.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_failed) setState(() => _failed = false);
    final added = await widget.onLoadMore();
    if (mounted && !added) setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_failed) return widget.placeholder;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NoirSpacing.lg),
      child: Center(
        child: PillButton(
          label: 'Show more',
          icon: Icons.expand_more_rounded,
          onPressed: () => unawaited(_load()),
        ),
      ),
    );
  }
}
