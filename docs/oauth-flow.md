# Google OAuth (planned for Phase 5)

Nothing in this version contacts Google. This document fixes the design so
Phase 5 can be implemented and reviewed against it. Sources: see
[youtube-capability-matrix.md](youtube-capability-matrix.md).

## Principles

- NOIR never sees the user's Google password: consent happens in the system
  browser (desktop) or the platform SDK (mobile). Embedded WebViews are
  forbidden by Google for OAuth.
- Minimum scopes: `openid email profile youtube.readonly`. The write scope
  `youtube.force-ssl` is requested incrementally the first time the user edits
  a YouTube playlist.
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
- Testing mode limits: 100 test users, authorizations expire after 7 days.
