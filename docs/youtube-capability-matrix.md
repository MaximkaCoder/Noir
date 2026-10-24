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
| Liked videos | `videos.list myRating=like` (1 unit per 50, max 1,000 results) — **every** liked video, music or not | `youtube.readonly` | `playlistItems.list` on the `LL` playlist is **unverified** | "Liked music" page (heuristic filter, see below) with an "All likes" switch — never called "YouTube Music likes" |
| YouTube Music library (albums, songs, artists, YT Music likes, recommendations) | **None.** No YouTube Music API or scope exists; only unofficial cookie-based libraries | — | Not compliant | Not implemented. UI says so |
| YouTube Music "Liked music" (`LM`) | **None.** `LM` is a YouTube Music-internal list; the Data API documents only the channel's `likes` playlist (`LL`, all liked videos). Not tested live | — | — | Approximated by filtering liked videos |
| Video category | `snippet.categoryId` in `videos.list part=snippet` (no extra cost: same call as details/likes) | `youtube.readonly` | Uploader-chosen | Stored per video; drives the music filter |
| Change detection | Conditional requests: send the response `etag` as `If-None-Match`, get `304 Not Modified`. The docs say every request costs at least 1 unit, so a 304 is not free, just tiny. Not tested live | — | — | Opening a YouTube page re-checks it at most every 30 s |
| Watch history | **No** (`watchHistoryNotAccessible`) | — | — | Not implemented. NOIR keeps its own local play history |
| Subscriptions | `subscriptions.list mine=true` (1 unit) | `youtube.readonly` | — | Optional "Channels" view. Phase 5 |
| Read playback state | IFrame Player API events (`onStateChange`, `getCurrentTime`) | none | OS WebView must send an HTTP Referer (else **Error 153**) | Player events drive `PlaybackState` |
| Control playback | IFrame Player API (`playVideo`, `pauseVideo`, `seekTo`, `loadVideoById`) | none | Player ≥ 200×200 px, no overlays, no modifications | Play/pause/seek/next/prev via the player API |
| Background playback | **Prohibited** (Developer Policies III.I.9) | — | All platforms | `supportsBackgroundPlayback = false`; pause when the player is hidden or the app is minimized |
| Audio-only playback | **Prohibited** (III.I.7) | — | All platforms | Video always visible in Now Playing for YouTube items |
| Offline / download | **Prohibited** (III.E.1.b) | — | All platforms | Not implemented |
| Queue management | No dedicated API. Advancing on state `0` (ended) with `loadVideoById` is documented player usage; no clause forbids it | none | Autoplay only when > 50 % of the player is visible | Local NOIR queue; clearly labeled as not a YouTube playlist |
| Add / remove playlist items | `playlistItems.insert` / `playlistItems.delete` (**50 units each**; removing a row cached before item ids were stored first costs 1 unit for `playlistItems.list videoId=…`) | `youtube` (or `youtube.force-ssl`), requested incrementally on the first heart / target choice | Must be clearly user-initiated (III.C.2) | The heart on YouTube songs saves to / removes from one user-chosen playlist. Optimistic, reverted on error; one request in flight per video (double taps ignored); writes are never retried automatically (a retry could add the video twice). ~100 hearts/day fit in the default quota |
| Reorder playlist items | `playlistItems.update` (50 units) | `youtube` | — | Not implemented |
| Create playlist | `playlists.insert` (50 units) | `youtube` | — | "Create new playlist…" in the save-target picker; private by default, name defaults to "NOIR Likes" |
| Like / rate videos | `videos.rate` (50 units) | `youtube` | — | **Never called.** The heart is a playlist save, not a YouTube like |

Default quota: 10,000 units/day for regular methods plus the separate 100/day
`search.list` bucket. More quota requires an API Compliance Audit.

## Liked music filter

The Data API returns every liked video. NOIR's "Liked music" view keeps a video when
any of these hold (`isMusicVideo`, `lib/features/youtube/domain/music_filter.dart`):

- `snippet.categoryId == "10"` (Music);
- the channel title ends with ` - Topic` (YouTube Music's auto-generated artist channels);
- the channel title ends with `VEVO` or contains the word `VEVO` (not `VEVOR`).

Limits: uploaders pick the category, so music on ordinary channels filed under
Entertainment, People & Blogs, etc. is missed, and non-music videos filed under Music
(podcasts, reactions, gaming music videos) are kept. "All likes" shows everything.
Videos cached before the category was stored are filled in on the next sync with
`videos.list` (1 unit per 50 videos; playlists are not downloaded again).

## Refresh on open

Opening a YouTube playlist or the likes page refreshes it in the background when it
was last checked more than 30 s ago (and no full sync ran in that window). The check is
`playlists.list id=…` (or the first likes page) with `If-None-Match`; items are only
downloaded when the playlist etag differs from the one the cached items came from.
Failures keep the cached list and show a toast. The Library's YouTube section can call
`YouTubeSyncController.refreshPlaylists()` with the same 30 s throttle.

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
   Note: YouTube Music's `LM` ("Liked music") list is not part of the Data API at all.
7. Does the API answer `If-None-Match` with 304 for `playlists.list id=…` and
   `videos.list myRating=like`, and which etag form (quoted or not) does it accept?
   NOIR sends the body `etag` wrapped in quotes; without 304 a check still costs 1 unit
   and writes nothing when the playlist etag is unchanged.
3. Is `youtube.readonly` classified sensitive in the Cloud Console Data Access screen?
4. Does the Desktop token exchange succeed without `client_secret`?
5. Does a minimized desktop window count as a background player? NOIR assumes yes and pauses.
6. ~~Windows embed identity~~ — **verified 2026-10-24**: WebView2 virtual host mapping to
   `https://app.noir.player` plays without Error 153; the no-origin control reproduces
   Error 153. See `docs/spikes/yt-embed.md`. Android/iOS/macOS embed still unverified.
