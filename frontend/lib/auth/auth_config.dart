import 'package:oidc/oidc.dart';

/// Where and how the app authenticates: the Logto issuer, the client
/// registration, and the OAuth redirects.
///
/// Every value is build configuration (`--dart-define`), never code — local
/// compose and production differ only in defines:
///
/// ```
/// flutter run \
///   --dart-define=CLUBINS_ISSUER=https://login.clubins.de/oidc \
///   --dart-define=CLUBINS_CLIENT_ID=clubins-flutter
/// ```
class AuthConfig {
  const AuthConfig({
    required this.issuer,
    required this.clientId,
    required this.audience,
    required this.redirectUri,
    required this.postLogoutRedirectUri,
    required this.scopes,
  });

  /// OpenID Connect issuer of the Logto instance.
  ///
  /// Local compose: `http://localhost:3301/oidc` —
  /// production: `https://login.clubins.de/oidc` (per the Logto mount).
  final Uri issuer;

  /// OAuth client id registered in Logto (public client, PKCE, no secret).
  final String clientId;

  /// Audience the Clubins API validates access tokens against; the venue
  /// scope lives under this API resource.
  final Uri audience;

  /// Where the hosted sign-in redirects back to (custom scheme `clubins://`).
  final Uri redirectUri;

  /// Where RP-initiated logout redirects back to.
  final Uri postLogoutRedirectUri;

  /// OAuth scopes requested at the authorization endpoint, including
  /// `offline_access` for refresh tokens and the API-resource venue scope.
  final List<String> scopes;

  /// dart-define keys, kept as constants so [fromMap] stays testable.
  static const _kIssuer = 'CLUBINS_ISSUER';
  static const _kClientId = 'CLUBINS_CLIENT_ID';
  static const _kAudience = 'CLUBINS_AUDIENCE';
  static const _kRedirectUri = 'CLUBINS_REDIRECT_URI';
  static const _kPostLogoutRedirectUri = 'CLUBINS_POST_LOGOUT_REDIRECT_URI';

  /// Scopes every Clubins client requests; [fromMap] appends the venue scope.
  static const baseScopes = [
    'openid',
    'profile',
    'email',
    'offline_access',
  ];

  /// The venue-read permission expressed as a Logto API-resource scope.
  static String venueScope(Uri audience) => '$audience/venues:read';

  /// Builds the config from compile-time dart-defines, with compose-stack
  /// defaults so `flutter run` works against `docker compose up` as-is.
  factory AuthConfig.fromEnvironment() => AuthConfig.fromMap(const {
        _kIssuer: String.fromEnvironment(
          _kIssuer,
          defaultValue: 'http://localhost:3301/oidc',
        ),
        _kClientId: String.fromEnvironment(
          _kClientId,
          defaultValue: 'clubins-flutter',
        ),
        _kAudience: String.fromEnvironment(
          _kAudience,
          defaultValue: 'https://api.clubins.de',
        ),
        _kRedirectUri: String.fromEnvironment(
          _kRedirectUri,
          defaultValue: 'clubins://login-callback',
        ),
        _kPostLogoutRedirectUri: String.fromEnvironment(
          _kPostLogoutRedirectUri,
          defaultValue: 'clubins://logout-callback',
        ),
      });

  /// Validates and builds the config from a raw value map. Missing or
  /// malformed values fail fast at boot with every problem named.
  ///
  /// Plain-http issuers are only allowed on loopback hosts — RFC 8252 §7.3
  /// allows loopback exceptions for native apps; anything else must be https.
  factory AuthConfig.fromMap(Map<String, String?> values) {
    final problems = <String>[];

    final issuer = Uri.tryParse(values[_kIssuer] ?? '');
    if (issuer == null || !issuer.hasScheme || !issuer.hasAuthority) {
      problems.add('$_kIssuer must be a valid URI');
    } else if (!_isSecureEnough(issuer)) {
      problems.add(
        '$_kIssuer must be https (or http on localhost/127.0.0.1), '
        'got "$issuer"',
      );
    }

    final audience = Uri.tryParse(values[_kAudience] ?? '');
    if (audience == null || !audience.hasScheme || !audience.hasAuthority) {
      problems.add('$_kAudience must be a valid URI');
    } else if (!_isSecureEnough(audience)) {
      problems.add(
        '$_kAudience must be https (or http on localhost/127.0.0.1), '
        'got "$audience"',
      );
    }

    final clientId = values[_kClientId];
    if (clientId == null || clientId.isEmpty) {
      problems.add('$_kClientId must be set');
    }

    final redirectUri = Uri.tryParse(values[_kRedirectUri] ?? '');
    if (redirectUri == null || !redirectUri.hasScheme) {
      problems.add('$_kRedirectUri must be a valid URI');
    }

    final postLogoutRedirectUri =
        Uri.tryParse(values[_kPostLogoutRedirectUri] ?? '');
    if (postLogoutRedirectUri == null || !postLogoutRedirectUri.hasScheme) {
      problems.add('$_kPostLogoutRedirectUri must be a valid URI');
    }

    if (problems.isNotEmpty) {
      throw AuthConfigException(problems);
    }

    return AuthConfig(
      issuer: issuer!,
      clientId: clientId!,
      audience: audience!,
      redirectUri: redirectUri!,
      postLogoutRedirectUri: postLogoutRedirectUri!,
      scopes: [...baseScopes, venueScope(audience)],
    );
  }

  static bool _isSecureEnough(Uri uri) =>
      uri.scheme == 'https' ||
      (uri.scheme == 'http' &&
          const {'localhost', '127.0.0.1', '::1'}.contains(uri.host));

  /// Discovery document location, derived per OpenID Connect Discovery §4.1
  /// (path-appended, which is how Logto mounts its `/oidc` endpoint):
  /// `http://localhost:3301/oidc` →
  /// `http://localhost:3301/oidc/.well-known/openid-configuration`.
  Uri get discoveryDocumentUri =>
      OidcUtils.getOpenIdConfigWellKnownUri(issuer);
}

/// Thrown when [AuthConfig.fromMap] rejects the configuration; every
/// validation problem is listed in [problems].
class AuthConfigException implements Exception {
  AuthConfigException(this.problems);

  final List<String> problems;

  @override
  String toString() =>
      'AuthConfigException: invalid authentication config:\n'
      '${problems.map((p) => '  - $p').join('\n')}';
}
