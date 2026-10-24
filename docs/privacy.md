# Privacy

## Stored on this device

- Library index: file paths, tags (title, artist, album, year, track number,
  duration), file size and modification time.
- Artwork extracted from your files (app support folder → `artwork/`).
- Playlists, local favorites, listening history (track + time), search
  history, settings and the last playback session.
- On Android/iOS: copies of files you import with "Add files" (app documents
  folder → `NOIR Music/`).

Everything can be cleared in Settings → Library (artwork cache, search
history, listening history) or by removing library folders.

## Sent anywhere

Nothing. This version makes no network requests with your data, has no
telemetry, no analytics and no third-party tracking. Fonts are bundled.

"Export diagnostics" writes a JSON file you choose to share. It contains app
version, OS, locale, settings and item counts — no paths, titles, history or
account data.

## Google / YouTube (future version)

When account support ships, NOIR will contact only Google, only after you
connect, using the scopes described in [oauth-flow.md](oauth-flow.md). Data
from YouTube will be cached at most 30 days and deleted when you disconnect.
NOIR's privacy policy will link the Google Privacy Policy and the YouTube Terms
of Service, as Google's policies require.
