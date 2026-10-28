import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/features/edge_player/edge_snapshot.dart';

/// Implemented by the Windows runner (windows/runner/edge_player.cpp), on
/// the edge player's own engine.
const edgeViewChannel = MethodChannel('noir/edge_view');

/// Runs the edge player in its own engine; started by the Windows runner.
void runEdgePlayer() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EdgePlayerApp());
}

class EdgePlayerApp extends StatelessWidget {
  const EdgePlayerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    color: Colors.transparent,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      canvasColor: Colors.transparent,
    ),
    home: const EdgePlayerView(),
  );
}

/// How far the player is out.
enum EdgePhase {
  /// A thin line at the edge, to point at.
  handle,

  /// Artwork and play/pause.
  capsule,

  /// Everything: title, progress, controls, heart and volume.
  panel,
}

/// The player's outline in each [EdgePhase], measured from the screen edge.
@immutable
class EdgeShape {
  const EdgeShape(this.depth, this.height, this.radius);

  factory EdgeShape.of(EdgePhase phase) => switch (phase) {
    EdgePhase.handle => handle,
    EdgePhase.capsule => capsule,
    EdgePhase.panel => panel,
  };

  /// Between the phases: [t] runs 0 (handle) → 1 (capsule) → 2 (panel).
  factory EdgeShape.at(double t) {
    final (a, b, f) = t <= 1 ? (handle, capsule, t) : (capsule, panel, t - 1);
    return EdgeShape(
      ui.lerpDouble(a.depth, b.depth, f)!,
      ui.lerpDouble(a.height, b.height, f)!,
      ui.lerpDouble(a.radius, b.radius, f)!,
    );
  }

  static const handle = EdgeShape(5, 96, 3);
  static const capsule = EdgeShape(64, 140, 32);
  static const panel = EdgeShape(264, 364, 36);

  /// How far it reaches into the screen.
  final double depth;
  final double height;
  final double radius;
}

/// The player that comes out from behind the screen edge: a thin handle
/// until pointed at, then a capsule, then — after a moment over it — the
/// full panel. It slides back when the pointer leaves.
class EdgePlayerView extends StatefulWidget {
  const EdgePlayerView({
    this.channel = edgeViewChannel,
    this.initialPhase = EdgePhase.handle,
    super.key,
  });

  final MethodChannel channel;

  /// For tests and previews.
  final EdgePhase initialPhase;

  /// How long the pointer stays on the capsule before the panel opens.
  static const dwell = Duration(milliseconds: 350);

  /// How long the pointer may be away before the player slides back.
  static const grace = Duration(milliseconds: 400);

  /// Room around the outline for its shadow.
  static const shadowRoom = 28.0;

  @override
  State<EdgePlayerView> createState() => _EdgePlayerViewState();
}

