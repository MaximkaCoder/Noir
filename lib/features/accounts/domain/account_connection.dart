import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as tabs;
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

  /// Whether NOIR may add and remove items in the user's playlists.
  bool get canSaveToPlaylists =>
      isConnected && GoogleOAuthConfig.grantsWrite(grantedScopes);
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

  /// Incremental authorization: asks Google, in the browser, for permission
  /// to edit the user's playlists on top of what was already granted.
  /// Completes once granted; throws [OAuthWriteDeclined] when the user says
  /// no (read-only access stays as it was) or another [OAuthException].
  Future<void> requestWriteAccess();
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

  @override
  Future<void> requestWriteAccess() =>
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

  /// Bumped on disconnect, so a refresh or upgrade still in flight then
  /// does not bring the account back.
  int _session = 0;
  Future<String>? _refreshing;
  Future<void>? _upgrading;

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
        subject: identity.subject,
        email: identity.email,
        name: identity.name,
      );
      final replaced = await _store.read();
      await _store.write(account);
      // Reconnecting replaces the old grant; don't leave it valid at Google.
      if (replaced != null && replaced.refreshToken != refreshToken) {
        await _flow.revoke(replaced.refreshToken);
      }
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
  Future<void> requestWriteAccess() =>
      _upgrading ??= _upgrade().whenComplete(() => _upgrading = null);

  Future<void> _upgrade() async {
    final session = _session;
    final account = await _store.read();
    if (account == null || _state.status != AccountStatus.connected) {
      throw const OAuthReauthRequired();
    }
    // Runs even when the scope is on record: YouTube answering 403
    // insufficientPermissions means Google no longer honours it.
    final OAuthTokens tokens;
    try {
      // Only the new scope needs consent; include_granted_scopes keeps the
      // rest. The read-only set is repeated so the ID token still comes back.
      tokens = await _flow.authorize([
        ...scopes,
        GoogleOAuthConfig.playlistWriteScope,
      ], loginHint: account.email);
    } on OAuthDenied {
      throw const OAuthWriteDeclined();
    }
    // Granular consent lets people untick the new box.
    if (!GoogleOAuthConfig.grantsWrite(tokens.scopes)) {
      throw const OAuthWriteDeclined();
    }
    if (session != _session) {
      // Disconnected meanwhile.
      await _flow.revoke(tokens.refreshToken ?? tokens.accessToken);
      throw const OAuthCancelled();
    }
    final identity = tokens.identity;
    // Accounts saved before the id was kept fall back to the email. Without
    // either to compare, it can't be shown to be the same account.
    final sameAccount = account.subject != null && identity.subject != null
        ? identity.subject == account.subject
        : identity.email != null && identity.email == account.email;
    if (!sameAccount) {
      // A grant for some other account: give it back, keep the current one.
      await _flow.revoke(tokens.refreshToken ?? tokens.accessToken);
      throw OAuthFailed(
        'That was a different Google account. Choose ${account.email}.',
      );
    }
    final upgraded = StoredAccount(
      // The new refresh token carries the combined grant.
      refreshToken: tokens.refreshToken ?? account.refreshToken,
      scopes: tokens.scopes,
      connectedAt: account.connectedAt,
      subject: account.subject ?? identity.subject,
      email: account.email ?? identity.email,
      name: account.name ?? identity.name,
    );
    await _store.write(upgraded);
    _access = tokens;
    _emit(_connected(upgraded));
  }

  @override
  Future<void> disconnect() async {
    _session++;
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
    final session = _session;
    final account = await _store.read();
    if (account == null) throw const OAuthReauthRequired();
    final OAuthTokens tokens;
    try {
      tokens = await _flow.refresh(account.refreshToken);
    } on OAuthReauthRequired {
      // Disconnected meanwhile: the account is gone, not expired.
      if (session != _session) rethrow;
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
    if (session != _session) throw const OAuthReauthRequired();
    _access = tokens;
    return tokens.accessToken;
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
      launch: Platform.isAndroid ? _openSheet : _openBrowser,
      untilForeground: Platform.isAndroid ? _backToApp : null,
    ),
    store: ref.watch(tokenStoreProvider),
  );
  unawaited(service.init());
  return service;
});

Future<bool> _openBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Android: sign-in in a sheet over the app. With the browser in front the
/// app would be frozen, its redirect server unanswered; under a sheet it
/// stays visible, and so running.
Future<bool> _openSheet(Uri url) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  try {
    await tabs.launchUrl(
      url,
      customTabsOptions: tabs.CustomTabsOptions.partial(
        configuration: tabs.PartialCustomTabsConfiguration.bottomSheet(
          initialHeight: view.physicalSize.height / view.devicePixelRatio * .9,
        ),
        showTitle: true,
      ),
    );
    return true;
  } on Object {
    // No browser with Custom Tabs: the full browser, as on desktop.
    return await _openBrowser(url);
  }
}

/// Closes the sign-in sheet and waits until the app is in front.
Future<void> _backToApp() async {
  try {
    await tabs.closeCustomTabs();
  } on Object {
    // Opened in the full browser; the user comes back on their own.
  }
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    return;
  }
  final resumed = Completer<void>();
  final listener = AppLifecycleListener(onResume: resumed.complete);
  try {
    await resumed.future;
  } finally {
    listener.dispose();
  }
}

final accountConnectionProvider = StreamProvider<AccountConnection>(
  (ref) => ref.watch(accountServiceProvider).watch(),
);
