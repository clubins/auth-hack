import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Key-value persistence for authentication material: tokens, PKCE
/// verifiers, session state.
///
/// The abstraction exists so the auth stack never touches a platform channel
/// directly: production binds [SecureTokenStore], tests bind an in-memory
/// fake, and [TokenStoreOidcStore] adapts either one to the oidc package.
abstract interface class TokenStore {
  /// Stores [value] under [key], replacing any previous value.
  Future<void> write({required String key, required String value});

  /// Returns the value stored under [key], or null when absent.
  Future<String?> read({required String key});

  /// Removes [key]; a no-op when the key is absent.
  Future<void> delete({required String key});

  /// Returns every stored key-value pair.
  Future<Map<String, String>> readAll();
}

/// Production [TokenStore] backed by flutter_secure_storage.
///
/// Values land in the platform keystore (Android Keystore-backed
/// EncryptedSharedPreferences, iOS/macOS Keychain, ...), never in
/// plain-text app storage.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}
