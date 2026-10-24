/// YouTube's video category for music (`snippet.categoryId`).
const youTubeMusicCategoryId = '10';

final _vevoWord = RegExp(r'\bVEVO\b');

/// Whether a YouTube video is probably music.
///
/// There is no official YouTube Music API, so "Liked music" is approximated
/// from data the Data API does return: the Music category, YouTube Music's
/// auto-generated "Artist - Topic" channels, and VEVO channels
/// ("TaylorSwiftVEVO", "VEVO Hits", but not "VEVOR"). Uploads that use
/// another category on an ordinary channel are missed, and non-music videos
/// filed under Music are kept.
bool isMusicVideo({required String? categoryId, required String channelTitle}) {
  if (categoryId == youTubeMusicCategoryId) return true;
  final channel = channelTitle.trim();
  return channel.endsWith(' - Topic') ||
      channel.endsWith('VEVO') ||
      _vevoWord.hasMatch(channel);
}
