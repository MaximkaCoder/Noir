import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  bool _focused = true;
  bool _hovered = false;
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
    final active = _focused || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(
            color: const Color(0xFFFEBC2E),
            active: active,
            showGlyph: _hovered,
            glyph: Icons.remove_rounded,
            tooltip: 'Minimize',
            onPressed: windowManager.minimize,
          ),
          _Dot(
            color: const Color(0xFF28C840),
            active: active,
            showGlyph: _hovered,
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
            active: active,
            showGlyph: _hovered,
            glyph: Icons.close_rounded,
            tooltip: 'Close',
            onPressed: windowManager.close,
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({
    required this.color,
    required this.active,
    required this.showGlyph,
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
  });

  final Color color;
  final bool active;
  final bool showGlyph;
  final IconData glyph;
  final String tooltip;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkResponse(
          onTap: () => unawaited(onPressed()),
          radius: 12,
          // A 24 px target around a 12 px dot keeps it easy to hit.
          child: SizedBox(
            width: 20,
            height: 24,
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? color : const Color(0xFF4A4A4A),
                ),
                child: showGlyph
                    ? Icon(glyph, size: 9, color: const Color(0xB3000000))
                    : null,
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
