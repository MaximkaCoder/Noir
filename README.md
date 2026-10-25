# NOIR

**Less interface. More music.**

A desktop player for YouTube Music and your own audio files, written in
Flutter. Windows is the main target and the only platform tested so far.

![NOIR on Windows: Home, Now Playing with lyrics, search, an album, settings](docs/screenshots/noir.jpg)

<sub>Screenshots from the Windows build. Lyrics are blurred in the image on
purpose.</sub>

## What it does

Home opens with **Listen again** (what you play most, YouTube only), your
pinned playlists, and **For you**: mixes built from radio seeded by your own
plays, likes and playlists. Below that sits YouTube Music's regular home feed
with its mood chips.

Search goes to YouTube Music (songs, videos, albums, artists, playlists) and
to your local library at the same time. Albums, artists and playlists open as
pages inside the app.

Now Playing shows big artwork over a slowly moving, blurred copy of it. Time
synced lyrics appear next to the cover, line by line or word by word
(karaoke). Lyrics come from YouTube Music, with LRCLIB as a fallback. Click
the cover to pause.

The queue never runs dry: when fewer than five tracks are left, NOIR appends
more of the same YouTube Music radio. If YouTube Music only has a song as a
music video (with intro and skits), NOIR swaps in the plain studio track,
like YouTube Music does in song mode.

Between tracks NOIR can do a plain crossfade or a "smart" transition that
picks the moment and the type of blend for each pair of songs. Both work on
tracks played through NOIR's own audio player.

Connect a Google account and NOIR syncs your YouTube playlists and liked
music both ways. Adding a song to a playlist or removing it in NOIR changes
the playlist on YouTube, and the heart saves to a playlist you choose.

The rest:

- Local files: MP3, M4A/AAC, FLAC, OGG, Opus and WAV, with tags and cover art.
- Liquid Glass surfaces you can turn off, plus a performance mode for laptops
  with integrated graphics.
- Windows media keys and the Windows media flyout work while the window is
  in the background.
- Dark, light and system themes; comfortable and compact density.

## Privacy

Browsing YouTube Music (home feed, search, radio, lyrics) is anonymous. NOIR
sends no cookies and no account tokens there, so nothing it does touches
your Google account.

The Google sign-in is used only for the official YouTube Data API, to read
and edit your playlists and likes. The refresh token sits in the Windows
Credential Manager. Recommendations in **For you** are computed on your
machine from a local play log; Settings has a button that clears it.

Details: [docs/privacy.md](docs/privacy.md).

## How the code is organized

```
lib/
  app/            bootstrap, router, adaptive shell, theme and glass
  core/           database, window chrome, shared widgets
  features/       one folder per feature
    home, discover, search, library, playlists, playback, queue,
    lyrics, youtube, accounts, settings, …
      data/          repositories (Drift)
      domain/        models and interfaces
      application/   Riverpod controllers and providers
      presentation/  screens and widgets
  integrations/
    youtube_music/   anonymous YouTube Music client and parsers
    youtube_data/    YouTube Data API v3 (playlists, likes)
    google_auth/     OAuth 2.0 with PKCE through the system browser
    youtube_playback/ official IFrame player in WebView2
    local_audio/     just_audio + media_kit (libmpv)
    lyrics/          YouTube Music and LRCLIB sources
  shared/         Track, Playlist, PlaybackState and other models
```

State lives in Riverpod 3 providers, without code generation. Anything that
does I/O is a provider, which lets tests swap in fakes for the database, the
audio engine and the network clients.

Playback has a single owner:

```
UI ── commands ──▶ PlaybackController   (queue, shuffle, repeat, radio, session)
                         │
                         ▼
                   PlaybackEngine        (local audio player, or the YouTube embed)
                         │  status, position, completion
                         ▼
                   PlaybackState ──▶ mini player, Now Playing, queue, Windows SMTC
```

Each engine reports what it can do (seek, crossfade, play in the background).
The UI hides controls an engine doesn't support instead of greying them out.

Data is stored in SQLite through Drift (schema v4): the local library,
playlists, play history, cached YouTube playlists and likes, and settings as
JSON documents. Every schema version is snapshotted in `drift_schemas/` and
covered by a migration test.

YouTube sync works in two directions. Pulling compares ETags so unchanged
playlists cost almost nothing. Edits made in NOIR show up locally right
away, go out to the Data API, and are kept on top of YouTube's answers for a
couple of minutes, because YouTube keeps returning the old list for a while
after a write.

## Building

You need Flutter 3.47 (Dart 3.13) and Visual Studio with the C++ desktop
workload and ATL. Full notes are in [docs/setup.md](docs/setup.md).

```powershell
flutter pub get
dart run build_runner build
./tool/run.ps1             # debug run
./tool/run.ps1 -Release    # build\windows\x64\runner\Release\noir.exe
```

Google sign-in needs your own OAuth desktop client. Put its id in
`config/oauth.local.json` (git ignores it; see `config.example/`). Without
it NOIR runs fine, just without the account features.

## Tests

```powershell
flutter analyze
flutter test                               # about 620 unit and widget tests
flutter test integration_test -d windows   # real audio engine on Windows
```

## Platforms

| Platform | State |
|---|---|
| Windows | Daily driver. Debug and release builds tested |
| Android | Paused. The project is set up, the release APK doesn't build yet |
| macOS, iOS | Paused. Never built |

What is missing on purpose, and why: [docs/limitations.md](docs/limitations.md).
How YouTube fits in: [docs/youtube-capability-matrix.md](docs/youtube-capability-matrix.md).

Inter is © The Inter Project Authors, SIL Open Font License 1.1
(`assets/fonts/Inter-LICENSE.txt`).