class _EdgePlayerViewState extends State<EdgePlayerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    upperBound: 2,
    value: widget.initialPhase.index.toDouble(),
  );

  EdgeSnapshot _snapshot = const EdgeSnapshot(side: 'right');
  String _side = 'right';
  double _overhang = 48;
  late EdgePhase _phase = widget.initialPhase;
  Timer? _dwell;
  Timer? _grace;
  _Backdrop? _backdrop;

  /// The region last sent, to skip repeats.
  Rect? _sentRegion;
  bool _sentOpen = false;

  bool get _left => _side == 'left';

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler(_onNativeCall);
    unawaited(_call('ready'));
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendRegion());
  }

  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _dwell?.cancel();
    _grace?.cancel();
    _backdrop?.image.dispose();
    _t.dispose();
    super.dispose();
  }

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await widget.channel.invokeMethod<void>(method, arguments);
    } on Object catch (e) {
      debugPrint('Edge player: $method failed: $e');
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'update' when args is Map:
        final snapshot = EdgeSnapshot.fromMap(args);
        setState(() => _snapshot = snapshot);
        // Hidden with nothing to play; it comes back as the handle.
        if (!snapshot.visible && _phase != EdgePhase.handle) {
          _dwell?.cancel();
          _grace?.cancel();
          _t.value = 0;
          setState(() => _phase = EdgePhase.handle);
          _sendRegion();
        }
      case 'layout' when args is Map:
        setState(() {
          _side = args['side'] as String? ?? 'right';
          _overhang = (args['overhang'] as num? ?? 48).toDouble();
        });
        _sentRegion = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => _sendRegion());
      case 'backdrop' when args is Map:
        await _setBackdrop(args);
    }
  }

  Future<void> _setBackdrop(Map<Object?, Object?> args) async {
    final pixels = args['pixels'];
    if (pixels is! Uint8List) return;
    final width = args['pixelWidth']! as int;
    final height = args['pixelHeight']! as int;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    final image = await completer.future;
    if (!mounted) {
      image.dispose();
      return;
    }
    final old = _backdrop;
    setState(() {
      _backdrop = _Backdrop(
        image,
        Rect.fromLTWH(
          (args['left']! as num).toDouble(),
          (args['top']! as num).toDouble(),
          (args['width']! as num).toDouble(),
          (args['height']! as num).toDouble(),
        ),
      );
    });
    old?.image.dispose();
  }

  // ---------------------------------------------------------------- shape --

  /// The outline's rectangle in window coordinates. It runs [_overhang]
  /// past the screen edge, so its outer corners are never seen.
  Rect _rectFor(EdgeShape shape, Size window) {
    final top = (window.height - shape.height) / 2;
    final width = shape.depth + _overhang;
    final left = _left ? 0.0 : window.width - width;
    return Rect.fromLTWH(left, top, width, shape.height);
  }

  /// Where the pointer is caught for [phase]: the outline plus room for its
  /// shadow (a little more around the thin handle, to be easy to hit).
  Rect _regionFor(EdgePhase phase, Size window) {
    final rect = _rectFor(EdgeShape.of(phase), window);
    final room = phase == EdgePhase.handle ? 4.0 : EdgePlayerView.shadowRoom;
    return Rect.fromLTRB(
      _left ? rect.left : rect.left - room,
      rect.top - room,
      _left ? rect.right + room : rect.right,
      rect.bottom + room,
    );
  }

  void _sendRegion({EdgePhase? phase}) {
    if (!mounted) return;
    final window = MediaQuery.sizeOf(context);
    final region = _regionFor(phase ?? _phase, window);
    final open = (phase ?? _phase) != EdgePhase.handle;
    if (region == _sentRegion && open == _sentOpen) return;
    _sentRegion = region;
    _sentOpen = open;
    unawaited(
      _call('region', {
        'left': region.left,
        'top': region.top,
        'right': region.right,
        'bottom': region.bottom,
        'open': open,
      }),
    );
  }

  Future<void> _go(EdgePhase phase) async {
    if (phase == _phase) return;
    final growing = phase.index > _phase.index;
    setState(() => _phase = phase);
    // Grow the clickable region before the player grows into it; shrink it
    // once the player has shrunk.
    if (growing) _sendRegion();
    if (MediaQuery.disableAnimationsOf(context)) {
      _t.value = phase.index.toDouble();
    } else {
      await _t.animateTo(
        phase.index.toDouble(),
        duration: growing
            ? const Duration(milliseconds: 460)
            : const Duration(milliseconds: 320),
        curve: growing ? Curves.easeOutQuint : Curves.easeInOutCubic,
      );
    }
    if (!growing && mounted && _phase == phase) _sendRegion();
  }

  // ---------------------------------------------------------------- hover --

  void _onEnter() {
    _grace?.cancel();
    if (_phase == EdgePhase.handle) unawaited(_go(EdgePhase.capsule));
    if (_phase != EdgePhase.panel) {
      _dwell?.cancel();
      _dwell = Timer(EdgePlayerView.dwell, () => _go(EdgePhase.panel));
    }
  }

  void _onExit() {
    _dwell?.cancel();
    _grace?.cancel();
    _grace = Timer(EdgePlayerView.grace, () => _go(EdgePhase.handle));
  }

  void _command(EdgeCommand command, [num? value]) =>
      unawaited(_call('command', {'name': command.name, 'value': ?value}));

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    return Material(type: MaterialType.transparency, child: _player(window));
  }

  Widget _player(Size window) {
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final t = _t.value;
          final shape = EdgeShape.at(t);
          final rect = _rectFor(shape, window);
          // The content's own box: the outline minus the part past the edge.
          final inner = _left
              ? Rect.fromLTRB(
                  rect.left + _overhang,
                  rect.top,
                  rect.right,
                  rect.bottom,
                )
              : Rect.fromLTRB(
                  rect.left,
                  rect.top,
                  rect.right - _overhang,
                  rect.bottom,
                );
          final glass = t.clamp(0.0, 0.6) / 0.6;
          final capsule =
              (1 - (t - 1).abs() * 2.2).clamp(0.0, 1.0) *
              ((t - 0.45) / 0.45).clamp(0.0, 1.0);
          final panel = ((t - 1.45) / 0.55).clamp(0.0, 1.0);
          return Stack(
            children: [
              _Glass(
                rect: rect,
                radius: shape.radius,
                amount: glass,
                backdrop: _backdrop,
              ),
              if (capsule > 0)
                Positioned.fromRect(
                  rect: Rect.fromCenter(
                    center: inner.center,
                    width: EdgeShape.capsule.depth,
                    height: EdgeShape.capsule.height,
                  ),
                  child: Opacity(
                    opacity: capsule,
                    child: _CapsuleContent(
                      snapshot: _snapshot,
                      onOpen: () => _go(EdgePhase.panel),
                      onCommand: _command,
                    ),
                  ),
                ),
              if (panel > 0)
                Positioned.fromRect(
                  rect: Rect.fromCenter(
                    center: inner.center,
                    width: EdgeShape.panel.depth,
                    height: EdgeShape.panel.height,
                  ),
                  child: Opacity(
                    opacity: panel,
                    child: Transform.scale(
                      scale: ui.lerpDouble(0.94, 1, panel),
                      child: _PanelContent(
                        snapshot: _snapshot,
                        onCommand: _command,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

@immutable
class _Backdrop {
  const _Backdrop(this.image, this.rect);

  /// What is behind the player, scaled down.
  final ui.Image image;

  /// Where it belongs, in window coordinates.
  final Rect rect;
}

/// The outline: blurred, tinted backdrop, a hairline of light along the
/// inner edge and a soft shadow. [amount] 0 is the bare handle.
class _Glass extends StatelessWidget {
  const _Glass({
    required this.rect,
    required this.radius,
    required this.amount,
    required this.backdrop,
  });

  final Rect rect;
  final double radius;
  final double amount;
  final _Backdrop? backdrop;

  @override
  Widget build(BuildContext context) {
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final backdrop = this.backdrop;
    return Positioned.fill(
      child: CustomPaint(
        painter: _ShadowPainter(shape, amount),
        foregroundPainter: _RimPainter(shape, amount),
        child: ClipRRect(
          clipper: _ShapeClipper(shape),
          child: Stack(
            children: [
              if (backdrop != null && amount > 0)
                Positioned.fromRect(
                  rect: backdrop.rect,
                  child: Opacity(
                    opacity: amount,
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                      child: RawImage(image: backdrop.image, fit: BoxFit.fill),
                    ),
                  ),
                ),
              Positioned.fill(
                child: ColoredBox(
                  color: Color.lerp(
                    const Color(0x47FFFFFF),
                    backdrop == null
                        ? const Color(0xEB101012)
                        : const Color(0xA8101012),
                    amount,
                  )!,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShapeClipper extends CustomClipper<RRect> {
  const _ShapeClipper(this.shape);

  final RRect shape;

  @override
  RRect getClip(Size size) => shape;

  @override
  bool shouldReclip(_ShapeClipper old) => old.shape != shape;
}

class _ShadowPainter extends CustomPainter {
  const _ShadowPainter(this.shape, this.amount);

  final RRect shape;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    canvas.drawRRect(
      shape.shift(const Offset(0, 6)),
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.45 * amount)
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 14),
    );
  }

  @override
  bool shouldRepaint(_ShadowPainter old) =>
      old.shape != shape || old.amount != amount;
}

/// Light catching the glass: brighter at the top, fading downwards.
class _RimPainter extends CustomPainter {
  const _RimPainter(this.shape, this.amount);

  final RRect shape;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final rect = shape.outerRect;
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [
            Color.fromRGBO(255, 255, 255, 0.22 * amount),
            Color.fromRGBO(255, 255, 255, 0.05 * amount),
            Color.fromRGBO(255, 255, 255, 0.10 * amount),
          ],
          const [0, 0.6, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.shape != shape || old.amount != amount;
}

// -------------------------------------------------------------- contents --

class _Artwork extends StatelessWidget {
  const _Artwork(this.source, {required this.size, required this.radius});

  final String source;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cache = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final placeholder = ColoredBox(
      color: const Color(0xFF1C1C1F),
      child: Icon(
        Icons.music_note_rounded,
        size: size * 0.4,
        color: const Color(0x66FFFFFF),
      ),
    );
    final ImageProvider? image = source.isEmpty
        ? null
        : source.startsWith('http')
        ? ResizeImage(NetworkImage(source), width: cache, height: cache)
        : ResizeImage(FileImage(File(source)), width: cache, height: cache);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: image == null
            ? placeholder
            : Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _CapsuleContent extends StatelessWidget {
  const _CapsuleContent({
    required this.snapshot,
    required this.onOpen,
    required this.onCommand,
  });

  final EdgeSnapshot snapshot;
  final VoidCallback onOpen;
  final void Function(EdgeCommand, [num?]) onCommand;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      GestureDetector(
        onTap: onOpen,
        child: _Artwork(snapshot.artwork, size: 44, radius: 12),
      ),
      const SizedBox(height: 14),
      _PlayButton(
        playing: snapshot.playing,
        size: 40,
        onPressed: () => onCommand(EdgeCommand.playPause),
      ),
    ],
  );
}

class _PanelContent extends StatelessWidget {
  const _PanelContent({required this.snapshot, required this.onCommand});

  final EdgeSnapshot snapshot;
  final void Function(EdgeCommand, [num?]) onCommand;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
      child: Column(
        children: [
          _Artwork(snapshot.artwork, size: 96, radius: 18),
          const SizedBox(height: 14),
          Text(
            snapshot.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.titleSmall!.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            snapshot.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall!.copyWith(
              fontSize: 13,
              color: const Color(0x99FFFFFF),
            ),
          ),
          const SizedBox(height: 14),
          _Progress(
            snapshot: snapshot,
            onSeek: (p) => onCommand(EdgeCommand.seek, p.inMilliseconds),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _IconButton(
                icon: Icons.skip_previous_rounded,
                label: 'Previous',
                size: 28,
                onPressed: snapshot.canPrevious
                    ? () => onCommand(EdgeCommand.previous)
                    : null,
              ),
              const SizedBox(width: 18),
              _PlayButton(
                playing: snapshot.playing,
                size: 52,
                onPressed: () => onCommand(EdgeCommand.playPause),
              ),
              const SizedBox(width: 18),
              _IconButton(
                icon: Icons.skip_next_rounded,
                label: 'Next',
                size: 28,
                onPressed: snapshot.canNext
                    ? () => onCommand(EdgeCommand.next)
                    : null,
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              if (snapshot.canLike)
                _IconButton(
                  icon: snapshot.liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  label: snapshot.liked ? 'Liked' : 'Like',
                  size: 18,
                  onPressed: () => onCommand(EdgeCommand.like),
                )
              else
                const SizedBox(width: 32),
              const SizedBox(width: 4),
              Expanded(
                child: _Volume(
                  volume: snapshot.volume,
                  onChanged: (v) => onCommand(EdgeCommand.volume, v),
                ),
              ),
              const SizedBox(width: 4),
              _IconButton(
                icon: Icons.open_in_full_rounded,
                label: 'Open NOIR',
                size: 16,
                onPressed: () => onCommand(EdgeCommand.open),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.size,
    required this.onPressed,
  });

  final bool playing;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: playing ? 'Pause' : 'Play',
    child: GestureDetector(
      onTap: onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: size * 0.55,
            color: const Color(0xFF0E0E10),
          ),
        ),
      ),
    ),
  );
}

class _IconButton extends StatefulWidget {
  const _IconButton({
    required this.icon,
    required this.label,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final double size;
  final VoidCallback? onPressed;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final color = !enabled
        ? const Color(0x40FFFFFF)
        : _hovered
        ? Colors.white
        : const Color(0xCCFFFFFF);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: SizedBox.square(
            dimension: math.max(32, widget.size + 8),
            child: Icon(widget.icon, size: widget.size, color: color),
          ),
        ),
      ),
    );
  }
}

/// A thin line with the elapsed and remaining time; click or drag to seek.
class _Progress extends StatefulWidget {
  const _Progress({required this.snapshot, required this.onSeek});

  final EdgeSnapshot snapshot;
  final ValueChanged<Duration> onSeek;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  /// Moves the line on while playing; the time changes once a second, so
  /// redrawing every frame would only cost the blur behind it.
  Timer? _tick;

  /// Fraction while dragging, shown before the seek lands.
  double? _scrub;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Progress old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.snapshot.playing) {
      _tick ??= Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  double _fractionAt(double dx, double width) => (dx / width).clamp(0.0, 1.0);

  void _seek(double fraction) {
    final duration = widget.snapshot.duration;
    widget.onSeek(duration * fraction);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final position = s.positionAt(DateTime.now());
    final total = s.duration;
    final fraction =
        _scrub ??
        (total > Duration.zero
            ? position.inMilliseconds / total.inMilliseconds
            : 0.0);
    final shown = _scrub == null ? position : total * _scrub!;
    const style = TextStyle(
      fontSize: 11,
      color: Color(0x80FFFFFF),
      fontFeatures: [ui.FontFeature.tabularFigures()],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final seekable = total > Duration.zero;
        return Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: seekable
                  ? (d) => _seek(_fractionAt(d.localPosition.dx, width))
                  : null,
              onHorizontalDragUpdate: seekable
                  ? (d) => setState(
                      () => _scrub = _fractionAt(d.localPosition.dx, width),
                    )
                  : null,
              onHorizontalDragEnd: seekable
                  ? (_) {
                      if (_scrub != null) _seek(_scrub!);
                      setState(() => _scrub = null);
                    }
                  : null,
              child: SizedBox(
                height: 14,
                child: Center(child: _Line(fraction: fraction.clamp(0.0, 1.0))),
              ),
            ),
            Row(
              children: [
                Text(formatClock(shown), style: style),
                const Spacer(),
                Text(
                  seekable ? '-${formatClock(total - shown)}' : '',
                  style: style,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: SizedBox(
      height: 3,
      child: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0x33FFFFFF))),
          FractionallySizedBox(
            widthFactor: fraction,
            heightFactor: 1,
            alignment: Alignment.centerLeft,
            child: const ColoredBox(color: Colors.white),
          ),
        ],
      ),
    ),
  );
}

class _Volume extends StatefulWidget {
  const _Volume({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  State<_Volume> createState() => _VolumeState();
}

class _VolumeState extends State<_Volume> {
  /// While dragging, ahead of the app's answer.
  double? _dragged;

  void _set(double dx, double width) {
    final v = (dx / width).clamp(0.0, 1.0);
    setState(() => _dragged = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final volume = _dragged ?? widget.volume;
    return Row(
      children: [
        Icon(
          volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          size: 16,
          color: const Color(0x99FFFFFF),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Semantics(
                slider: true,
                label: 'Volume',
                value: '${(volume * 100).round()}%',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    _set(d.localPosition.dx, width);
                    _dragged = null;
                  },
                  onHorizontalDragUpdate: (d) =>
                      _set(d.localPosition.dx, width),
                  onHorizontalDragEnd: (_) => setState(() => _dragged = null),
                  child: SizedBox(
                    height: 24,
                    child: Center(child: _Line(fraction: volume)),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
