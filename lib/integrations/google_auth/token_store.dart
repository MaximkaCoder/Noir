import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What NOIR keeps about a connected Google account. The refresh token is the
/// only credential; the access token lives in memory only.
class StoredAccount {
  const StoredAccount({
    required this.refreshToken,
    required this.scopes,
    required this.connectedAt,
    this.email,
    this.name,
  });

  factory StoredAccount.fromJson(Map<String, Object?> json) => StoredAccount(
    refreshToken: json['refreshToken']! as String,
    scopes: (json['scopes']! as List<Object?>).cast<String>(),
    connectedAt: DateTime.parse(json['connectedAt']! as String),
    email: json['email'] as String?,
    name: json['name'] as String?,
  );

  final String refreshToken;
  final List<String> scopes;
  final DateTime connectedAt;
  final String? email;
  final String? name;

  Map<String, Object?> toJson() => {
    'refreshToken': refreshToken,
    'scopes': scopes,
    'connectedAt': connectedAt.toIso8601String(),
    'email': email,
    'name': name,
  };
}

abstract interface class TokenStore {
  Future<StoredAccount?> read();
  Future<void> write(StoredAccount account);
  Future<void> delete();
}

/// Windows Credential Manager / Keychain / Android Keystore via
/// flutter_secure_storage.
class SecureTokenStore implements TokenStore {
  const SecureTokenStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static const _key = 'noir.google.account';

  @override
  Future<StoredAccount?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return StoredAccount.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      await delete(); // Unreadable credentials are useless; start over.
      return null;
    }
  }

  @override
  Future<void> write(StoredAccount account) =>
      _storage.write(key: _key, value: jsonEncode(account.toJson()));

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MemoryTokenStore implements TokenStore {
  StoredAccount? account;

  @override
  Future<StoredAccount?> read() async => account;

  @override
  Future<void> write(StoredAccount value) async => account = value;

  @override
  Future<void> delete() async => account = null;
}
