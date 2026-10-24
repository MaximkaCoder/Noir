# Known limitations

## By policy or missing official APIs

| Not available | Why | NOIR instead |
|---|---|---|
| YouTube Music library (saved albums, songs, artists, YT Music likes) | No official API | YouTube playlists, liked videos, subscriptions (Phase 5) |
| YouTube Music's own "Liked music" list | No YouTube Music API; the Data API only has all liked videos | "Liked music": liked videos filtered by a heuristic (Music category, "- Topic" and VEVO channels). It misses music filed under other categories and keeps non-music filed under Music; "All likes" shows everything |
| Instant YouTube updates | The Data API cannot push changes | Full sync every 15 min / on foreground, plus a background re-check (throttled to 30 s) when a YouTube page is opened |
| Background / screen-off / audio-only YouTube playback | YouTube Developer Policies III.I.7, III.I.9 | Visible embedded player; full audio features for local files |
| Downloading YouTube content | Policy III.E.1.b | — |
| YouTube watch history | Not exposed by the API | NOIR's own local history |
| "Daily Mix" / recommendations | No legitimate source | Shuffle library, recently played |
| Explicit-content badges | No reliable data source | — |

## This version

- **Google / YouTube is not connected yet.** The capability audit, OAuth design
  and a working WebView2 embed spike exist; the integration is Phase 5.
- **Windows media controls** use System Media Transport Controls through
  NOIR's own runner code (no Rust-based package): media keys work while the
  window is unfocused or minimized, and the Windows media flyout shows the
  track with play/pause/next/previous. When NOIR is focused the same key
  press may arrive both as a key event and from SMTC; a press seen from both
  within 400 ms acts once. If another app owns the current Windows media
  session, unfocused media keys go to that app. Keys pressed while the
  YouTube video has focus go to the video's WebView2. In-app shortcuts:
  Space (play/pause), Ctrl+←/→ (previous/next), Ctrl+K (search), Ctrl+P (Now
  Playing), Ctrl+, (Settings), Esc (close player), Alt+← or the mouse Back
  button (go back).
- **No system tray or global hotkeys.**
- **Crossfade** applies to local files only and is skipped for tracks shorter
  than twice the fade length and in repeat-one mode.
- **Gapless playback** is not guaranteed on Windows (media_kit backend).
- **No automatic low-performance detection** yet; Performance mode is manual.
- **Window controls** are the reference design's three dots in the top-right
  corner of a frameless window (owner decision) rather than standard caption
  buttons. Windows 11 snap layouts on hovering "maximize" are therefore not
  available; Win+Arrow snapping still works. Corners stay square on the
  frameless window.
- **Android is paused by owner decision** (Windows first). The project is
  configured (manifest, media session, compileSdk 37, AGP 9.4.1) but the
  release APK does not build yet: `:app:compileReleaseJavaWithJavac` fails
  after the AGP upgrade. Not investigated further.
- **macOS / iOS are paused by owner decision.** Not built or run; CI jobs are
  prepared.

## Platform build status

| Platform | Status |
|---|---|
| Windows | Debug and release builds verified; unit, widget and integration tests pass on Windows |
| Android | Paused; release APK build currently fails (see above) |
| macOS | Paused; not built |
| iOS | Paused; not built |
