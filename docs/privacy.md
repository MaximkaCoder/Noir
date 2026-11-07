# Privacy

## Stored on this device

- Library index: file paths, tags (title, artist, album, year, track number,
  duration), file size and modification time.
- Artwork extracted from your files (app support folder → `artwork/`).
- Playlists, local favorites, listening history (track + time), search
  history, settings and the last playback session.
- Songs and artists you marked "Not interested", and which playlists you
  hid from the sidebar.
- On Android/iOS: copies of files you import with "Add files" (app documents
  folder → `NOIR Music/`).

Everything can be cleared in Settings (Library, Recommendations, Storage)
or by removing library folders.

## Sent anywhere

Nothing, except the lyrics lookups and YouTube Music discovery described
below. There is no telemetry, no analytics and no third-party tracking.
Fonts are bundled. Your library, playlists and history never leave the device.

## YouTube Music discovery (anonymous)

Discover on Home, the "YouTube Music" part of Search and radio (autoplay
after the queue ends, "Start radio") ask music.youtube.com's web API
directly, as a logged-out visitor:

- **Sent:** what the feature needs: search text (typed in Search, or a
  local song's artist and title for "Start radio"), the video id a radio is
  based on, the playlist/album opened, the mood chip picked, plus the
  system language and country.
- **Never sent:** cookies, Google sign-in or OAuth tokens, or anything
  else tied to your account. The client has its own HTTP connection with a
  guard that strips such headers. YouTube hands every logged-out visitor an
  anonymous visitor id; NOIR keeps it in memory only.
- **Stored:** results are kept in memory for at most 30 minutes (home
  feed) or a few minutes (search, radio, playlists) and never written to
  disk.

Anything you play still goes through the official YouTube embedded player.

"Export diagnostics" writes a JSON file you choose to share. It contains app
version, OS, locale, settings and item counts — no paths, titles, history or
account data.

## Lyrics (YouTube Music, LRCLIB)

A lyrics lookup happens only while the Lyrics panel is open in Now Playing,
for the song currently playing. Lyrics are off at every launch; leave the
panel closed and nothing is ever sent.

**YouTube Music** (anonymous, through the same logged-out client as
discovery above — no cookies, sign-in or tokens). For a YouTube song NOIR
asks music.youtube.com for that video's Lyrics tab, then for the lyrics
behind it. Time-synced lyrics are only given to YouTube Music's Android
app, so that one request introduces itself as the Android app (its client
name, version and user agent) and carries no visitor id; plain lyrics are
asked as the web client. Sent: the video id and the lyrics page id, plus the
system language and country. Lyrics there are licensed from providers such
as Musixmatch or LyricFind, which NOIR names under the lyrics.

**LRCLIB** ([lrclib.net](https://lrclib.net), a free community lyrics
database) is asked for local files first, and for YouTube songs when YouTube
Music has no time-synced lyrics. It is sent:

- the song title and artist (for YouTube videos: the cleaned-up video title
  and channel name), the album for local files, and the duration in seconds;
- a `User-Agent: NOIR/<version>` header, plus your IP address as with any
  web request.

When LRCLIB has no time-synced lyrics for a local file, NOIR searches
YouTube Music's songs for its artist and title (anonymously, as above),
and uses the lyrics of a song whose title, artist and length (within 3 s)
match.

No account, file path or listening history is sent. Answers are kept in
memory for the last 50 songs and are gone when NOIR quits.

## Google account (optional)

Signing in with Google is optional. You sign in on Google's own page in
your browser; NOIR never sees your password. Details of the flow are in
[oauth-flow.md](oauth-flow.md).

- **Permissions asked:** your name, email and Google account id (`openid
  email profile`) and read-only access to your YouTube account
  (`youtube.readonly`). Write access is asked separately, only when you use
  a feature that needs it (see below).
- **Read from YouTube:** your playlists and the videos in them, your liked
  videos, and the title, channel, duration and thumbnail of those videos.
  NOIR doesn't read subscriptions, watch history, comments or anything
  else.
- **Stored on this device:** your name, email and account id, and a copy
  of the playlists and videos above so the library opens offline. That copy
  is refreshed while you stay connected and anything not refreshed for 30
  days is deleted.
- **Sign-in tokens** stay on this device, in the system's secure storage
  (Windows Credential Manager, Android Keystore, Apple Keychain), and are
  sent only to Google.
- **Shared with:** nobody. Data from your Google account goes only between
  your device and Google. NOIR has no server, and doesn't use the data for
  ads or to train AI models.
- **Disconnect** in Settings → Accounts revokes NOIR's access at Google and
  deletes the account data and the YouTube copy from this device. You can
  also remove NOIR's access at https://myaccount.google.com/permissions.

NOIR's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements. See also the
[Google Privacy Policy](https://policies.google.com/privacy) and the
[YouTube Terms of Service](https://www.youtube.com/t/terms).

## Written to your YouTube account

NOIR changes your YouTube account only when you ask it to, and only after you
grant the extra permission ("manage your YouTube account") in your browser:

- **Heart on a YouTube song** — adds that video to the playlist you chose in
  Settings → Accounts → "Save hearted songs to" (`playlistItems.insert`).
  Tapping the filled heart removes it from that playlist again
  (`playlistItems.delete`). Nothing else in the playlist is touched.
- **Create new playlist…** — creates one **private** playlist with the name
  you typed (default "NOIR Likes", `playlists.insert`).
- **Liked music** — if you choose it as the heart's target, or tick it in
  "Add to playlist…", NOIR likes the video on YouTube (`videos.rate`).
  Removing a song from Liked music clears that rating.
- **Not interested** on a YouTube song also dislikes it on YouTube
  (`videos.rate`), if NOIR has this permission. Allowing the song again in
  Settings clears the rating. Without the permission the choice stays in
  NOIR.

NOIR never deletes playlists and never writes anything in the background. On this
device it remembers which playlist you chose (deleted when you disconnect).
You can withdraw the permission at https://myaccount.google.com/permissions
or by disconnecting in Settings.

## Contact

Questions about your data or this policy: noir.support.mail@gmail.com
