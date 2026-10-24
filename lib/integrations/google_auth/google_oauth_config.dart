/// Public OAuth client configuration, injected at build time:
///
///   flutter run --dart-define=NOIR_GOOGLE_DESKTOP_CLIENT_ID=...
///
/// Client IDs are public identifiers, not secrets. No client secret or token
/// is ever compiled into NOIR or committed to the repository. See
/// docs/oauth-flow.md.
class GoogleOAuthConfig {
  const GoogleOAuthConfig({this.desktopClientId, this.androidServerClientId});

  factory GoogleOAuthConfig.fromEnvironment() {
    const desktop = String.fromEnvironment('NOIR_GOOGLE_DESKTOP_CLIENT_ID');
    const android = String.fromEnvironment('NOIR_GOOGLE_ANDROID_CLIENT_ID');
    return GoogleOAuthConfig(
      desktopClientId: desktop.isEmpty ? null : desktop,
      androidServerClientId: android.isEmpty ? null : android,
    );
  }

  final String? desktopClientId;
  final String? androidServerClientId;

  /// Minimum scope for every read-only feature in the capability matrix.
  static const readOnlyScopes = [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/youtube.readonly',
  ];

  /// Requested incrementally, only when the user first edits a playlist.
  static const playlistWriteScope =
      'https://www.googleapis.com/auth/youtube.force-ssl';
}
