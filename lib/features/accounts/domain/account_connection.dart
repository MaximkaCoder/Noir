import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/google_auth/google_oauth_config.dart';
import 'package:noir/integrations/google_auth/token_store.dart';
import 'package:url_launcher/url_launcher.dart';

enum AccountStatus {
  /// This build has no OAuth client configured; connecting is impossible.
  notConfigured,
  disconnected,
  connecting,
  connected,

  /// The session ended (expired or revoked); the user must reconnect.
  needsReconnect,
}

class AccountConnection {
  const AccountConnection({
    required this.status,
    this.email,
    this.displayName,
    this.grantedScopes = const [],
    this.connectedAt,
    this.message,
  });

  final AccountStatus status;
  final String? email;
  final String? displayName;
  final List<String> grantedScopes;
  final DateTime? connectedAt;

  /// User-facing note about the last attempt (e.g. "Access was not granted").
  final String? message;

  bool get isConnected => status == AccountStatus.connected;
}

/// Connects and disconnects the user's Google account. Implementations use
/// the system browser, never an embedded WebView, and clear local tokens on
/// [disconnect].
abstract interface class AccountConnectionService {
  AccountConnection get current;
  Stream<AccountConnection> watch();
  Future<void> connect();
  void cancelConnect();
  Future<void> disconnect();

  /// A valid access token, refreshed when needed. Throws [OAuthException].
  Future<String> accessToken({bool forceRefresh = false});
}

/// Used when no OAuth client is configured. Reports the truth instead of
/// pretending a connection is possible.
class UnconfiguredAccountService implements AccountConnectionService {
  const UnconfiguredAccountService();

  static const _state = AccountConnection(status: AccountStatus.notConfigured);

  @override
  AccountConnection get current => _state;

  @override
  Stream<AccountConnection> watch() => Stream.value(_state);

  @override
  Future<void> connect() =>
      Future.error(const OAuthFailed('Google sign-in is not configured.'));

  @override
  void cancelConnect() {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<String> accessToken({bool forceRefresh = false}) =>
      Future.error(const OAuthFailed('Google sign-in is not configured.'));
}

class GoogleAccountService implements AccountConnectionService {
  GoogleAccountService({
    required this._flow,
    required this._store,
    this.scopes = GoogleOAuthConfig.readOnlyScopes,
  });

  final DesktopOAuthFlow _flow;
  final TokenStore _store;
  final List<String> scopes;

  final _changes = StreamController<AccountConnection>.broadcast();
  AccountConnection _state = const AccountConnection(
    status: AccountStatus.disconnected,
  );
  OAuthTokens? _access;
  Future<String>? _refreshing;

  /// Restores a previous connection from secure storage.
  Future<void> init() async {
    final account = await _store.read();
    if (account != null) _emit(_connected(account));
  }

  @override
  AccountConnection get current => _state;

  @override
  Stream<AccountConnection> watch() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<void> connect() async {
    if (_state.status == AccountStatus.connecting) return;
    final previous = _state;
    _emit(const AccountConnection(status: AccountStatus.connecting));
    try {
      final tokens = await _flow.authorize(scopes);
      if (!tokens.scopes.contains(GoogleOAuthConfig.youtubeReadOnlyScope)) {
        // Google's consent screen lets people untick individual scopes.
        throw const OAuthFailed(
          'NOIR needs permission to view your YouTube account. Connect again '
          'and keep the YouTube box ticked.',
        );
      }
      final refreshToken = tokens.refreshToken;
      if (refreshToken == null) {
        throw const OAuthFailed('Google did not return a long-lived session.');
      }
      final identity = tokens.identity;
      final account = StoredAccount(
        refreshToken: refreshToken,
        scopes: tokens.scopes,
        connectedAt: DateTime.now(),
        email: identity.email,
        name: identity.name,
      );
      await _store.write(account);
      _access = tokens;
      _emit(_connected(account));
    } on OAuthException catch (e) {
      _emit(
        AccountConnection(
          status: previous.status == AccountStatus.connected
              ? AccountStatus.connected
              : previous.status == AccountStatus.needsReconnect
              ? AccountStatus.needsReconnect
              : AccountStatus.disconnected,
          email: previous.email,
          displayName: previous.displayName,
          grantedScopes: previous.grantedScopes,
          connectedAt: previous.connectedAt,
          message: e is OAuthCancelled ? null : e.message,
        ),
      );
    }
  }

  @override
  void cancelConnect() => _flow.cancel();

  @override
  Future<void> disconnect() async {
    final account = await _store.read();
    if (account != null) await _flow.revoke(account.refreshToken);
    await _store.delete();
    _access = null;
    _emit(const AccountConnection(status: AccountStatus.disconnected));
  }

  @override
  Future<String> accessToken({bool forceRefresh = false}) {
    final access = _access;
    if (!forceRefresh &&
        access != null &&
        access.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 1)),
        )) {
      return Future.value(access.accessToken);
    }
    // Concurrent callers share one refresh.
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    final account = await _store.read();
    if (account == null) throw const OAuthReauthRequired();
    try {
      final tokens = await _flow.refresh(account.refreshToken);
      _access = tokens;
      return tokens.accessToken;
    } on OAuthReauthRequired {
      _access = null;
      _emit(
        AccountConnection(
          status: AccountStatus.needsReconnect,
          email: account.email,
          displayName: account.name,
          message: const OAuthReauthRequired().message,
        ),
      );
      rethrow;
    }
  }

  AccountConnection _connected(StoredAccount a) => AccountConnection(
    status: AccountStatus.connected,
    email: a.email,
    displayName: a.name,
    grantedScopes: a.scopes,
    connectedAt: a.connectedAt,
  );

  void _emit(AccountConnection state) {
    _state = state;
    _changes.add(state);
  }
}

final googleOAuthConfigProvider = Provider<GoogleOAuthConfig>(
  (ref) => GoogleOAuthConfig.fromEnvironment(),
);

final httpClientProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => const SecureTokenStore(),
);

final accountServiceProvider = Provider<AccountConnectionService>((ref) {
  final config = ref.watch(googleOAuthConfigProvider);
  if (!config.isConfigured) return const UnconfiguredAccountService();
  final service = GoogleAccountService(
    flow: DesktopOAuthFlow(
      config: config,
      dio: ref.watch(httpClientProvider),
      launch: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
    ),
    store: ref.watch(tokenStoreProvider),
  );
  unawaited(service.init());
  return service;
});

final accountConnectionProvider = StreamProvider<AccountConnection>(
  (ref) => ref.watch(accountServiceProvider).watch(),
);
