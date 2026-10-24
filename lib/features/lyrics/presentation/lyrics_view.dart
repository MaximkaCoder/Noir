import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/core/widgets/smooth_scroll.dart';
import 'package:noir/core/widgets/states.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/shared/models/media.dart';

/// Lyrics for [track]: time-synced lines that follow playback, plain text,
/// or a calm state explaining why there are none.
class LyricsView extends ConsumerWidget {
  const LyricsView({required this.track, this.compact = false, super.key});

  final Track track;

  /// Smaller type for narrow windows.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = LyricsRequest.fromTrack(track);
    final lyrics = ref.watch(lyricsProvider(request));
    final fx = NoirEffects.of(context);

    final child = lyrics.when(
      skipLoadingOnRefresh: false,
      loading: () => const Center(
        key: ValueKey('loading'),
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, _) => ErrorState(
        key: const ValueKey('error'),
        title: "Couldn't load lyrics",
        message: 'The lyrics service could not be reached.',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(lyricsProvider(request)),
        compact: true,
      ),
      data: (data) => switch (data) {
        null => const EmptyState(
          key: ValueKey('none'),
          icon: Icons.lyrics_outlined,
          title: 'No lyrics found',
          message: 'There are no lyrics for this song yet.',
          compact: true,
        ),
        InstrumentalLyrics() => const EmptyState(
          key: ValueKey('instrumental'),
          icon: Icons.music_note_rounded,
          title: 'Instrumental',
          message: 'This song has no lyrics.',
          compact: true,
        ),
        PlainLyrics(:final text, :final source) => _Attributed(
          key: const ValueKey('plain'),
          source: source,
          note: 'Not time-synced',
          child: _PlainLyrics(text: text, compact: compact),
        ),
        SyncedLyrics(:final lines, :final source) => _Attributed(
          key: ValueKey(request),
          source: source,
          child: SyncedLyricsList(lines: lines, compact: compact),
        ),
      },
    );
    return AnimatedSwitcher(
      duration: fx.motion(NoirMotion.medium),
      child: child,
    );
  }
}

class _Attributed extends StatelessWidget {
  const _Attributed({
    required this.source,
    required this.child,
    this.note,
    super.key,
  });

  final String source;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: context.noir.textTertiary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        Padding(
          padding: const EdgeInsets.only(top: NoirSpacing.sm),
          child: Text([?note, 'Lyrics from $source'].join(' · '), style: t),
        ),
      ],
    );
  }
}

/// Fades lines out toward the top and bottom edges.
Widget _edgeFade(Widget child) => ShaderMask(
  blendMode: BlendMode.dstIn,
  shaderCallback: (bounds) => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x00000000),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0x00000000),
    ],
    stops: [0, 0.1, 0.88, 1],
  ).createShader(bounds),
  child: child,
);

TextStyle? _lineStyle(BuildContext context, {required bool compact}) =>
    Theme.of(context).textTheme.headlineSmall?.copyWith(
      fontSize: compact ? 22 : 28,
      fontWeight: FontWeight.w700,
      height: 1.3,
      letterSpacing: -0.3,
    );

class _PlainLyrics extends StatelessWidget {
  const _PlainLyrics({required this.text, required this.compact});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = _lineStyle(context, compact: compact)?.copyWith(
      fontSize: compact ? 18 : 22,
      color: context.noir.textPrimary.withValues(alpha: 0.8),
      height: 1.55,
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: _edgeFade(
        SmoothScroll(
          builder: (context, scroll) => SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.symmetric(vertical: NoirSpacing.xxxl),
            child: Text(text.trim(), style: style),
          ),
        ),
      ),
    );
  }
}

/// Time-synced lines. Only this widget listens to playback position, and it
/// rebuilds only when the active line changes.
class SyncedLyricsList extends ConsumerStatefulWidget {
  const SyncedLyricsList({
    required this.lines,
    this.compact = false,
    super.key,
  });

  final List<LyricLine> lines;
  final bool compact;

  /// Where the active line rests, as a fraction of the viewport height.
  static const anchor = 0.38;

  /// How long manual scrolling pauses auto-follow.
  static const followPause = Duration(seconds: 3);

  @override
  ConsumerState<SyncedLyricsList> createState() => _SyncedLyricsListState();
}

