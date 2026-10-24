# Google OAuth (planned for Phase 5)

Nothing in this version contacts Google. This document fixes the design so
Phase 5 can be implemented and reviewed against it. Sources: see
[youtube-capability-matrix.md](youtube-capability-matrix.md).

## Principles

- NOIR never sees the user's Google password: consent happens in the system
  browser (desktop) or the platform SDK (mobile). Embedded WebViews are
  forbidden by Google for OAuth.
- Minimum scopes: `openid email profile youtube.readonly`. The write scope
  `https://www.googleapis.com/auth/youtube` is never requested at sign-in; it
  is requested incrementally (see below) the first time the user hearts a
  YouTube song or picks / creates the playlist hearted songs go to.
- Permissions are explained before the browser opens (see the account card in
  Settings → Accounts).
- No tokens, cookies or authorization headers are logged.

## Windows / macOS (Desktop client)

1. Generate `state` (32 random bytes) and a PKCE verifier; challenge = S256.
2. Bind `http://127.0.0.1:<random port>` (not `localhost`).
3. Open `https://accounts.google.com/o/oauth2/v2/auth?...` in the default
   browser with `client_id`, `redirect_uri`, `response_type=code`, scopes,
   `code_challenge`, `state`, `access_type=offline`.
4. Accept exactly one request on the loopback server; reject a mismatched
   `state`; show a "you can close this tab" page; handle `error=access_denied`
   as a cancellation.
5. Exchange the code with the verifier. Google documents desktop apps as public
   clients and marks `client_secret` optional; if the exchange requires it,
   it is injected at build time (`--dart-define`), treated as public config,
   never committed.
6. Store the refresh token with `flutter_secure_storage` (Windows Credential
   Manager-backed). Keep the access token in memory only.

## Incremental authorization (playlist write scope)

The heart on a YouTube song saves it to a playlist the user chose (it is
never a YouTube like). That needs `https://www.googleapis.com/auth/youtube`
(`youtube.force-ssl` is accepted too when Google reports it).

1. Trigger: the first heart tap, or choosing / creating the target playlist
   in Settings → Accounts, while the stored grant lacks the write scope. A
   dialog explains what NOIR will do before the browser opens.
2. The same desktop flow runs again (loopback, PKCE, `state`) with
   `scope=openid email profile youtube.readonly youtube`,
   `include_granted_scopes=true`, `access_type=offline`, `prompt=consent`
   and `login_hint=<connected email>`. Google only asks about the new scope.
   (`include_granted_scopes=true` is sent on every authorization; the
   sign-in request itself never contains the write scope.)
3. The token response's `scope` field is the source of truth for what was
   granted. If it lacks the write scope (the user unticked it) or the user
   pressed Cancel (`access_denied`), NOIR keeps the old refresh token and
   says "NOIR can't save songs to your playlists without that permission.
   Everything else keeps working." Read-only features are unaffected.
4. On success the new refresh token (it represents the combined grant)
   replaces the old one in secure storage, together with the granted
   scopes. The old token is not revoked — revoking would end the whole
   grant. The account card then shows "Can save to playlists".
5. If the ID token names a different Google account than the connected one,
   the new grant is revoked and nothing changes.
6. If YouTube later answers a write with HTTP 403 `insufficientPermissions`
   (scope no longer honoured), NOIR reverts the heart and offers the same
   upgrade again.

Disconnecting revokes the combined grant, so a later reconnect starts
read-only again.

## Android

Credential Manager for sign-in, then `AuthorizationClient.authorize()` for the
YouTube scope. It returns a short-lived access token on the device; NOIR does
not request offline access and stores no refresh token (Google discourages
refresh tokens on device). When the token expires NOIR calls `authorize()`
again.

## iOS

GoogleSignIn SDK with an iOS client ID; `addScopes` for YouTube scopes.

## Disconnect

1. `POST https://oauth2.googleapis.com/revoke?token=<refresh or access>`.
2. Delete tokens from secure storage.
3. Delete every cached YouTube-derived row immediately (policy allows 7 days).
4. Link to https://myaccount.google.com/permissions for revocation outside NOIR.

## Configuration

```
flutter run -d windows --dart-define=NOIR_GOOGLE_DESKTOP_CLIENT_ID=<id>
```

Read in `lib/integrations/google_auth/google_oauth_config.dart`. Without it,
`UnconfiguredAccountService` reports "not available" and no sign-in UI is
offered.

## Before release

- OAuth consent screen with privacy policy URL and verified domain.
- Sensitive-scope verification for `youtube.readonly` (expect a demo video).
- Add `https://www.googleapis.com/auth/youtube` to the consent screen's Data
  Access list (also needed in testing mode for test users to be offered it);
  it is a sensitive scope and joins the same verification.
- Testing mode limits: 100 test users, authorizations expire after 7 days.
