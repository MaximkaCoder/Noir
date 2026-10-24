import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:window_manager/window_manager.dart';

/// True where NOIR draws its own window chrome (frameless window).
bool get usesCustomWindowChrome => Platform.isWindows || Platform.isLinux;

/// macOS keeps its native traffic lights top-left; reserve room for them.
bool get reservesWindowControlsSpace => Platform.isMacOS;

/// Minimize / maximize / close as three dots in the top-right corner — the
/// reference design's look with Windows placement (owner decision, see
/// docs/design/README.md). Colored while the window is focused, grey
/// otherwise; symbols appear on hover; each dot has a tooltip.
class WindowControls extends StatefulWidget {
  const WindowControls({this.onImage = false, super.key});

  /// Over artwork or another busy backdrop (Now Playing): the idle dots
  /// become translucent light dots with a dark hairline and a soft shadow
  /// in dark themes (dark-ish dots with a light rim in light themes), so
  /// they stand out from whatever is behind them.
  final bool onImage;

  /// Each dot, for tests.
  static const dotKey = ValueKey('window-controls-dot');

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
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