class _SyncedLyricsListState extends ConsumerState<SyncedLyricsList> {
  final _scroll = SmoothScrollController();
  late List<GlobalKey> _keys;
  int _active = -1;
  bool _following = true;
  Timer? _resume;

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.lines) GlobalKey()];
    _active = activeLineIndex(
      widget.lines,
      ref.read(playbackEngineProvider).currentPosition,
    );
    ref.listenManual(positionProvider, (_, next) {
      final position = next.value;
      if (position != null) _setActive(activeLineIndex(widget.lines, position));
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _reveal(animate: false),
    );
  }

  @override
  void didUpdateWidget(SyncedLyricsList old) {
    super.didUpdateWidget(old);
    if (old.lines != widget.lines) {
      _keys = [for (final _ in widget.lines) GlobalKey()];
      _active = -1;
    }
  }

  @override
  void dispose() {
    _resume?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _setActive(int index) {
    if (index == _active || !mounted) return;
    setState(() => _active = index);
    if (_following) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  /// Scrolls the active line to [SyncedLyricsList.anchor]. Only this list
  /// scrolls, never the page around it.
  void _reveal({bool animate = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final target = _keys[_active.clamp(0, _keys.length - 1)].currentContext
        ?.findRenderObject();
    if (target == null || !target.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(target);
    if (viewport == null) return;
    final position = _scroll.position;
    final offset = viewport
        .getOffsetToReveal(target, SyncedLyricsList.anchor)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final duration = animate
        ? NoirEffects.of(context).motion(NoirMotion.slow * 2)
        : Duration.zero;
    if (duration == Duration.zero) {
      position.jumpTo(offset);
    } else {
      unawaited(
        position.animateTo(
          offset,
          duration: duration,
          curve: NoirMotion.emphasized,
        ),
      );
    }
  }

  void _pauseFollow() {
    _following = false;
    _resume?.cancel();
    _resume = Timer(SyncedLyricsList.followPause, () {
      _following = true;
      _reveal();
    });
  }

  void _seekTo(int index) {
    _resume?.cancel();
    _following = true;
    unawaited(
      ref.read(playbackProvider.notifier).seek(widget.lines[index].time),
    );
    _setActive(index);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final fx = NoirEffects.of(context);
    final canSeek = ref.watch(
      playbackProvider.select((s) => s.capabilities.canSeek),
    );
    final base = _lineStyle(context, compact: widget.compact);
    _scroll.smooth = fx.animations;

    return LayoutBuilder(
      builder: (context, box) => Listener(
        // Wheel and trackpad scrolling don't send drag notifications.
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _pauseFollow();
        },
        onPointerPanZoomStart: (_) => _pauseFollow(),
        child: NotificationListener<ScrollStartNotification>(
          onNotification: (n) {
            if (n.dragDetails != null) _pauseFollow();
            return false;
          },
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: _edgeFade(
              SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.only(
                  top: box.maxHeight * SyncedLyricsList.anchor,
                  bottom: box.maxHeight * 0.55,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, line) in widget.lines.indexed)
                      _Line(
                        key: _keys[i],
                        text: line.text,
                        state: i == _active
                            ? _LineState.active
                            : i < _active
                            ? _LineState.past
                            : _LineState.future,
                        style: base,
                        color: c.textPrimary,
                        duration: fx.motion(NoirMotion.slow),
                        onTap: canSeek ? () => _seekTo(i) : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _LineState { past, active, future }

class _Line extends StatelessWidget {
  const _Line({
    required this.text,
    required this.state,
    required this.style,
    required this.color,
    required this.duration,
    required this.onTap,
    super.key,
  });

  final String text;
  final _LineState state;
  final TextStyle? style;
  final Color color;
  final Duration duration;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = state == _LineState.active;
    final alpha = switch (state) {
      _LineState.active => 1.0,
      _LineState.past => 0.42,
      _LineState.future => 0.26,
    };
    return Semantics(
      selected: active,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: NoirRadii.mdAll,
        hoverColor: context.noir.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NoirSpacing.sm,
            vertical: NoirSpacing.sm,
          ),
          child: AnimatedScale(
            scale: active ? 1 : 0.94,
            alignment: Alignment.centerLeft,
            duration: duration,
            curve: NoirMotion.standard,
            child: AnimatedDefaultTextStyle(
              duration: duration,
              curve: NoirMotion.standard,
              style: (style ?? const TextStyle()).copyWith(
                color: color.withValues(alpha: alpha),
              ),
              child: Text(text.isEmpty ? '♪' : text),
            ),
          ),
        ),
      ),
    );
  }
}
