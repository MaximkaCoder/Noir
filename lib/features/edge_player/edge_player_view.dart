import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noir/core/formatters.dart';
import 'package:noir/core/widgets/artwork_flow.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';
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
  /// Behind the screen edge: NOIR is open, or nothing is loaded.
  away,

  /// A thin line at the edge, to point at.
  handle,

  /// The strip: artwork, title, transport, heart and "more".
  capsule,

  /// The wider player, opened with "more": progress and volume too.
  panel,
}

/// The screen edge the player is docked to.
enum EdgeSide {
  left,
  right,
  top,
  bottom;

  /// Left and right: the strip stands upright.
  bool get vertical => this == left || this == right;
}

/// The player's outline in each [EdgePhase]: how far it reaches into the
/// screen ([depth]) and how long it runs along the edge ([length]).
@immutable
class EdgeShape {
  const EdgeShape(this.depth, this.length, this.radius);

  factory EdgeShape.of(EdgePhase phase, EdgeSide side) => switch (phase) {
    EdgePhase.away => const EdgeShape(0, 96, 3),
    EdgePhase.handle => const EdgeShape(5, 96, 3),
    EdgePhase.capsule => EdgeShape(capsuleDepth, side.vertical ? 276 : 300, 16),
    EdgePhase.panel => EdgeShape(
      side.vertical ? panelSize.width : panelSize.height,
      side.vertical ? panelSize.height : panelSize.width,
      26,
    ),
  };

  /// Between the phases: [t] runs 0 (away) to 3 (panel).
  factory EdgeShape.at(double t, EdgeSide side) {
    final from = t.floor().clamp(0, EdgePhase.values.length - 2);
    final a = EdgeShape.of(EdgePhase.values[from], side);
    final b = EdgeShape.of(EdgePhase.values[from + 1], side);
    final f = t - from;
    return EdgeShape(
      ui.lerpDouble(a.depth, b.depth, f)!,
      ui.lerpDouble(a.length, b.length, f)!,
      ui.lerpDouble(a.radius, b.radius, f)!,
    );
  }

  static const capsuleDepth = 60.0;

  /// The wider player's box, whichever edge it is on.
  static const panelSize = Size(252, 236);

  final double depth;
  final double length;
  final double radius;
}

/// The player that lives behind the screen edge while NOIR is in the
/// background (minimized, or another window active): a
/// thin line to point at, which brings out a strip with the essentials;
/// "more" opens a wider player. Clicking the artwork or the title opens
/// NOIR. Dragged anywhere, the strip docks to the nearest edge where it is
/// dropped.
class EdgePlayerView extends StatefulWidget {
  const EdgePlayerView({this.channel = edgeViewChannel, super.key});

  final MethodChannel channel;

  /// How long the pointer may be away before the player slides back.
  static const grace = Duration(milliseconds: 450);

  /// Room around the outline for its shadow.
  static const shadowRoom = 28.0;

  @override
  State<EdgePlayerView> createState() => _EdgePlayerViewState();
}

