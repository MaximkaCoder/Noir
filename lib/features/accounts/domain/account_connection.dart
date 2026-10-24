import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    this.lastSync,
  });

  final AccountStatus status;
  final String? email;
  final String? displayName;
  final List<String> grantedScopes;
  final DateTime? lastSync;
}

/// Connects and disconnects the user's Google account. Implementations must
/// use the system browser / platform SDK, never an embedded WebView, and must
/// clear local tokens and account-derived cache on [disconnect].
abstract interface class AccountConnectionService {
  Stream<AccountConnection> watch();
  Future<void> connect();
  Future<void> disconnect();
}

/// Used when no OAuth client is configured (the default in this version).
/// Reports the truth instead of pretending a connection is possible.
class UnconfiguredAccountService implements AccountConnectionService {
  const UnconfiguredAccountService();

  @override
  Stream<AccountConnection> watch() => Stream.value(
    const AccountConnection(status: AccountStatus.notConfigured),
  );

  @override
  Future<void> connect() =>
      Future.error(UnsupportedError('Google sign-in is not configured.'));

  @override
  Future<void> disconnect() async {}
}

final accountServiceProvider = Provider<AccountConnectionService>(
  // Phase 5 swaps in the real Google implementation when
  // GoogleOAuthConfig.fromEnvironment() provides client IDs.
  (ref) => const UnconfiguredAccountService(),
);

final accountConnectionProvider = StreamProvider<AccountConnection>(
  (ref) => ref.watch(accountServiceProvider).watch(),
);
