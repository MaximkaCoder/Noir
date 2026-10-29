import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/google_auth/google_oauth_config.dart';
import 'package:noir/integrations/google_auth/token_store.dart';

import '../helpers/fake_http.dart';

const _config = GoogleOAuthConfig(
  desktopClientId: 'client-id.apps.googleusercontent.com',
  desktopClientSecret: 'test-secret',
);

/// Plays the browser: hits the loopback redirect like Google would.
UrlLauncher browser({
  String? code = 'auth-code',
  String? error,
  bool tamperState = false,
  List<Uri>? opened,
}) => (url) async {
  opened?.add(url);
  final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
  final state = url.queryParameters['state']!;
  unawaited(() async {
    final client = HttpClient();
    if (tamperState) {
      // A forged request first; it must be ignored.
      final forged = await client.getUrl(
        redirect.replace(queryParameters: {'code': 'evil', 'state': 'x'}),
      );
      await (await forged.close()).drain<void>();
    }
    final req = await client.getUrl(
      redirect.replace(
        queryParameters: {'state': state, 'code': ?code, 'error': ?error},
      ),
    );
    await (await req.close()).drain<void>();
    client.close();
  }());
  return true;
};

Map<String, Object?> tokenJson({
  String scope = 'openid ${GoogleOAuthConfig.youtubeReadOnlyScope}',
  bool refresh = true,
}) => {
  'access_token': 'access-1',
  'expires_in': 3599,
  if (refresh) 'refresh_token': 'refresh-1',
  'scope': scope,
  'id_token': fakeIdToken({'email': 'me@example.com', 'name': 'Max'}),
};

