import 'package:oidc/oidc.dart';

import 'token_store.dart';

/// Adapts a [TokenStore] to the oidc package's [OidcStore] interface.
///
/// Everything the manager persists — tokens, PKCE `code_verifier`s, session
/// state, the discovery cache — flows through the secure-storage abstraction,
/// so tests fake one small interface instead of the whole store contract.
///
/// Keys are namespaced as `oidc/<namespace>/<managerId>/<key>`; managerId is
/// empty for the single-manager case.
class TokenStoreOidcStore implements OidcStore {
  TokenStoreOidcStore({required TokenStore tokenStore})
      : _tokenStore = tokenStore;

  final TokenStore _tokenStore;

  static String _prefix(OidcStoreNamespace namespace, String? managerId) =>
      'oidc/${namespace.value}/${managerId ?? ''}/';

  @override
  Future<void> init() async {
    // flutter_secure_storage needs no explicit initialization.
  }

  @override
  Future<Set<String>> getAllKeys(
    OidcStoreNamespace namespace, {
    String? managerId,
  }) async {
    final prefix = _prefix(namespace, managerId);
    final all = await _tokenStore.readAll();
    return {
      for (final key in all.keys)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    };
  }

  @override
  Future<Map<String, String>> getMany(
    OidcStoreNamespace namespace, {
    required Set<String> keys,
    String? managerId,
  }) async {
    final prefix = _prefix(namespace, managerId);
    final all = await _tokenStore.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix))
          if (keys.contains(entry.key.substring(prefix.length)))
            entry.key.substring(prefix.length): entry.value,
    };
  }

  @override
  Future<void> setMany(
    OidcStoreNamespace namespace, {
    required Map<String, String> values,
    String? managerId,
  }) {
    final prefix = _prefix(namespace, managerId);
    return Future.wait([
      for (final entry in values.entries)
        _tokenStore.write(key: '$prefix${entry.key}', value: entry.value),
    ]);
  }

  @override
  Future<void> removeMany(
    OidcStoreNamespace namespace, {
    required Set<String> keys,
    String? managerId,
  }) {
    final prefix = _prefix(namespace, managerId);
    return Future.wait([
      for (final key in keys) _tokenStore.delete(key: '$prefix$key'),
    ]);
  }
}
