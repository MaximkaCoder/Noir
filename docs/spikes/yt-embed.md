# Spike: YouTube IFrame Player in WebView2 (Windows)

Date: 2026-10-24. Code: `spikes/yt_embed/` (standalone; not part of the app).

## Question

Can NOIR play YouTube content on Windows through the **official IFrame Player API**
inside the OS WebView (WebView2) while satisfying YouTube's embedder-identity rule
(HTTP Referer / `origin`), i.e. without Error 153?

## Setup

- Flutter 3.47.8, webview_windows 0.4.0, WebView2 runtime 155.0.4283.62.
- Player page served from `https://app.noir.player/player.html` via WebView2
  `SetVirtualHostNameToFolderMapping` (`addVirtualHostNameMapping`), player param
  `origin: 'https://app.noir.player'`. The host name is NOIR's app ID.
- Control run: the identical page loaded with `NavigateToString` (`loadStringContent`),
  which has origin `null` and sends no Referer.
- Player 480×270 (≥ 200×200), visible, nothing overlaid, muted for autoplay in the test.

## Result

| Mode | Origin | Events |
|---|---|---|
| Virtual host mapping | `https://app.noir.player` | `ready` → `state 1` (playing) → `getCurrentTime()` advanced 2 s → 26 s |
| NavigateToString (control) | `null` | `ready` → **`error 153`**, time stayed 0 |

**Conclusion: works.** Virtual host mapping gives the page a real HTTPS origin, the
iframe sends a Referer, and state/time events reach Dart through
`chrome.webview.postMessage`. The control run reproduces Error 153, so the identity
mechanism is what makes it work.

## Implications for Phase 5

- Windows `YouTubeEmbedEngine` = webview_windows + virtual host mapping to a folder
  holding NOIR's player page; Dart ↔ JS via `postWebMessage` / `webMessage`.
- Android / iOS / macOS: youtube_player_iframe 6.0.2 with `origin: 'https://app.noir.player'`.
  **Not verified here** (no Android device/emulator or macOS in this spike).
- Autoplay with sound in WebView2 may require a user gesture; verify in Phase 5 (the
  spike used `mute: 1`).
- webview_windows 0.4.0 is ~2 years old; keep it behind the `PlaybackEngine` interface so
  it can be replaced.
