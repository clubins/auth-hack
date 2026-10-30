import 'package:clubins_frontend/auth/oidc_store_adapter.dart';
import 'package:clubins_frontend/auth/token_store.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oidc/oidc.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../fakes/fake_auth.dart';

/// In-memory stand-in for the secure-storage platform binding so the
/// production wrapper can be exercised without platform channels.
class _TestSecureStoragePlatform extends FlutterSecureStoragePlatform
    with MockPlatformInterfaceMixin {
  _TestSecureStoragePlatform(this._data);

  final Map<String, String> _data;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _data[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _data[key];

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(_data);

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _data.containsKey(key);

  @override
  Future<void> deleteAll({
    required Map<String, String> options,
  }) async => _data.clear();
}

void main() {
  group('InMemoryTokenStore', () {
    late InMemoryTokenStore store;

    setUp(() => store = InMemoryTokenStore());

    test('round-trips a value', () async {
      await store.write(key: 'k', value: 'v');
      expect(await store.read(key: 'k'), 'v');
    });

    test('overwrites an existing key', () async {
      await store.write(key: 'k', value: 'v1');
      await store.write(key: 'k', value: 'v2');
      expect(await store.read(key: 'k'), 'v2');
    });

    test('reads null from an absent key', () async {
      expect(await store.read(key: 'missing'), isNull);
    });

    test('delete removes the key and is a no-op when absent', () async {
      await store.write(key: 'k', value: 'v');
      await store.delete(key: 'k');
      await store.delete(key: 'never-existed');
      expect(await store.read(key: 'k'), isNull);
    });

    test('readAll returns a copy of every entry', () async {
      await store.write(key: 'a', value: '1');
      await store.write(key: 'b', value: '2');
      final all = await store.readAll();
      expect(all, {'a': '1', 'b': '2'});
      all['c'] = '3';
      expect(await store.read(key: 'c'), isNull);
    });
  });

  group('SecureTokenStore', () {
    // The package ships an in-memory platform implementation, so the secure
    // storage binding is exercised without platform channels.
    final data = <String, String>{};

    setUp(() {
      data.clear();
      FlutterSecureStoragePlatform.instance = _TestSecureStoragePlatform(data);
    });

    test('round-trips through the platform keystore interface', () async {
      final store = SecureTokenStore();

      await store.write(key: 'token', value: 'secret-value');
      expect(await store.read(key: 'token'), 'secret-value');
      expect(await store.readAll(), {'token': 'secret-value'});
      await store.delete(key: 'token');
      expect(await store.read(key: 'token'), isNull);
    });
  });

  group('TokenStoreOidcStore', () {
    late InMemoryTokenStore tokenStore;
    late TokenStoreOidcStore store;

    setUp(() {
      tokenStore = InMemoryTokenStore();
      store = TokenStoreOidcStore(tokenStore: tokenStore);
    });

    test('setMany/getMany round-trip within a namespace', () async {
      await store.init();
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'currentToken': '{"access_token":"abc"}'},
      );

      expect(
        await store.getMany(
          OidcStoreNamespace.secureTokens,
          keys: {'currentToken'},
        ),
        {'currentToken': '{"access_token":"abc"}'},
      );
    });

    test('getMany omits absent keys', () async {
      await store.setMany(
        OidcStoreNamespace.state,
        values: {'present': 'yes'},
      );

      expect(
        await store.getMany(
          OidcStoreNamespace.state,
          keys: {'present', 'absent'},
        ),
        {'present': 'yes'},
      );
    });

    test('namespaces do not bleed into each other', () async {
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'nonce': 'n0nce'},
      );
      await store.setMany(
        OidcStoreNamespace.state,
        values: {'nonce': 'not-a-nonce'},
      );

      expect(
        await store.getMany(
          OidcStoreNamespace.secureTokens,
          keys: {'nonce'},
        ),
        {'nonce': 'n0nce'},
      );
      expect(
        await store.getAllKeys(OidcStoreNamespace.session),
        isEmpty,
      );
    });

    test('managerIds isolate keys within a namespace', () async {
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'currentToken': 'a'},
        managerId: 'manager-a',
      );
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'currentToken': 'b'},
        managerId: 'manager-b',
      );

      expect(
        await store.getMany(
          OidcStoreNamespace.secureTokens,
          keys: {'currentToken'},
          managerId: 'manager-a',
        ),
        {'currentToken': 'a'},
      );
      expect(
        await store.getAllKeys(
          OidcStoreNamespace.secureTokens,
          managerId: 'manager-b',
        ),
        {'currentToken'},
      );
    });

    test('removeMany deletes only the requested keys', () async {
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'keep': '1', 'drop': '2'},
      );
      await store.removeMany(
        OidcStoreNamespace.secureTokens,
        keys: {'drop', 'never-there'},
      );

      expect(
        await store.getAllKeys(OidcStoreNamespace.secureTokens),
        {'keep'},
      );
    });

    // The PKCE code_verifier lives in the secureTokens namespace for the
    // lifetime of an in-flight authorization state (see the oidc package's
    // OidcStoreExt.getStateCodeVerifier); this pins that path through the
    // adapter.
    test('persists a PKCE code_verifier for an in-flight state', () async {
      const state = 'st4te';
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';

      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {'oidc.state.$state': verifier},
      );

      expect(
        await store.getMany(
          OidcStoreNamespace.secureTokens,
          keys: {'oidc.state.$state'},
        ),
        {'oidc.state.$state': verifier},
      );
    });
  });
}
