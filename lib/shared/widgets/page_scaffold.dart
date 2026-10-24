import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';

/// Horizontal page padding for the current width.
double pagePadding(BuildContext context) =>
    switch (WindowClass.of(MediaQuery.sizeOf(context).width)) {
      WindowClass.compact => NoirSpacing.lg,
      WindowClass.medium => NoirSpacing.xl,
      WindowClass.expanded => 40,
    };

/// Scrollable page body with an optional large title and actions.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    required this.slivers,
    this.title,
    this.actions = const [],
    this.controller,
    super.key,
  });

  final String? title;
  final List<Widget> actions;
  final List<Widget> slivers;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final own = controller;
    if (own != null) return _page(context, own);
    return SmoothScroll(builder: _page);
  }

  Widget _page(BuildContext context, ScrollController scroll) {
    final pad = pagePadding(context);
    final t = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: Scrollbar(
        controller: scroll,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            if (title != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, NoirSpacing.lg, pad - 8, 0),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(title!, style: t.headlineSmall),
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ),
              ),
            for (final s in slivers)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                sliver: s,
              ),
            const SliverToBoxAdapter(child: SizedBox(height: NoirSpacing.xxxl)),
          ],
        ),
      ),
    );
  }
}