void main() {
  group('DesktopOAuthFlow', () {
    test('loopback + PKCE: exchanges the code with the verifier', () async {
      final http = FakeHttp((_) => ok(tokenJson()));
      final opened = <Uri>[];
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: http.dio(),
        launch: browser(opened: opened),
      );

      final tokens = await flow.authorize(GoogleOAuthConfig.readOnlyScopes);

      final url = opened.single;
      expect(url.host, 'accounts.google.com');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['access_type'], 'offline');
      expect(Uri.parse(url.queryParameters['redirect_uri']!).host, '127.0.0.1');
      final form = http.requests.single.form;
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'auth-code');
      expect(form['code_verifier'], hasLength(64));
      expect(form['client_secret'], 'test-secret');
      expect(tokens.refreshToken, 'refresh-1');
      expect(tokens.identity.email, 'me@example.com');
    });

    test('exchanges the code only once the app is in front', () async {
      final http = FakeHttp((_) => ok(tokenJson()));
      final front = Completer<void>();
      var asked = false;
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: http.dio(),
        launch: browser(),
        untilForeground: () {
          asked = true;
          return front.future;
        },
      );
      final tokens = flow.authorize(GoogleOAuthConfig.readOnlyScopes);
      while (!asked) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(http.requests, isEmpty);

      front.complete();
      expect((await tokens).refreshToken, 'refresh-1');
      expect(http.requests.single.form['code'], 'auth-code');
    });

    test('ignores a callback with a forged state', () async {
      final http = FakeHttp((_) => ok(tokenJson()));
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: http.dio(),
        launch: browser(tamperState: true),
      );
      await flow.authorize(GoogleOAuthConfig.readOnlyScopes);
      expect(http.requests.single.form['code'], 'auth-code');
    });

    test('access_denied becomes OAuthDenied', () async {
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: FakeHttp((_) => ok(tokenJson())).dio(),
        launch: browser(code: null, error: 'access_denied'),
      );
      expect(
        flow.authorize(GoogleOAuthConfig.readOnlyScopes),
        throwsA(isA<OAuthDenied>()),
      );
    });

    test('cancel aborts while waiting for the browser', () async {
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: FakeHttp((_) => ok(tokenJson())).dio(),
        launch: (_) async => true, // The user never finishes.
      );
      final pending = flow.authorize(GoogleOAuthConfig.readOnlyScopes);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      flow.cancel();
      await expectLater(pending, throwsA(isA<OAuthCancelled>()));
    });

    test('invalid_grant on refresh means reconnect', () async {
      final flow = DesktopOAuthFlow(
        config: _config,
        dio: FakeHttp((_) => error(400, {'error': 'invalid_grant'})).dio(),
        launch: browser(),
      );
      expect(flow.refresh('old'), throwsA(isA<OAuthReauthRequired>()));
    });
  });

  group('GoogleAccountService', () {
    late FakeHttp http;
    late MemoryTokenStore store;
    late GoogleAccountService service;

    GoogleAccountService build({UrlLauncher? launch}) => GoogleAccountService(
      flow: DesktopOAuthFlow(
        config: _config,
        dio: http.dio(),
        launch: launch ?? browser(),
      ),
      store: store,
    );

    setUp(() {
      store = MemoryTokenStore();
      http = FakeHttp((_) => ok(tokenJson()));
      service = build();
    });

    test(
      'connect stores only the refresh token and reports identity',
      () async {
        await service.connect();
        expect(service.current.status, AccountStatus.connected);
        expect(service.current.email, 'me@example.com');
        expect(store.account!.refreshToken, 'refresh-1');
        expect(
          jsonEncode(store.account!.toJson()),
          isNot(contains('access-1')),
        );
        expect(await service.accessToken(), 'access-1');
      },
    );

    test('rejects a grant without the YouTube scope', () async {
      http.handler = (_) => ok(tokenJson(scope: 'openid email'));
      await service.connect();
      expect(service.current.status, AccountStatus.disconnected);
      expect(service.current.message, contains('YouTube'));
      expect(store.account, isNull);
    });

    test('restores a saved session and refreshes on demand', () async {
      store.account = StoredAccount(
        refreshToken: 'refresh-1',
        scopes: const [GoogleOAuthConfig.youtubeReadOnlyScope],
        connectedAt: DateTime(2026),
        email: 'me@example.com',
      );
      await service.init();
      expect(service.current.status, AccountStatus.connected);

      http.handler = (_) => ok(tokenJson(refresh: false));
      final results = await Future.wait([
        service.accessToken(),
        service.accessToken(),
      ]);
      expect(results, ['access-1', 'access-1']);
      expect(http.requests, hasLength(1), reason: 'one shared refresh');
      expect(http.requests.single.form['grant_type'], 'refresh_token');
    });

    test('expired session switches to needsReconnect', () async {
      await service.connect();
      http.handler = (_) => error(400, {'error': 'invalid_grant'});
      await expectLater(
        service.accessToken(forceRefresh: true),
        throwsA(isA<OAuthReauthRequired>()),
      );
      expect(service.current.status, AccountStatus.needsReconnect);
    });

    group('incremental write access', () {
      List<String> scopesOf(Uri url) =>
          url.queryParameters['scope']!.split(' ');

      const writeGrant =
          'openid email profile ${GoogleOAuthConfig.youtubeReadOnlyScope} '
          '${GoogleOAuthConfig.playlistWriteScope}';

      test(
        'sign-in asks for read-only scopes, never the write scope',
        () async {
          final opened = <Uri>[];
          service = build(launch: browser(opened: opened));
          await service.connect();
          expect(
            scopesOf(opened.single),
            isNot(contains(GoogleOAuthConfig.playlistWriteScope)),
          );
          expect(scopesOf(opened.single), GoogleOAuthConfig.readOnlyScopes);
          expect(service.current.canSaveToPlaylists, isFalse);
        },
      );

      test('upgrade adds the write scope with include_granted_scopes and '
          'keeps the new refresh token', () async {
        final opened = <Uri>[];
        service = build(launch: browser(opened: opened));
        await service.connect();
        http.handler = (_) =>
            ok({...tokenJson(scope: writeGrant), 'refresh_token': 'refresh-2'});

        await service.requestWriteAccess();

        final url = opened.last;
        expect(opened, hasLength(2));
        expect(url.queryParameters['include_granted_scopes'], 'true');
        expect(url.queryParameters['login_hint'], 'me@example.com');
        expect(scopesOf(url), contains(GoogleOAuthConfig.playlistWriteScope));
        expect(store.account!.refreshToken, 'refresh-2');
        expect(
          store.account!.scopes,
          contains(GoogleOAuthConfig.playlistWriteScope),
        );
        expect(service.current.status, AccountStatus.connected);
        expect(service.current.canSaveToPlaylists, isTrue);
      });

      test('declining keeps read-only access untouched', () async {
        await service.connect();
        service = build(launch: browser(code: null, error: 'access_denied'));
        await service.init();

        await expectLater(
          service.requestWriteAccess(),
          throwsA(isA<OAuthWriteDeclined>()),
        );
        expect(store.account!.refreshToken, 'refresh-1');
        expect(service.current.status, AccountStatus.connected);
        expect(service.current.canSaveToPlaylists, isFalse);
      });

      test('an unticked write box counts as declined', () async {
        await service.connect();
        http.handler = (_) =>
            ok({...tokenJson(), 'refresh_token': 'refresh-2'});
        await expectLater(
          service.requestWriteAccess(),
          throwsA(isA<OAuthWriteDeclined>()),
        );
        expect(store.account!.refreshToken, 'refresh-1');
      });

      test('the same email on another account id is rejected', () async {
        http.handler = (_) => ok({
          ...tokenJson(),
          'id_token': fakeIdToken({'sub': '111', 'email': 'me@example.com'}),
        });
        await service.connect();
        expect(store.account!.subject, '111');
        http.handler = (r) => r.uri.path.endsWith('revoke')
            ? ok({})
            : ok({
                ...tokenJson(scope: writeGrant),
                'refresh_token': 'other-refresh',
                'id_token': fakeIdToken({
                  'sub': '222',
                  'email': 'me@example.com',
                }),
              });
        await expectLater(
          service.requestWriteAccess(),
          throwsA(isA<OAuthFailed>()),
        );
        expect(http.requests.last.form['token'], 'other-refresh');
        expect(store.account!.refreshToken, 'refresh-1');
      });

      test('a grant that names no account is rejected', () async {
        await service.connect();
        http.handler = (r) => r.uri.path.endsWith('revoke')
            ? ok({})
            : ok({
                ...tokenJson(scope: writeGrant),
                'refresh_token': 'other-refresh',
                'id_token': fakeIdToken({}),
              });
        await expectLater(
          service.requestWriteAccess(),
          throwsA(isA<OAuthFailed>()),
        );
        expect(http.requests.last.form['token'], 'other-refresh');
        expect(store.account!.refreshToken, 'refresh-1');
      });

      test('a different Google account is rejected and revoked', () async {
        await service.connect();
        http.handler = (r) => r.uri.path.endsWith('revoke')
            ? ok({})
            : ok({
                ...tokenJson(scope: writeGrant),
                'refresh_token': 'other-refresh',
                'id_token': fakeIdToken({'email': 'someone@example.com'}),
              });
        await expectLater(
          service.requestWriteAccess(),
          throwsA(isA<OAuthFailed>()),
        );
        expect(http.requests.last.form['token'], 'other-refresh');
        expect(store.account!.refreshToken, 'refresh-1');
        expect(service.current.canSaveToPlaylists, isFalse);
      });
    });

    test('a refresh still running at disconnect does not reconnect', () async {
      await service.connect();
      final release = Completer<void>();
      Future<void>? holdRefresh(FakeRequest r) =>
          r.form['grant_type'] == 'refresh_token' ? release.future : null;
      http
        ..hold = holdRefresh
        ..handler = (_) => ok(tokenJson(refresh: false));
      final pending = service.accessToken(forceRefresh: true);
      await pumpEventQueue();
      await service.disconnect();
      release.complete();

      await expectLater(pending, throwsA(isA<OAuthReauthRequired>()));
      expect(service.current.status, AccountStatus.disconnected);
      expect(store.account, isNull);
      await expectLater(
        service.accessToken(),
        throwsA(isA<OAuthReauthRequired>()),
      );
    });

    test('reconnecting revokes the grant it replaces', () async {
      await service.connect();
      http.handler = (r) => r.uri.path.endsWith('revoke')
          ? ok({})
          : ok({...tokenJson(), 'refresh_token': 'refresh-2'});
      await service.connect();
      expect(store.account!.refreshToken, 'refresh-2');
      expect(http.requests.last.form['token'], 'refresh-1');
    });

    test('disconnect revokes at Google and forgets credentials', () async {
      await service.connect();
      await service.disconnect();
      expect(
        http.requests.last.uri.toString(),
        GoogleOAuthConfig.revokeEndpoint.toString(),
      );
      expect(http.requests.last.form['token'], 'refresh-1');
      expect(store.account, isNull);
      expect(service.current.status, AccountStatus.disconnected);
    });
  });
}
