/// Public OAuth client configuration, injected at build time from a
/// gitignored file:
///
///   flutter run -d windows --dart-define-from-file=config/oauth.local.json
///
/// Google documents desktop apps as public clients whose secret "is obviously
/// not treated as a secret"; it still never goes into the repository. See
/// docs/oauth-flow.md.
class GoogleOAuthConfig {
  const GoogleOAuthConfig({this.desktopClientId, this.desktopClientSecret});

  factory GoogleOAuthConfig.fromEnvironment() {
    const id = String.fromEnvironment('NOIR_GOOGLE_DESKTOP_CLIENT_ID');
    const secret = String.fromEnvironment('NOIR_GOOGLE_DESKTOP_CLIENT_SECRET');
    return GoogleOAuthConfig(
      desktopClientId: id.isEmpty ? null : id,
      desktopClientSecret: secret.isEmpty ? null : secret,
    );
  }

  final String? desktopClientId;
  final String? desktopClientSecret;

  bool get isConfigured => desktopClientId != null;

  static const youtubeReadOnlyScope =
      'https://www.googleapis.com/auth/youtube.readonly';

  /// Minimum scope set for every read-only feature in the capability matrix.
  static const readOnlyScopes = [
    'openid',
    'email',
    'profile',
    youtubeReadOnlyScope,
  ];

  /// Requested incrementally, only when the user first edits a playlist.
  static const playlistWriteScope =
      'https://www.googleapis.com/auth/youtube.force-ssl';

  static final authorizationEndpoint = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  static final tokenEndpoint = Uri.parse('https://oauth2.googleapis.com/token');
  static final revokeEndpoint = Uri.parse(
    'https://oauth2.googleapis.com/revoke',
  );
}
