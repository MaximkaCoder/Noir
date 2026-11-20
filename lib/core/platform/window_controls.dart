import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:window_manager/window_manager.dart';

/// True where NOIR draws its own window chrome (frameless window).
bool get usesCustomWindowChrome => Platform.isWindows || Platform.isLinux;

/// macOS keeps its native traffic lights top-left; reserve room for them.
bool get reservesWindowControlsSpace => Platform.isMacOS;

/// The desktop title bar's geometry. Every bar that ends in [WindowControls]
/// (the shell's top bar, Now Playing's) uses it, so the dots sit at exactly
/// the same place on every screen: [padding] from the window's top right,
/// vertically centered in the [height] − vertical padding band.
abstract final class TitleBarMetrics {
  static const double height = 60;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(24, 12, 20, 4);
}

/// Minimize / maximize / close in the top-right corner, in the style chosen
/// in Settings ([AppSettings.windowButtons]):
///
/// * dots, the reference design's look with Windows placement (owner
///   decision, see docs/design/README.md). Grey until the pointer is over
///   one; symbols appear on hover;
/// * Windows' glyphs with no strip behind them, only a faint rounded hover
///   (red for close).
///
/// Dimmer while the window is not focused; each button has a tooltip.
class WindowControls extends ConsumerStatefulWidget {
  const WindowControls({this.onImage = false, super.key});

  /// Over artwork or another busy backdrop (Now Playing): the idle dots
  /// become translucent light dots with a dark hairline and a soft shadow
  /// in dark themes (dark-ish dots with a light rim in light themes), so
  /// they stand out from whatever is behind them; the Windows glyphs turn
  /// light (dark in light themes) and translucent.
  final bool onImage;

  /// Each dot, for tests.
  static const dotKey = ValueKey('window-controls-dot');

  /// Each Windows-style button, for tests.
  static const buttonKey = ValueKey('window-controls-button');

