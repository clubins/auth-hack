import 'dart:async';

import 'package:clubins_frontend/auth/auth.dart';

/// In-memory [TokenStore] for tests: same semantics as the secure-storage
/// binding, no platform channel.
class InMemoryTokenStore implements TokenStore {
  final Map<String, String> _data = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _data[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => _data[key];

  @override
  Future<void> delete({required String key}) async {
    _data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(_data);
}

/// Scriptable [AuthService] fake for widget tests: records calls, replays a
/// user (or an init failure), and never touches a platform channel.
class FakeAuthService implements AuthService {
  FakeAuthService({
    AuthUser? user,
    Object? initError,
    Object? signInError,
    Object? signOutError,
    String? accessToken,
  })  : _user = user,
        _initError = initError,
        _signInError = signInError,
        _signOutError = signOutError,
        _accessToken = accessToken,
        _changes = StreamController<AuthUser?>.broadcast();

  AuthUser? _user;
  final Object? _initError;
  final Object? _signInError;
  final Object? _signOutError;
  final String? _accessToken;
  final StreamController<AuthUser?> _changes;

  int initCalls = 0;
  int signInCalls = 0;
  int signOutCalls = 0;
  int freshTokenCalls = 0;

  /// Pushes a user (or null) to [authStateChanges] listeners and updates
  /// [currentUser].
  void emitUser(AuthUser? user) {
    _user = user;
    _changes.add(user);
  }

  @override
  Future<void> init() async {
    initCalls++;
    if (_initError != null) {
      throw _initError;
    }
  }

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> get authStateChanges =>
      // Replays the current user on every listen, mirroring the oidc
      // package's OidcValueStream contract.
      Stream<AuthUser?>.multi((controller) {
        controller.add(_user);
        final sub = _changes.stream.listen(
          controller.add,
          onError: controller.addError,
        );
        controller.onCancel = sub.cancel;
      });

  @override
  Future<void> signIn() async {
    signInCalls++;
    if (_signInError != null) {
      throw _signInError;
    }
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (_signOutError != null) {
      throw _signOutError;
    }
    emitUser(null);
  }

  @override
  Future<String?> freshAccessToken() async {
    freshTokenCalls++;
    if (_user == null) {
      return null;
    }
    return _accessToken;
  }
}
