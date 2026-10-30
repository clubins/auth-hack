import 'dart:convert';

/// Where the Clubins API lives. Build configuration (`--dart-define`),
/// never code — mirrors how [AuthConfig] drives the issuer.
///
/// Note: this file intentionally does not import `lib/auth/` — the API
/// layer stays decoupled from the OIDC client, so the https/loopback rule
/// is restated here instead of shared.
class ApiConfig {
  const ApiConfig({required this.baseUrl});

  /// API root: local compose maps the backend to
  /// `http://localhost:8080`, production serves `https://api.clubins.de`.
  final Uri baseUrl;

  static const _kApiUrl = 'CLUBINS_API_URL';

  /// Builds the config from compile-time dart-defines with the
  /// compose-stack default, so `flutter run` works against
  /// `docker compose up` as-is.
  factory ApiConfig.fromEnvironment() => ApiConfig.fromMap({
        _kApiUrl: String.fromEnvironment(
          _kApiUrl,
          defaultValue: 'http://localhost:8080',
        ),
      });

  /// Validates and builds the config from a raw value map; fails fast at
  /// boot with the problem named. Plain http is only allowed on loopback
  /// hosts (same rule as the auth config, RFC 8252 §7.3).
  factory ApiConfig.fromMap(Map<String, String?> values) {
    final raw = values[_kApiUrl] ?? '';
    final url = Uri.tryParse(raw);
    final secureEnough = url != null &&
        url.hasScheme &&
        url.hasAuthority &&
        (url.scheme == 'https' ||
            (url.scheme == 'http' &&
                const {'localhost', '127.0.0.1', '::1'}.contains(url.host)));
    if (!secureEnough) {
      throw ApiConfigException(
        '$_kApiUrl must be https (or http on localhost/127.0.0.1), '
        'got "$raw"',
      );
    }
    return ApiConfig(baseUrl: url);
  }

  /// Human-readable form for API errors and debugging.
  @override
  String toString() => baseUrl.toString();
}

/// Thrown when [ApiConfig.fromMap] rejects the configuration.
class ApiConfigException implements Exception {
  ApiConfigException(this.message);

  final String message;

  @override
  String toString() => 'ApiConfigException: $message';
}

/// JSON encoder used by the token inspector for stable, indented claim
/// output; kept here so the encoding rule lives in one place.
String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
