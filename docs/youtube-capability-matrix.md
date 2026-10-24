# YouTube / Google capability matrix

Audit date: 2026-10-24. Every row was checked against official Google documentation
(sources at the bottom). Items marked **unverified** must be confirmed at runtime in
Phase 5 before the UI advertises them.

## Summary

NOIR can connect a Google account, read the user's YouTube channel, playlists, playlist
items, liked videos and subscriptions, and play YouTube videos through the official
embedded player. NOIR **cannot** provide a YouTube Music library, audio-only YouTube
playback, background/screen-off YouTube playback, or offline YouTube content: there is
no official API for the first, and YouTube's Developer Policies prohibit the others.

For YouTube content NOIR is therefore a *visual* music player: the video stays visible
(at least 200×200 px, no overlays) while it plays. Full audio-player features (background
playback, media notifications, crossfade, offline) apply to local files only.

## Matrix

| Feature | Official API support | Required permission | Platform restrictions | Implemented behavior |
|---|---|---|---|---|
| Google sign-in | OAuth 2.0 / OpenID Connect | `openid email profile` | No embedded WebViews for the consent page | System browser (desktop) or platform SDK (mobile). Phase 5 |
| Authenticated channel | `channels.list mine=true` (1 unit) | `youtube.readonly` | — | Fetched once after connect, cached |
| List own playlists | `playlists.list mine=true` (1 unit) | `youtube.readonly` | Watch Later cannot be listed | Supported. Phase 5 |
| Private playlists | Implied by `mine=true`; **unverified** in docs | `youtube.readonly` | — | Verify at runtime before advertising |
| Playlist items | `playlistItems.list` (1 unit) | `youtube.readonly` | Watch History / Watch Later return errors | Supported, paginated. Phase 5 |
| Search | `search.list` (1 unit, separate bucket of **100 calls/day per project**, since 2026-06-01) | API key or OAuth | Quota shared by every user of the app | Submit-only search (no live typing), cached results, explicit "search limit reached" state |
| Liked videos | `videos.list myRating=like` (1 unit, max 1,000 results) | `youtube.readonly` | `playlistItems.list` on the `LL` playlist is **unverified** | Shown as "Liked videos" — never as "YouTube Music likes" |
| YouTube Music library (albums, songs, artists, YT Music likes, recommendations) | **None.** Only unofficial cookie-based libraries exist | — | Not compliant | Not implemented. UI says so |
| Watch history | **No** (`watchHistoryNotAccessible`) | — | — | Not implemented. NOIR keeps its own local play history |
| Subscriptions | `subscriptions.list mine=true` (1 unit) | `youtube.readonly` | — | Optional "Channels" view. Phase 5 |
| Read playback state | IFrame Player API events (`onStateChange`, `getCurrentTime`) | none | OS WebView must send an HTTP Referer (else **Error 153**) | Player events drive `PlaybackState` |
| Control playback | IFrame Player API (`playVideo`, `pauseVideo`, `seekTo`, `loadVideoById`) | none | Player ≥ 200×200 px, no overlays, no modifications | Play/pause/seek/next/prev via the player API |
| Background playback | **Prohibited** (Developer Policies III.I.9) | — | All platforms | `supportsBackgroundPlayback = false`; pause when the player is hidden or the app is minimized |
| Audio-only playback | **Prohibited** (III.I.7) | — | All platforms | Video always visible in Now Playing for YouTube items |
| Offline / download | **Prohibited** (III.E.1.b) | — | All platforms | Not implemented |
| Queue management | No dedicated API. Advancing on state `0` (ended) with `loadVideoById` is documented player usage; no clause forbids it | none | Autoplay only when > 50 % of the player is visible | Local NOIR queue; clearly labeled as not a YouTube playlist |
| Add / remove / reorder playlist items | `playlistItems.insert/update/delete` (50 units each) | `youtube.force-ssl` (requested incrementally on first edit) | Must be clearly user-initiated (III.C.2) | Phase 5, explicit user action only |
| Create playlist | `playlists.insert` (50 units) | `youtube.force-ssl` | — | Phase 5 |

