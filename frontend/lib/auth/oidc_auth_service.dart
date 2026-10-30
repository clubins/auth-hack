import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:oidc/oidc.dart';

import 'auth_config.dart';
import 'auth_service.dart';
import 'oidc_store_adapter.dart';
import 'token_store.dart';

/// [AuthService] on top of the oidc package's [OidcUserManager]:
/// authorization code + PKCE against the configured issuer, silent refresh
/// via `offline_access`, and revocation + end-session on sign-out.
class OidcAuthService implements AuthService {
  OidcAuthService({required OidcUserManager manager}) : _manager = manager;

  /// Production wiring: manager over secure storage, discovery from config.
  factory OidcAuthService.fromConfig(
    AuthConfig config, {
    TokenStore? tokenStore,
    http.Client? httpClient,
  }) =>
      OidcAuthService(
        manager: buildOidcUserManager(
          config: config,
          tokenStore: tokenStore,
          httpClient: httpClient,
        ),
      );

  final OidcUserManager _manager;

  @override
  Future<void> init() async {
    try {
      await _manager.init();
    } on OidcException catch (e) {
      throw AuthException(
        'Authentication could not be initialized: ${e.message}',
        cause: e,
      );
    }
  }

  @override
  AuthUser? get currentUser => _mapUser(_manager.currentUser);

  @override
  Stream<AuthUser?> get authStateChanges =>
      _manager.userChanges().map(_mapUser);

  @override
  Future<void> signIn() async {
    try {
      await _manager.loginAuthorizationCodeFlow();
    } on OidcException catch (e) {
      throw AuthException('Sign-in failed: ${e.message}', cause: e);
    }
  }

  @override
  Future<void> signOut() async {
    if (_manager.currentUser == null) {
      await _manager.forgetUser();
      return;
    }
    try {
      // logout() already revokes refresh and access tokens best-effort
      // (RFC 7009), then ends the provider session and clears local state.
      await _manager.logout();
    } on OidcException catch (e) {
      throw AuthException('Sign-out failed: ${e.message}', cause: e);
    }
  }

  @override
  Future<String?> freshAccessToken() async {
    try {
      return await _manager.getAccessToken(minValidity: _minFreshness);
    } on OidcException catch (e) {
      throw AuthException(
        'Could not obtain a fresh access token: ${e.message}',
        cause: e,
      );
    }
  }

  static const _minFreshness = Duration(seconds: 30);

  static AuthUser? _mapUser(OidcUser? user) {
    if (user == null) {
      return null;
    }
    final claims = user.claims.toJson();
    return AuthUser(subject: claims['sub'] as String? ?? '', claims: claims);
  }
}

/// Builds the manager the auth service runs on. [keyStore] stays null in
/// production (keys are fetched from the discovery `jwks_uri`); tests inject
/// a known signing key instead.
OidcUserManager buildOidcUserManager({
  required AuthConfig config,
  TokenStore? tokenStore,
  http.Client? httpClient,
  JsonWebKeyStore? keyStore,
}) {
  return OidcUserManager.lazy(
    discoveryDocumentUri: config.discoveryDocumentUri,
    clientCredentials: OidcClientAuthentication.none(clientId: config.clientId),
    store: TokenStoreOidcStore(tokenStore: tokenStore ?? SecureTokenStore()),
    settings: OidcUserManagerSettings(
      redirectUri: config.redirectUri,
      postLogoutRedirectUri: config.postLogoutRedirectUri,
      scope: config.scopes,
      expectedIssuer: config.issuer,
    ),
    httpClient: httpClient,
    keyStore: keyStore,
    // Single-manager app; a stable id keeps store keys predictable.
    id: 'clubins',
  );
}

/// Surfaced for diagnostics; debug builds only.
void debugLogAuth(Object message) {
  if (!kReleaseMode) {
    debugPrint('clubins auth: $message');
  }
}
