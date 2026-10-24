import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:noir/integrations/google_auth/google_oauth_config.dart';

/// Tokens returned by Google's token endpoint. Never logged.
class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.expiresAt,
    required this.scopes,
    this.refreshToken,
    this.idToken,
  });

  factory OAuthTokens.fromJson(Map<String, Object?> json, DateTime now) =>
      OAuthTokens(
        accessToken: json['access_token']! as String,
        expiresAt: now.add(
          Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
        ),
        refreshToken: json['refresh_token'] as String?,
        idToken: json['id_token'] as String?,
        scopes: ((json['scope'] as String?) ?? '')
            .split(' ')
            .where((s) => s.isNotEmpty)
            .toList(),
      );

  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;
  final String? idToken;
  final List<String> scopes;

  /// Name and email from the ID token. The token came straight from Google
  /// over TLS, so its payload is only decoded for display, not trusted for
  /// authorization decisions.
  ({String? email, String? name}) get identity {
    final parts = idToken?.split('.');
    if (parts == null || parts.length != 3) return (email: null, name: null);
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, Object?>;
      return (
        email: payload['email'] as String?,
        name: payload['name'] as String?,
      );
    } on Object {
      return (email: null, name: null);
    }
  }
}

sealed class OAuthException implements Exception {
  const OAuthException(this.message);

  /// User-facing explanation.
  final String message;

  @override
  String toString() => 'OAuthException: $message';
}

final class OAuthCancelled extends OAuthException {
  const OAuthCancelled() : super('Sign-in was cancelled.');
}

final class OAuthDenied extends OAuthException {
  const OAuthDenied()
    : super('Access was not granted. You can try again at any time.');
}

/// The refresh token is no longer valid (expired, revoked, or the 7-day limit
/// of Google's testing mode). The user must connect again.
final class OAuthReauthRequired extends OAuthException {
  const OAuthReauthRequired()
    : super('Your Google session has ended. Connect your account again.');
}

/// The user did not grant the playlist write scope during an incremental
/// authorization. Read-only access is unchanged.
final class OAuthWriteDeclined extends OAuthException {
  const OAuthWriteDeclined()
    : super(
        "NOIR can't save songs to your playlists without that permission. "
        'Everything else keeps working.',
      );
}

final class OAuthFailed extends OAuthException {
  const OAuthFailed(super.message);
}

/// Opens [url] in the user's default browser.
typedef UrlLauncher = Future<bool> Function(Uri url);

/// OAuth 2.0 for installed desktop apps: system browser, loopback redirect on
/// 127.0.0.1 with a random port, PKCE (S256) and a `state` check.
/// https://developers.google.com/identity/protocols/oauth2/native-app
class DesktopOAuthFlow {
  DesktopOAuthFlow({
    required this._config,
    required this._dio,
    required this._launch,
    this.timeout = const Duration(minutes: 5),
    Random? random,
  }) : _random = random ?? Random.secure();

  final GoogleOAuthConfig _config;
  final Dio _dio;
  final UrlLauncher _launch;
  final Random _random;
  final Duration timeout;

  Completer<Uri>? _callback;

  /// Runs the browser consent flow and exchanges the code for tokens.
  ///
  /// Always sends `include_granted_scopes=true`, so asking for one more
  /// scope later (incremental authorization) returns tokens covering
  /// everything granted so far. [loginHint] preselects the connected account.
  Future<OAuthTokens> authorize(
    List<String> scopes, {
    String? loginHint,
  }) async {
    final clientId = _config.desktopClientId;
    if (clientId == null) {
      throw const OAuthFailed('Google sign-in is not configured.');
    }
    final verifier = _randomString(64);
    final state = _randomString(32);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final callback = _callback = Completer<Uri>();
    server.listen((request) => _handle(request, state, callback));

    try {
      final url = GoogleOAuthConfig.authorizationEndpoint.replace(
        queryParameters: {
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'response_type': 'code',
          'scope': scopes.join(' '),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          'access_type': 'offline',
          // Always return a refresh token, also on re-consent.
          'prompt': 'consent',
          'include_granted_scopes': 'true',
          'login_hint': ?loginHint,
        },
      );
      if (!await _launch(url)) {
        throw const OAuthFailed("Couldn't open your web browser.");
      }
      final result = await callback.future.timeout(
        timeout,
        onTimeout: () => throw const OAuthCancelled(),
      );
      final error = result.queryParameters['error'];
      if (error == 'access_denied') throw const OAuthDenied();
      if (error != null) {
        throw const OAuthFailed('Google reported a sign-in error.');
      }
      final code = result.queryParameters['code'];
      if (code == null) throw const OAuthFailed('No authorization code.');
      return await _token({
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
      });
    } finally {
      _callback = null;
      await server.close(force: true);
    }
  }

  /// Aborts a running [authorize].
  void cancel() {
    final callback = _callback;
    if (callback != null && !callback.isCompleted) {
      callback.completeError(const OAuthCancelled());
    }
  }

  Future<OAuthTokens> refresh(String refreshToken) =>
      _token({'grant_type': 'refresh_token', 'refresh_token': refreshToken});

  /// Revokes the grant at Google. Best effort: local data is cleared anyway.
  Future<void> revoke(String token) async {
    try {
      await _dio.postUri<void>(
        GoogleOAuthConfig.revokeEndpoint,
        data: {'token': token},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException {
      // Already revoked or offline; nothing else to do.
    }
  }

  Future<void> _handle(
    HttpRequest request,
    String expectedState,
    Completer<Uri> callback,
  ) async {
    final uri = request.uri;
    final isCallback =
        uri.path == '/' &&
        (uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('error'));
    if (!isCallback) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    // A mismatched state means the request did not come from our flow.
    final valid = uri.queryParameters['state'] == expectedState;
    request.response
      ..statusCode = valid ? HttpStatus.ok : HttpStatus.badRequest
      ..headers.contentType = ContentType.html
      ..write(_page(valid && !uri.queryParameters.containsKey('error')));
    await request.response.close();
    if (valid && !callback.isCompleted) callback.complete(uri);
  }

  Future<OAuthTokens> _token(Map<String, String> params) async {
    final clientId = _config.desktopClientId!;
    try {
      final response = await _dio.postUri<Map<String, Object?>>(
        GoogleOAuthConfig.tokenEndpoint,
        data: {
          'client_id': clientId,
          if (_config.desktopClientSecret != null)
            'client_secret': _config.desktopClientSecret!,
          ...params,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return OAuthTokens.fromJson(response.data!, DateTime.now());
    } on DioException catch (e) {
      final data = e.response?.data;
      final error = data is Map ? data['error'] : null;
      if (error == 'invalid_grant') throw const OAuthReauthRequired();
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout) {
        throw const OAuthFailed(
          "Couldn't reach Google. Check your internet connection.",
        );
      }
      throw const OAuthFailed('Google refused the sign-in request.');
    }
  }

  String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  static String _page(bool ok) =>
      '''
<!doctype html><html><head><meta charset="utf-8"><title>NOIR</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;
background:#090909;color:#f2f2f0;font:16px system-ui,sans-serif}
p{color:#a3a3a3}</style></head><body><div>
<h1>${ok ? 'Connected' : 'Not connected'}</h1>
<p>${ok ? 'You can close this tab and return to NOIR.' : 'Return to NOIR and try again.'}</p>
</div></body></html>''';
}
