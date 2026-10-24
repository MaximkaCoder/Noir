import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/dialogs.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/analysis/domain/track_analysis.dart';
import 'package:noir/shared/models/media.dart';

/// Debug view of a track's stored analysis (tempo, key, loudness, mix
/// points), with a button to analyse it now.
Future<void> showTrackAnalysis(BuildContext context, Track track) =>
    showGlassDialog<void>(
      context,
      builder: (context) => _TrackAnalysisView(track),
    );

class _TrackAnalysisView extends ConsumerStatefulWidget {
  const _TrackAnalysisView(this.track);

  final Track track;

  @override
  ConsumerState<_TrackAnalysisView> createState() => _TrackAnalysisViewState();
}

class _TrackAnalysisViewState extends ConsumerState<_TrackAnalysisView> {
  bool _working = false;
  bool _failed = false;

  Future<void> _analyse(String path) async {
    setState(() {
      _working = true;
      _failed = false;
    });
    final result = await ref
        .read(analysisQueueProvider.notifier)
        .analyzeFile(path, trackId: widget.track.id);
    if (!mounted) return;
    setState(() {
      _working = false;
      _failed = result == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.noir;
    final analysis = ref.watch(trackAnalysisProvider(widget.track.id));
    final path = ref.read(analysisPathResolverProvider)(widget.track);
    final a = analysis.value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Track analysis', style: t.titleMedium),
        const SizedBox(height: 2),
        Text(
          widget.track.title,
          style: t.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: NoirSpacing.lg),
        if (a != null)
          ..._rows(a).map(
            (r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      r.$1,
                      style: t.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                  ),
                  Expanded(child: Text(r.$2, style: t.bodySmall)),
                ],
              ),
            ),
          )
        else
          Text(
            analysis.isLoading
                ? 'Loading…'
                : path == null
                ? 'No audio file to analyse for this track yet.'
                : 'Not analysed yet.',
            style: t.bodySmall,
          ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(top: NoirSpacing.sm),
            child: Text(
              'This file could not be analysed.',
              style: t.bodySmall?.copyWith(color: c.destructive),
            ),
          ),
        const SizedBox(height: NoirSpacing.xl),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: NoirSpacing.sm,
          runSpacing: NoirSpacing.sm,
          children: [
            if (path != null)
              PillButton(
                label: _working
                    ? 'Analysing…'
                    : a == null
                    ? 'Analyse now'
                    : 'Analyse again',
                icon: Icons.graphic_eq_rounded,
                onPressed: _working ? null : () => unawaited(_analyse(path)),
              ),
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: c.textPrimary),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }

  static List<(String, String)> _rows(TrackAnalysis a) {
    String time(double s) {
      final m = s ~/ 60;
      final rest = (s - m * 60).toStringAsFixed(1).padLeft(4, '0');
      return '$m:$rest';
    }

    String pct(double v) => '${(v * 100).round()}%';
    String times(List<double> ts) => ts.isEmpty ? '—' : ts.map(time).join(', ');

    return [
      (
        'Tempo',
        a.bpm > 0
            ? '${a.bpm.toStringAsFixed(1)} BPM · '
                  '${a.steadyTempo ? 'steady' : 'variable'} · '
                  '${pct(a.tempoConfidence)}'
            : 'No steady pulse',
      ),
      (
        'Key',
        a.key == null
            ? 'Unknown'
            : '${a.key!.name} (${a.key!.camelot}) · ${pct(a.keyConfidence)}',
      ),
      (
        'Loudness',
        '${a.loudnessLufs.toStringAsFixed(1)} LUFS · '
            'peak ${a.peakDb.toStringAsFixed(1)} dBFS',
      ),
      ('Audio', '${time(a.contentStart)} – ${time(a.contentEnd)}'),
      (
        'First downbeat',
        a.firstDownbeat == null ? '—' : time(a.firstDownbeat!),
      ),
      ('Intro ends', time(a.introEnd)),
      ('Outro starts', time(a.outroStart)),
      ('Mix in', times(a.mixInPoints)),
      ('Mix out', times(a.mixOutPoints)),
      (
        'Analysed',
        'v${a.analysisVersion}'
            '${a.elapsedMs == null ? '' : ' in ${a.elapsedMs} ms'}',
      ),
    ];
  }
}
