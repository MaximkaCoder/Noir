# Design reference

`reference.png` is the visual direction supplied by the product owner. It is a guide,
not a pixel spec, and some of its content conflicts with product rules.

## What NOIR adopts

- **Desktop shell (wide):** a left sidebar with Home / Search / Library, then a "Playlists"
  section that lists the user's playlists, a "Create playlist" pill, and a compact player
  docked at the bottom of the sidebar. Top bar: a pill search field and an account avatar.
- **Desktop shell (medium):** an icon-only rail with Settings and the avatar pinned to the
  bottom.
- **Home:** greeting ("Good morning,") with a quiet subtitle. One wide hero card (artwork
  backdrop, title, subtitle, white circular play button) next to a secondary card.
  "Recently played" is a horizontal row of square artwork with title and artist, plus a
  "See all" link.
- **Now Playing:** artwork on the left, then title, artist and album on the right. Progress
  shows elapsed time and remaining time (`-1:45`). Controls: shuffle, previous, a large
  white play/pause, next, repeat. Below sits an "Up next" glass panel with numbered rows.
- **Library:** a large title with search and "+" actions, pill filter chips (Playlists /
  Artists / Albums / Tracks), and rows with thumbnail, name, count and a chevron.
- **Search:** a pill field with a clear button, filter chips (All / Artists / Albums /
  Tracks / Playlists), a "Top result" card, then grouped sections.
- **Playlist details:** artwork, title, "32 songs · 2h 14m", white play button, shuffle and
  add actions, then a numbered track list with durations right-aligned.
- **Settings:** theme picker as three icon tiles (Dark / Light / System), and toggle rows
  with icon, title and subtitle (e.g. "Liquid Glass — Enable the modern glass effect").
- **Material:** soft grey glass panels with a hairline light border and generous radii
  (~16–20 px) on a near-black background. The only bright fill is the white primary
  action.

## Deliberate deviations and owner decisions

| Reference element | NOIR behavior | Reason |
|---|---|---|
| macOS-style traffic-light dots, top-left | **Owner decision (2026-10-24):** the same three dots, but in the **top-right corner** (minimize · maximize · close, close outermost) on a fully frameless window with no system title bar. Colored when focused, grey when not; tooltips on every dot | Reference look, Windows placement |
| "Daily Mix — Curated for you" | Not shown | No legitimate recommendation source |
| "Crossfade" toggle | **Implemented for local files** with two players and a volume ramp; labeled "Local music only" | Owner decision 2026-10-24 |
| "Liked Songs" | "Favorites" (local, labeled as local) for local files; "Liked videos" for YouTube in Phase 5 | No YouTube Music likes API; a local favorite does not sync to YouTube |
| "E" explicit badges | Not shown | No reliable source in local tags or the YouTube Data API |
| Colored artwork (e.g. orange album) | Kept as-is | Artwork is content; the UI chrome stays monochrome |
