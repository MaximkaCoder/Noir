import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';

/// The canvas behind every screen: near-black with soft light falloff, and —
/// when Liquid Glass is on in Balanced mode — a faint monochrome wash of the
/// current artwork so glass surfaces have something to refract.
///
/// The artwork is decoded at 24 px and upscaled; bilinear filtering produces
/// the blur for free instead of running a full-screen blur filter.
class NoirBackdrop extends StatelessWidget {
  const NoirBackdrop({this.artworkPath, super.key});

  final String? artworkPath;

  static const _grayscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: c.background),
          if (fx.highlights)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.7, -0.9),
                  radius: 1.3,
                  colors: [
                    (dark ? Colors.white : Colors.black).withValues(
                      alpha: dark ? 0.06 : 0.03,
                    ),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          if (fx.ambient && artworkPath != null)
            AnimatedSwitcher(
              duration: fx.motion(NoirMotion.slow * 2),
              child: Opacity(
                key: ValueKey(artworkPath),
                opacity: dark ? 0.18 : 0.12,
                child: ColorFiltered(
                  colorFilter: _grayscale,
                  child: Image.file(
                    File(artworkPath!),
                    fit: BoxFit.cover,
                    cacheWidth: 24,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
