/// Authentication core for the Clubins Flutter client: standard OIDC
/// (discovery, authorization code + PKCE, RS256/JWKS via the `oidc`
/// package) with tokens held in secure storage behind [TokenStore].
library;

export 'auth_config.dart';
export 'auth_service.dart';
export 'oidc_auth_service.dart';
export 'oidc_store_adapter.dart';
export 'token_store.dart';