Default quota: 10,000 units/day for regular methods plus the separate 100/day
`search.list` bucket. More quota requires an API Compliance Audit.

## Embedding rules (Required Minimum Functionality)

- Viewport at least 200×200 px; nothing drawn over any part of the player.
- No changes to the player beyond what the API documents; ads are never blocked.
- At most one autoplaying player per screen, and only when > 50 % visible.
- The embed must identify the app via the HTTP `Referer` header (an HTTPS URL built from
  the app ID) and the `origin` player parameter. Missing identity → Error 153.
  - Android: `loadDataWithBaseURL` / headers. iOS & macOS: `loadHTMLString:baseURL:`.
  - Windows: WebView2 — virtual host mapping or `CoreWebView2HttpRequestHeaders`.

## Data rules

- Stored API data must be refreshed or deleted within 30 days.
- After the user disconnects inside NOIR, account data is deleted within 7 days
  (NOIR deletes it immediately).
- Display a link to the YouTube Terms of Service; the privacy policy links the Google
  Privacy Policy and explains revocation at https://myaccount.google.com/permissions.
- YouTube must be clearly attributed as the source of content.

## OAuth per platform (Phase 5)

| Platform | Client type | Flow | Secret |
|---|---|---|---|
| Windows | Desktop app | System browser → loopback `http://127.0.0.1:<random port>`, PKCE S256, `state` check | Google documents desktop apps as public clients ("the client secret is obviously not treated as a secret") and marks it Optional at the token endpoint. Try without; if required, inject at build time, never commit |
| macOS | iOS client via GoogleSignIn, or Desktop loopback as on Windows | — | None (iOS client) |
| Android | Android client (package + SHA-1) | Credential Manager sign-in + `AuthorizationClient.authorize()` → short-lived access token on device, no refresh token, no backend | Not applicable |
| iOS | iOS client | GoogleSignIn SDK + `addScopes` | None |

Revocation: `POST https://oauth2.googleapis.com/revoke?token=…`.
Testing mode: max 100 test users; authorizations expire after 7 days.

## Sources

- https://developers.google.com/youtube/v3/determine_quota_cost
- https://developers.google.com/youtube/v3/revision_history
- https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits
- https://developers.google.com/youtube/v3/docs/search/list
- https://developers.google.com/youtube/v3/docs/videos/list
- https://developers.google.com/youtube/v3/docs/playlistItems/list
- https://developers.google.com/youtube/v3/docs/playlistItems/insert
- https://developers.google.com/youtube/v3/docs/channels
- https://developers.google.com/youtube/terms/developer-policies
- https://developers.google.com/youtube/terms/required-minimum-functionality
- https://developers.google.com/youtube/iframe_api_revision_history
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/identity/protocols/oauth2/policies
- https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration
- https://developers.google.com/youtube/v3/guides/auth/installed-apps
- https://developer.android.com/identity/authorization
- https://developers.google.com/identity/sign-in/ios/api-access
- https://developers.google.com/terms/api-services-user-data-policy
- https://support.google.com/cloud/answer/15549945

## Open questions (verify in Phase 5)

1. Does `playlists.list mine=true` include private playlists?
2. Does `playlistItems.list` on the `LL` playlist still work? (Fallback: `myRating=like`.)
3. Is `youtube.readonly` classified sensitive in the Cloud Console Data Access screen?
4. Does the Desktop token exchange succeed without `client_secret`?
5. Does a minimized desktop window count as a background player? NOIR assumes yes and pauses.
6. ~~Windows embed identity~~ — **verified 2026-10-24**: WebView2 virtual host mapping to
   `https://app.noir.player` plays without Error 153; the no-origin control reproduces
   Error 153. See `docs/spikes/yt-embed.md`. Android/iOS/macOS embed still unverified.
