import 'package:flutter/material.dart';
import 'package:noir/app/theme/design_tokens.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/shared/models/media.dart';

/// Indexes of [tracks] whose title, artist or album contain every word of
/// [query] (case-insensitive). All of them when [query] is blank.
List<int> matchingTracks(List<Track> tracks, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  return [
    for (final (i, t) in tracks.indexed)
      if (words.every(
        '${t.title} ${t.artist ?? ''} ${t.album ?? ''}'.toLowerCase().contains,
      ))
        i,
  ];
}

/// Small search field that filters the songs of one playlist.
class TrackFilterField extends StatefulWidget {
  const TrackFilterField({required this.onChanged, super.key});

  final ValueChanged<String> onChanged;

  @override
  State<TrackFilterField> createState() => _TrackFilterFieldState();
}

class _TrackFilterFieldState extends State<TrackFilterField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.noir;
    final t = Theme.of(context).textTheme;
    return GlassSurface(
      borderRadius: NoirRadii.pillAll,
      blur: 0,
      child: SizedBox(
        width: 260,
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search_rounded, size: 18, color: c.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                onChanged: widget.onChanged,
                style: t.bodyMedium,
                decoration: InputDecoration(
                  hintText: 'Search in playlist',
                  hintStyle: t.bodySmall,
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox(width: 14)
                  : NoirIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Clear',
                      size: 16,
                      onPressed: () {
                        _controller.clear();
                        widget.onChanged('');
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