  @override
  ConsumerState<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends ConsumerState<WindowControls>
    with WindowListener {
  bool _focused = true;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_sync());
  }

  Future<void> _sync() async {
    bool focused;
    bool maximized;
    try {
      focused = await windowManager.isFocused();
      maximized = await windowManager.isMaximized();
    } on Exception {
      return; // No window plugin (e.g. tests); keep defaults.
    }
    if (!mounted) return;
    setState(() {
      _focused = focused;
      _maximized = maximized;
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() => setState(() => _focused = true);
  @override
  void onWindowBlur() => setState(() => _focused = false);
  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(settingsProvider.select((s) => s.windowButtons));
    if (style == WindowButtons.windows) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          _CaptionButton(
            glyph: _Glyph.minimize,
            focused: _focused,
            onImage: widget.onImage,
            tooltip: 'Minimize',
            onPressed: windowManager.minimize,
          ),
          _CaptionButton(
            glyph: _maximized ? _Glyph.restore : _Glyph.maximize,
            focused: _focused,
            onImage: widget.onImage,
            tooltip: _maximized ? 'Restore' : 'Maximize',
            onPressed: () => _maximized
                ? windowManager.unmaximize()
                : windowManager.maximize(),
          ),
          _CaptionButton(
            glyph: _Glyph.close,
            focused: _focused,
            onImage: widget.onImage,
            tooltip: 'Close',
            onPressed: windowManager.close,
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dot(
          color: const Color(0xFFFEBC2E),
          focused: _focused,
          onImage: widget.onImage,
          glyph: Icons.remove_rounded,
          tooltip: 'Minimize',
          onPressed: windowManager.minimize,
        ),
        _Dot(
          color: const Color(0xFF28C840),
          focused: _focused,
          onImage: widget.onImage,
          glyph: _maximized
              ? Icons.close_fullscreen_rounded
              : Icons.open_in_full_rounded,
          tooltip: _maximized ? 'Restore' : 'Maximize',
          onPressed: () => _maximized
              ? windowManager.unmaximize()
              : windowManager.maximize(),
        ),
        _Dot(
          color: const Color(0xFFFF5F57),
          focused: _focused,
          onImage: widget.onImage,
          glyph: Icons.close_rounded,
          tooltip: 'Close',
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}

/// One window button: a quiet grey dot that glows into its color only while
/// the pointer is over it (or it has keyboard focus), then fades back.
class _Dot extends StatefulWidget {
  const _Dot({
    required this.color,
    required this.focused,
    required this.onImage,
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
  });

  final Color color;

  /// See [WindowControls.onImage].
  final bool onImage;

  /// Whether the window is focused; unfocused windows dim the dots further.
  final bool focused;
  final IconData glyph;
  final String tooltip;
  final Future<void> Function() onPressed;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> {
  bool _hovered = false;
  bool _focusLit = false;

  bool get _lit => _hovered || _focusLit;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color idle;
    Color? rim;
    if (widget.onImage) {
      idle = dark
          ? Colors.white.withValues(alpha: widget.focused ? 0.62 : 0.4)
          : Colors.black.withValues(alpha: widget.focused ? 0.42 : 0.26);
      rim = dark
          ? Colors.black.withValues(alpha: 0.4)
          : Colors.white.withValues(alpha: 0.6);
    } else {
      idle = dark
          ? Color(widget.focused ? 0xFF3D3D3D : 0xFF2C2C2C)
          : Color(widget.focused ? 0xFFC9C9C9 : 0xFFDDDDDD);
    }
    final duration = NoirEffects.of(context)
        .motion(const Duration(milliseconds: 180));
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) => setState(() => _focusLit = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => unawaited(widget.onPressed()),
            ),
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              // The whole target takes the click, not only the painted dot:
              // otherwise a click near its edge lit the dot but went to the
              // drag area behind it.
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(widget.onPressed()),
              // A 20×24 target around a 12 px dot keeps it easy to hit.
              child: SizedBox(
                width: 20,
                height: 24,
                child: Center(
                  child: AnimatedContainer(
                    key: WindowControls.dotKey,
                    duration: duration,
                    curve: Curves.easeOut,
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _lit ? widget.color : idle,
                      border: rim == null
                          ? null
                          : Border.all(
                              color: _lit ? Colors.transparent : rim,
                              width: 0.5,
                            ),
                      boxShadow: [
                        BoxShadow(
                          color: _lit
                              ? widget.color.withValues(alpha: 0.45)
                              : widget.onImage
                              ? Colors.black.withValues(
                                  alpha: dark ? 0.35 : 0.12,
                                )
                              : widget.color.withValues(alpha: 0),
                          blurRadius: _lit ? 8 : 4,
                        ),
                      ],
                    ),
                    child: AnimatedOpacity(
                      opacity: _lit ? 1 : 0,
                      duration: duration,
                      child: Icon(
                        widget.glyph,
                        size: 9,
                        color: const Color(0xB3000000),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// One Windows-style window button: a thin glyph with nothing behind it
/// until the pointer comes over it, then a faint rounded fill (close: red
/// with a white glyph).
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.focused,
    required this.onImage,
    required this.tooltip,
    required this.onPressed,
  });

  final _Glyph glyph;

  /// Whether the window is focused; unfocused windows dim the glyphs.
  final bool focused;

  /// See [WindowControls.onImage].
  final bool onImage;
  final String tooltip;
  final Future<void> Function() onPressed;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focusLit = false;

  static const _closeRed = Color(0xFFC42B1C);

  @override
  Widget build(BuildContext context) {
    final close = widget.glyph == _Glyph.close;
    final lit = _hovered || _focusLit;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = widget.onImage
        ? (dark ? Colors.white : Colors.black)
        : theme.extension<NoirPalette>()?.textPrimary ??
              theme.colorScheme.onSurface;
    final Color fill;
    final Color glyph;
    if (close && (lit || _pressed)) {
      fill = _pressed ? _closeRed.withValues(alpha: 0.8) : _closeRed;
      glyph = Colors.white;
    } else {
      fill = ink.withValues(
        alpha: _pressed
            ? (dark ? 0.06 : 0.1)
            : lit
            ? (dark ? 0.1 : 0.06)
            : 0,
      );
      glyph = ink.withValues(alpha: widget.focused ? 0.85 : 0.45);
    }
    final duration = NoirEffects.of(context)
        .motion(const Duration(milliseconds: 120));
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.basic,
          onShowFocusHighlight: (v) => setState(() => _focusLit = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => unawaited(widget.onPressed()),
            ),
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              onTap: () => unawaited(widget.onPressed()),
              child: AnimatedContainer(
                key: WindowControls.buttonKey,
                duration: duration,
                curve: Curves.easeOut,
                width: 40,
                height: 30,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: CustomPaint(
                    size: const Size.square(10),
                    painter: _GlyphPainter(widget.glyph, glyph),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Windows' caption glyphs as hairlines in a 10 px square.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(const Offset(0, 5.5), const Offset(10, 5.5), paint);
      case _Glyph.maximize:
        canvas.drawRRect(
          RRect.fromLTRBR(0.5, 0.5, 9.5, 9.5, const Radius.circular(1.5)),
          paint,
        );
      case _Glyph.restore:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(0.5, 2.5, 7.5, 9.5, const Radius.circular(1)),
            paint,
          )
          ..drawPath(
            Path()
              ..moveTo(2.5, 2.5)
              ..lineTo(2.5, 0.5)
              ..lineTo(9.5, 0.5)
              ..lineTo(9.5, 7.5)
              ..lineTo(7.5, 7.5),
            paint,
          );
      case _Glyph.close:
        canvas
          ..drawLine(Offset.zero, const Offset(10, 10), paint)
          ..drawLine(const Offset(10, 0), const Offset(0, 10), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

/// Drag region for moving a frameless window; double-click maximizes.
///
/// The drag layer sits *behind* [child], so only empty space drags the
/// window. Wrapping controls directly would make every tap on them wait for
/// the double-tap timeout.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!usesCustomWindowChrome && !Platform.isMacOS) return child;
    return Stack(
      children: [
        const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
        child,
      ],
    );
  }
}