class _EdgePlayerViewState extends State<EdgePlayerView>
    with TickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    upperBound: 3,
  );

  /// 1 while dragged: the outline leaves the edge and rounds all corners.
  /// May dip below 0 as it lands (the flares overshoot).
  late final AnimationController _detach = AnimationController.unbounded(
    vsync: this,
  );

  /// One loop of the artwork's flow, as in Now Playing.
  late final _flow = FlowClock(period: const Duration(seconds: 36));

  /// Cross-fades the flow between tracks.
  late final AnimationController _flowFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  /// What is shown; kept while the player slides away.
  EdgeSnapshot _snapshot = const EdgeSnapshot(side: 'right');
  EdgeSide _side = EdgeSide.right;
  double _overhang = 48;
  EdgePhase _phase = EdgePhase.away;
  bool _dragging = false;
  Timer? _grace;
  _Backdrop? _backdrop;

  /// The artwork blurred for the flow, and the one it replaces.
  ui.Image? _art;
  ui.Image? _previousArt;
  String? _artSource;

  /// The region last sent, to skip repeats.
  Rect? _sentRegion;

  /// The screen beside the player is light: the line is drawn dark.
  bool _onLight = false;

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler(_onNativeCall);
    unawaited(_call('ready'));
    _t.addListener(_syncFlow);
  }

  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _grace?.cancel();
    _backdrop?.image.dispose();
    _art?.dispose();
    _previousArt?.dispose();
    _t.dispose();
    _detach.dispose();
    _flow.dispose();
    _flowFade.dispose();
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
        final next = EdgeSnapshot.fromMap(args);
        if (next.capturable && _backdrop != null) {
          // No more pictures of the screen will come.
          _backdrop!.image.dispose();
          setState(() => _backdrop = null);
        }
        if (next.visible) {
          setState(() => _snapshot = next);
          unawaited(_loadArt(next.artwork));
          if (_phase == EdgePhase.away) unawaited(_go(EdgePhase.handle));
        } else if (_phase != EdgePhase.away) {
          _grace?.cancel();
          unawaited(_go(EdgePhase.away));
        }
      case 'layout' when args is Map:
        setState(() {
          _side = EdgeSide.values.asNameMap()[args['side']] ?? EdgeSide.right;
          _overhang = (args['overhang'] as num? ?? 48).toDouble();
        });
        _sentRegion = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => _sendRegion());
      case 'backdrop' when args is Map:
        await _setBackdrop(args);
      case 'tone' when args is Map:
        final luminance = (args['luminance'] as num? ?? 0).toDouble();
        // A gap between the two, so a mid-grey screen doesn't flicker it.
        final onLight = _onLight ? luminance > 0.45 : luminance > 0.6;
        if (onLight != _onLight) setState(() => _onLight = onLight);
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

  /// Blurs the track's artwork for the flowing background.
  Future<void> _loadArt(String source) async {
    if (source == _artSource) return;
    _artSource = source;
    if (source.isEmpty) return;
    final provider = ResizeImage(
      isRemoteImage(source)
          ? NetworkImage(source)
          : FileImage(File(source)) as ImageProvider,
      width: 160,
    );
    final done = Completer<ImageInfo?>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info);
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete(null);
      },
    );
    stream.addListener(listener);
    final info = await done.future;
    stream.removeListener(listener);
    if (info == null) return;
    final ui.Image baked;
    try {
      baked = await blurArtwork(info.image, width: 48, sigma: 4);
    } finally {
      info.dispose();
    }
    if (!mounted || _artSource != source) {
      baked.dispose();
      return;
    }
    setState(() {
      _previousArt?.dispose();
      _previousArt = _art;
      _art = baked;
    });
    _flowFade.forward(from: 0);
  }

  /// The flow moves only while the glass shows.
  void _syncFlow() {
    final show = _t.value > 1.2 && !MediaQuery.disableAnimationsOf(context);
    if (show) {
      _flow.start();
    } else {
      _flow.stop();
    }
  }

  // ---------------------------------------------------------------- shape --

  /// The outline's rectangle in window coordinates. Docked, it runs
  /// [_overhang] past the screen edge, so its outer corners are never seen;
  /// [detach] 1 pulls it back to its visible part (while dragged).
  Rect _rectFor(EdgeShape shape, Size window, {double detach = 0}) {
    final o = _overhang;
    final reach = shape.depth + o * (1 - detach);
    final along =
        (_side.vertical ? window.height : window.width) / 2 - shape.length / 2;
    return switch (_side) {
      EdgeSide.right => Rect.fromLTWH(
        window.width - o - shape.depth,
        along,
        reach,
        shape.length,
      ),
      EdgeSide.left => Rect.fromLTWH(o * detach, along, reach, shape.length),
      EdgeSide.bottom => Rect.fromLTWH(
        along,
        window.height - o - shape.depth,
        shape.length,
        reach,
      ),
      EdgeSide.top => Rect.fromLTWH(along, o * detach, shape.length, reach),
    };
  }

  /// Where clicks are caught in [phase]: the outline plus room for its
  /// shadow (a little around the thin line). Empty once the player is away.
  Rect _regionFor(EdgePhase phase, Size window) {
    if (phase == EdgePhase.away) return Rect.zero;
    final rect = _rectFor(EdgeShape.of(phase, _side), window);
    final room = phase == EdgePhase.handle ? 4.0 : EdgePlayerView.shadowRoom;
    return Rect.fromLTRB(
      _side == EdgeSide.left ? rect.left : rect.left - room,
      _side == EdgeSide.top ? rect.top : rect.top - room,
      _side == EdgeSide.right ? rect.right : rect.right + room,
      _side == EdgeSide.bottom ? rect.bottom : rect.bottom + room,
    );
  }

  void _sendRegion() {
    if (!mounted) return;
    final region = _regionFor(_phase, MediaQuery.sizeOf(context));
    if (region == _sentRegion) return;
    _sentRegion = region;
    unawaited(
      _call('region', {
        'left': region.left,
        'top': region.top,
        'right': region.right,
        'bottom': region.bottom,
        // The line alone needs no picture of the screen behind it.
        'glass': _phase.index >= EdgePhase.capsule.index,
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
            ? const Duration(milliseconds: 420)
            : const Duration(milliseconds: 320),
        curve: growing ? Curves.easeOutQuint : Curves.easeInOutCubic,
      );
    }
    if (!growing && mounted && _phase == phase) _sendRegion();
  }

  // ------------------------------------------------------- hover and drag --

  void _onEnter() {
    _grace?.cancel();
    if (_phase == EdgePhase.handle) unawaited(_go(EdgePhase.capsule));
  }

  void _onExit() {
    if (_dragging || _phase.index < EdgePhase.capsule.index) return;
    _grace?.cancel();
    _grace = Timer(EdgePlayerView.grace, () => _go(EdgePhase.handle));
  }

  void _onDragStart() {
    if (_phase != EdgePhase.capsule) return;
    _grace?.cancel();
    _dragging = true;
    _detach.animateTo(
      1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    unawaited(_call('dragStart'));
  }

  void _onDragUpdate() {
    if (_dragging) unawaited(_call('dragUpdate'));
  }

  void _onDragEnd() {
    if (!_dragging) return;
    _dragging = false;
    // The runner springs the window onto the edge; the outline flattens
    // against it as it lands, the flares overshooting a little.
    _detach.animateBack(
      0,
      duration: const Duration(milliseconds: 520),
      curve: const Interval(0.35, 1, curve: Curves.easeOutBack),
    );
    final window = MediaQuery.sizeOf(context);
    final box = _rectFor(EdgeShape.of(_phase, _side), window, detach: 1);
    unawaited(
      _call('dragEnd', {
        'centerX': box.center.dx,
        'centerY': box.center.dy,
        'depth': EdgeShape.capsuleDepth,
      }),
    );
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
      child: GestureDetector(
        onPanStart: (_) => _onDragStart(),
        onPanUpdate: (_) => _onDragUpdate(),
        onPanEnd: (_) => _onDragEnd(),
        onPanCancel: _onDragEnd,
        child: AnimatedBuilder(
          animation: Listenable.merge([_t, _detach]),
          builder: (context, _) {
            final t = _t.value;
            final shape = EdgeShape.at(t, _side);
            // The visible box, whether docked or dragged.
            final inner = _rectFor(shape, window, detach: 1);
            final glass = ((t - 1) / 0.6).clamp(0.0, 1.0);
            final capsule =
                ((t - 1.3) / 0.7).clamp(0.0, 1.0) *
                (1 - ((t - 2) / 0.4).clamp(0.0, 1.0));
            final panel = ((t - 2.45) / 0.55).clamp(0.0, 1.0);
            return Stack(
              children: [
                _Glass(
                  outline: EdgeOutline(
                    inner,
                    _side,
                    radius: shape.radius,
                    attach: 1 - _detach.value,
                  ),
                  handle: t.clamp(0.0, 1.0),
                  onLight: _onLight,
                  amount: glass,
                  backdrop: _backdrop,
                  art: _art,
                  previousArt: _previousArt,
                  flow: _flow,
                  fade: _flowFade,
                ),
                if (capsule > 0)
                  Positioned.fromRect(
                    rect: _capsuleBox(inner, t),
                    child: Opacity(
                      opacity: capsule,
                      child: _CapsuleContent(
                        snapshot: _snapshot,
                        vertical: _side.vertical,
                        onMore: () => _go(EdgePhase.panel),
                        onCommand: _command,
                      ),
                    ),
                  ),
                if (panel > 0)
                  Positioned.fromRect(
                    rect: Rect.fromCenter(
                      center: inner.center,
                      width: EdgeShape.panelSize.width,
                      height: EdgeShape.panelSize.height,
                    ),
                    child: Opacity(
                      opacity: panel,
                      child: Transform.scale(
                        scale: ui.lerpDouble(0.94, 1, panel),
                        child: _PanelContent(
                          snapshot: _snapshot,
                          onLess: () => _go(EdgePhase.capsule),
                          onCommand: _command,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The strip's contents. Coming out, they ride along with its inner
  /// edge, as if pulled from behind the screen.
  Rect _capsuleBox(Rect inner, double t) {
    final length = EdgeShape.of(EdgePhase.capsule, _side).length;
    final size = _side.vertical
        ? Size(EdgeShape.capsuleDepth, length)
        : Size(length, EdgeShape.capsuleDepth);
    final c = inner.center;
    if (t > 2) {
      return Rect.fromCenter(center: c, width: size.width, height: size.height);
    }
    return switch (_side) {
      EdgeSide.right => Offset(inner.left, c.dy - size.height / 2) & size,
      EdgeSide.left =>
        Offset(inner.right - size.width, c.dy - size.height / 2) & size,
      EdgeSide.bottom => Offset(c.dx - size.width / 2, inner.top) & size,
      EdgeSide.top =>
        Offset(c.dx - size.width / 2, inner.bottom - size.height) & size,
    };
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

/// The player's outline: its visible box with rounded inner corners. Stuck
/// to the edge ([attach] 1) its outer side is flat against the screen edge
/// and flares into it with concave curves, as if it flowed out of the
/// edge; pulled off ([attach] 0) it is a plain rounded rectangle.
@immutable
class EdgeOutline {
  const EdgeOutline(
    this.box,
    this.side, {
    required this.radius,
    required this.attach,
  });

  final Rect box;
  final EdgeSide side;
  final double radius;
  final double attach;

  /// The largest flare, and how far into the screen it reaches along the
  /// edge beyond the box.
  static const flare = 18.0;

  /// The outer corners: rounded while loose (shrinking through the first
  /// half of [attach]), then flaring out (through the second half).
  double get _outerRadius => radius * (1 - 2 * attach).clamp(0.0, 1.0);
  double get _flare =>
      math.min(flare, depth / 2) * (2 * attach - 1).clamp(0.0, 1.2);

  double get depth => side.vertical ? box.width : box.height;
  double get length => side.vertical ? box.height : box.width;

  /// The filled shape.
  Path get path => _build(closed: true);

  /// The lit rim: the whole outline while loose, all but the side against
  /// the screen edge once stuck.
  Path get rim => _build(closed: _flare <= 0);

  /// Maps a point measured from the edge (u ≤ 0 into the screen, v along
  /// it) into the window.
  Offset _at(double u, double v) => switch (side) {
    EdgeSide.right => Offset(box.right + u, box.top + v),
    EdgeSide.left => Offset(box.left - u, box.top + v),
    EdgeSide.bottom => Offset(box.left + v, box.bottom + u),
    EdgeSide.top => Offset(box.left + v, box.top - u),
  };

  /// Left and bottom mirror the drawing, which turns arcs the other way.
  bool get _mirrored => side == EdgeSide.left || side == EdgeSide.bottom;

  Path _build({required bool closed}) {
    final d = depth;
    final l = length;
    final r = math.min(radius, math.min(d, l) / 2);
    final ro = math.min(_outerRadius, math.min(d, l) / 2);
    final f = _flare;
    final path = Path();
    void arc(double u, double v, double radius, {required bool clockwise}) {
      if (radius <= 0) {
        path.lineTo(_at(u, v).dx, _at(u, v).dy);
        return;
      }
      path.arcToPoint(
        _at(u, v),
        radius: Radius.circular(radius),
        clockwise: clockwise != _mirrored,
      );
    }

    void line(double u, double v) => path.lineTo(_at(u, v).dx, _at(u, v).dy);

    // From the edge at the top, across to the inner side, down, and back.
    final start = f > 0 ? _at(0, -f) : _at(0, ro);
    path.moveTo(start.dx, start.dy);
    if (f > 0) {
      arc(-f, 0, f, clockwise: true);
    } else {
      arc(-ro, 0, ro, clockwise: false);
    }
    line(-d + r, 0);
    arc(-d, r, r, clockwise: false);
    line(-d, l - r);
    arc(-d + r, l, r, clockwise: false);
    if (f > 0) {
      line(-f, l);
      arc(0, l + f, f, clockwise: true);
    } else {
      line(-ro, l);
      arc(0, l - ro, ro, clockwise: false);
    }
    if (closed) path.close();
    return path;
  }

  @override
  bool operator ==(Object other) =>
      other is EdgeOutline &&
      other.box == box &&
      other.side == side &&
      other.radius == radius &&
      other.attach == attach;

  @override
  int get hashCode => Object.hash(box, side, radius, attach);
}

/// The outline drawn. As the thin line ([handle] 0–1) it is a bar that
/// stands out from the screen beside it (dark [onLight], light otherwise);
/// as the player ([amount] 0–1) it is glass: the blurred screen behind, the
/// track's artwork flowing over it as in Now Playing, a dark wash, a
/// hairline of light along its inner sides and a soft shadow.
class _Glass extends StatelessWidget {
  const _Glass({
    required this.outline,
    required this.handle,
    required this.onLight,
    required this.amount,
    required this.backdrop,
    required this.art,
    required this.previousArt,
    required this.flow,
    required this.fade,
  });

  final EdgeOutline outline;
  final double handle;
  final bool onLight;
  final double amount;
  final _Backdrop? backdrop;
  final ui.Image? art;
  final ui.Image? previousArt;
  final ValueListenable<double> flow;
  final Animation<double> fade;

  @override
  Widget build(BuildContext context) {
    final path = outline.path;
    final bounds = path.getBounds();
    final backdrop = this.backdrop;
    final hasArt = art != null || previousArt != null;
    final wash = hasArt
        ? 0.5
        : backdrop == null
        ? 0.92
        : 0.66;
    return Positioned.fill(
      child: CustomPaint(
        painter: _ShadowPainter(path, amount),
        foregroundPainter: _RimPainter(outline.rim, bounds, amount),
        child: ClipPath(
          clipper: _ShapeClipper(path),
          child: Stack(
            children: [
              // The line, before the glass takes over.
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  color: onLight
                      ? Color.fromRGBO(0, 0, 0, 0.6 * handle * (1 - amount))
                      : Color.fromRGBO(
                          255,
                          255,
                          255,
                          0.5 * handle * (1 - amount),
                        ),
                ),
              ),
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
              if (hasArt && amount > 0)
                Positioned.fromRect(
                  rect: bounds,
                  child: Opacity(
                    // Over the blurred screen, a little of it shows through.
                    opacity: (backdrop == null ? 1 : 0.85) * amount,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: ArtworkFlowPainter(
                          shown: art,
                          previous: previousArt,
                          fade: fade,
                          flow: flow,
                        ),
                      ),
                    ),
                  ),
                ),
              if (amount > 0)
                Positioned.fill(
                  child: ColoredBox(
                    color: Color.fromRGBO(12, 12, 14, wash * amount),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.shape);

  final Path shape;

  @override
  Path getClip(Size size) => shape;

  @override
  bool shouldReclip(_ShapeClipper old) => old.shape != shape;
}

/// A soft shadow just under the outline, darkest beneath its middle.
class _ShadowPainter extends CustomPainter {
  const _ShadowPainter(this.shape, this.amount);

  final Path shape;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    canvas.drawPath(
      shape.shift(const Offset(0, 4)),
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.32 * amount)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  @override
  bool shouldRepaint(_ShadowPainter old) =>
      old.shape != shape || old.amount != amount;
}

/// Light catching the glass: brighter at the top, fading downwards.
class _RimPainter extends CustomPainter {
  const _RimPainter(this.rim, this.bounds, this.amount);

  final Path rim;
  final Rect bounds;
  final double amount;

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    canvas.drawPath(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          bounds.topCenter,
          bounds.bottomCenter,
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
      old.rim != rim || old.bounds != bounds || old.amount != amount;
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
        : isRemoteImage(source)
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

/// Opens NOIR when clicked: the artwork, and the title with the artist.
class _OpensApp extends StatelessWidget {
  const _OpensApp({required this.onCommand, required this.child});

  final void Function(EdgeCommand, [num?]) onCommand;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Open NOIR',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onCommand(EdgeCommand.open),
        child: child,
      ),
    ),
  );
}

class _Titles extends StatelessWidget {
  const _Titles({
    required this.snapshot,
    required this.titleSize,
    required this.centered,
  });

  final EdgeSnapshot snapshot;
  final double titleSize;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final align = centered ? TextAlign.center : TextAlign.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          snapshot.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: text.labelSmall!.copyWith(
            fontSize: titleSize,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          snapshot.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: align,
          style: text.labelSmall!.copyWith(
            fontSize: titleSize - 1.5,
            color: const Color(0x99FFFFFF),
          ),
        ),
      ],
    );
  }
}

/// The strip: upright on the left and right edges, lying along the top and
/// bottom ones.
class _CapsuleContent extends StatelessWidget {
  const _CapsuleContent({
    required this.snapshot,
    required this.vertical,
    required this.onMore,
    required this.onCommand,
  });

  final EdgeSnapshot snapshot;
  final bool vertical;
  final VoidCallback onMore;
  final void Function(EdgeCommand, [num?]) onCommand;

  @override
  Widget build(BuildContext context) {
    final controls = [
      _IconButton(
        icon: Icons.skip_previous_rounded,
        label: 'Previous',
        size: 18,
        onPressed: snapshot.canPrevious
            ? () => onCommand(EdgeCommand.previous)
            : null,
      ),
      _PlayButton(
        playing: snapshot.playing,
        size: 30,
        onPressed: () => onCommand(EdgeCommand.playPause),
      ),
      _IconButton(
        icon: Icons.skip_next_rounded,
        label: 'Next',
        size: 18,
        onPressed: snapshot.canNext ? () => onCommand(EdgeCommand.next) : null,
      ),
      if (snapshot.canLike)
        _IconButton(
          icon: snapshot.liked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: snapshot.liked ? 'Liked' : 'Like',
          size: 15,
          onPressed: () => onCommand(EdgeCommand.like),
        ),
      _IconButton(
        icon: Icons.more_horiz_rounded,
        label: 'More',
        size: 16,
        onPressed: onMore,
      ),
    ];
    final art = _Artwork(snapshot.artwork, size: 34, radius: 8);
    if (!vertical) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: _OpensApp(
                onCommand: onCommand,
                child: Row(
                  children: [
                    art,
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Titles(
                        snapshot: snapshot,
                        titleSize: 11,
                        centered: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            ...controls,
          ],
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _OpensApp(
          onCommand: onCommand,
          child: Column(
            children: [
              art,
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _Titles(
                  snapshot: snapshot,
                  titleSize: 11,
                  centered: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final (i, control) in controls.indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          control,
        ],
      ],
    );
  }
}

/// The wider player, opened with "more" on the strip.
class _PanelContent extends StatelessWidget {
  const _PanelContent({
    required this.snapshot,
    required this.onLess,
    required this.onCommand,
  });

  final EdgeSnapshot snapshot;
  final VoidCallback onLess;
  final void Function(EdgeCommand, [num?]) onCommand;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
      child: Column(
        children: [
          _OpensApp(
            onCommand: onCommand,
            child: Row(
              children: [
                _Artwork(snapshot.artwork, size: 56, radius: 12),
                const SizedBox(width: 12),
                Expanded(
                  child: _Titles(
                    snapshot: snapshot,
                    titleSize: 14,
                    centered: false,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _Progress(
              snapshot: snapshot,
              onSeek: (p) => onCommand(EdgeCommand.seek, p.inMilliseconds),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _IconButton(
                icon: Icons.skip_previous_rounded,
                label: 'Previous',
                size: 26,
                onPressed: snapshot.canPrevious
                    ? () => onCommand(EdgeCommand.previous)
                    : null,
              ),
              const SizedBox(width: 14),
              _PlayButton(
                playing: snapshot.playing,
                size: 44,
                onPressed: () => onCommand(EdgeCommand.playPause),
              ),
              const SizedBox(width: 14),
              _IconButton(
                icon: Icons.skip_next_rounded,
                label: 'Next',
                size: 26,
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
                  size: 16,
                  onPressed: () => onCommand(EdgeCommand.like),
                ),
              const SizedBox(width: 4),
              Expanded(
                child: _Volume(
                  volume: snapshot.volume,
                  onChanged: (v) => onCommand(EdgeCommand.volume, v),
                ),
              ),
              const SizedBox(width: 4),
              _IconButton(
                icon: Icons.more_horiz_rounded,
                label: 'Less',
                size: 16,
                onPressed: onLess,
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
            color: Color(0xFFEDEDED),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Color(0x33FFFFFF), blurRadius: 10)],
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
      fontSize: 10,
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
                child: Center(child: _Line(fraction: fraction)),
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

/// A 3 px track filled from the left up to [fraction].
class _Line extends StatelessWidget {
  const _Line({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    width: double.infinity,
    child: CustomPaint(painter: _LinePainter(fraction.clamp(0.0, 1.0))),
  );
}

class _LinePainter extends CustomPainter {
  const _LinePainter(this.fraction);

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, radius),
        Paint()..color = const Color(0x33FFFFFF),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * fraction, size.height),
          radius,
        ),
        Paint()..color = Colors.white,
      );
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.fraction != fraction;
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
          size: 15,
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
