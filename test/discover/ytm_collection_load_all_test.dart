import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';

void main() {
  FakeInnerTubeClient longPlaylist() => FakeInnerTubeClient()
    ..collections['PL1'] = YtmCollection(
      id: 'VLPL1',
      title: 'Long',
      tracks: [ytTrack('a'), ytTrack('b')],
      continuation: 'c1',
    )
    ..playlistMorePages['c1'] = YtmTrackPage(
      tracks: [ytTrack('c')],
      continuation: 'c2',
    )
    ..playlistMorePages['c2'] = YtmTrackPage(tracks: [ytTrack('d')]);

  test('loadAll pages in the rest of a long playlist', () async {
    final ytm = longPlaylist();
    final container = ProviderContainer(
      overrides: [innerTubeClientProvider.overrideWithValue(ytm)],
    );
    addTearDown(container.dispose);
    const target = (kind: YtmCollectionKind.playlist, id: 'PL1');
    container.listen(ytmCollectionProvider(target), (_, _) {});
    await container.read(ytmCollectionProvider(target).future);

    final ctrl = container.read(ytmCollectionProvider(target).notifier);
    // A page already loading (the list's own trigger) is joined.
    final shown = ctrl.loadMore();
    final all = await ctrl.loadAll();
    expect(await shown, isTrue);
    expect([for (final t in all) t.uri], ['a', 'b', 'c', 'd']);
    expect(ytm.calls.where((c) => c.startsWith('playlistMore')), [
      'playlistMore c1',
      'playlistMore c2',
    ]);
  });

  test('ytmPlaylistTracks follows every page', () async {
    final tracks = await ytmPlaylistTracks(longPlaylist(), 'PL1');
    expect([for (final t in tracks) t.uri], ['a', 'b', 'c', 'd']);
  });
}
