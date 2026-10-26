import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/widgets/track_filter.dart';
import 'package:noir/shared/widgets/track_row.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_database.dart';

Track _track(String title, {String? artist, String? album}) => Track(
  id: title,
  source: MediaSource.local,
  title: title,
  uri: title,
  artist: artist,
  album: album,
);

void main() {
  test('matchingTracks needs every word in title, artist or album', () {
    final tracks = [
      _track('Blinding Lights', artist: 'The Weeknd', album: 'After Hours'),
      _track('Espresso', artist: 'Sabrina Carpenter'),
      _track('Save Your Tears', artist: 'The Weeknd', album: 'After Hours'),
    ];
    expect(matchingTracks(tracks, ''), [0, 1, 2]);
    expect(matchingTracks(tracks, 'weeknd'), [0, 2]);
    expect(matchingTracks(tracks, 'after  TEARS'), [2]);
    expect(matchingTracks(tracks, 'carpenter hours'), isEmpty);
  });

  testWidgets('searching a playlist shows only matching songs', (tester) async {
    final app = await TestApp.pump(tester, withMusic: false);
    final library = LibraryRepository(app.db);
    await library.upsertScanned([
      trackRow('a.mp3', title: 'Blinding Lights', artist: 'The Weeknd'),
      trackRow('b.mp3', title: 'Espresso', artist: 'Sabrina Carpenter'),
    ]);
    final playlists = PlaylistRepository(app.db);
    final id = await playlists.create('Mix');
    await playlists.addTracks(id, [
      for (final r in await app.db.select(app.db.tracks).get()) r.id,
    ]);
    app.container.read(routerProvider).go('/library/playlist/$id');
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsNWidgets(2));

    await tester.enterText(
      find.descendant(
        of: find.byType(TrackFilterField),
        matching: find.byType(TextField),
      ),
      'espresso',
    );
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsOneWidget);
    expect(find.text('Espresso'), findsOneWidget);
    expect(find.text('Blinding Lights'), findsNothing);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackRow), findsNWidgets(2));
  });
}
