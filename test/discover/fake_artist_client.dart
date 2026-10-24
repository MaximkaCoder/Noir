import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';

/// [FakeInnerTubeClient] that also answers artist pages from [artists].
class FakeArtistInnerTube extends FakeInnerTubeClient {
  Map<String, YtmArtist> artists = {};

  @override
  Future<YtmArtist> artist(String browseId) async {
    calls.add('artist $browseId');
    await Future<void>.delayed(Duration.zero);
    if (error case final e?) throw e;
    return artists[browseId] ??
        (throw const InnerTubeException(
          InnerTubeErrorKind.http,
          'YouTube Music refused the request.',
          statusCode: 404,
        ));
  }
}

/// An artist page with five top songs, a full-songs playlist and a few
/// shelves.
YtmArtist fakeArtist({
  String browseId = 'UCmara',
  String name = 'Mara Vale',
  String? bannerUrl,
}) => YtmArtist(
  browseId: browseId,
  name: name,
  subscribers: '1.2M subscribers',
  audience: '3M monthly audience',
  description: 'Mara Vale makes quiet records.',
  bannerUrl: bannerUrl,
  topSongs: [
    for (var i = 1; i <= 5; i++)
      ytTrack('top$i', title: 'Top song $i', artist: name),
  ],
  songsPlaylistId: 'OLAK_all',
  shelves: const [
    YtmShelf(
      title: 'Albums',
      items: [
        YtmAlbumItem(browseId: 'MPREb_low', title: 'Low Light', year: 2024),
      ],
    ),
    YtmShelf(
      title: 'Fans might also like',
      items: [
        YtmArtistItem(
          browseId: 'UCkei',
          title: 'Kei Aoto',
          subtitle: '2M monthly audience',
        ),
      ],
    ),
  ],
);
