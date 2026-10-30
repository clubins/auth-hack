import 'package:clubins_frontend/auth/auth_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String?> validValues() => const {
        'CLUBINS_ISSUER': 'https://login.clubins.de/oidc',
        'CLUBINS_CLIENT_ID': 'clubins-flutter',
        'CLUBINS_AUDIENCE': 'https://api.clubins.de',
        'CLUBINS_REDIRECT_URI': 'clubins://login-callback',
        'CLUBINS_POST_LOGOUT_REDIRECT_URI': 'clubins://logout-callback',
      };

  group('AuthConfig.fromMap', () {
    test('builds a valid production config', () {
      final config = AuthConfig.fromMap(validValues());

      expect(config.issuer.toString(), 'https://login.clubins.de/oidc');
      expect(config.clientId, 'clubins-flutter');
      expect(config.audience.toString(), 'https://api.clubins.de');
      expect(config.redirectUri.toString(), 'clubins://login-callback');
      expect(
        config.postLogoutRedirectUri.toString(),
        'clubins://logout-callback',
      );
    });

    test('appends the venue scope to the base scopes', () {
      final config = AuthConfig.fromMap(validValues());

      expect(config.scopes, [
        'openid',
        'profile',
        'email',
        'offline_access',
        'https://api.clubins.de/venues:read',
      ]);
    });

    test('derives the compose-stack discovery URI (path-appended)', () {
      final config = AuthConfig.fromMap({
        ...validValues(),
        'CLUBINS_ISSUER': 'http://localhost:3301/oidc',
      });

      expect(
        config.discoveryDocumentUri.toString(),
        'http://localhost:3301/oidc/.well-known/openid-configuration',
      );
    });

    test('derives the production discovery URI', () {
      final config = AuthConfig.fromMap(validValues());

      expect(
        config.discoveryDocumentUri.toString(),
        'https://login.clubins.de/oidc/.well-known/openid-configuration',
      );
    });

    test('allows plain http on loopback issuers', () {
      for (final host in ['localhost', '127.0.0.1']) {
        final config = AuthConfig.fromMap({
          ...validValues(),
          'CLUBINS_ISSUER': 'http://$host:3301/oidc',
        });
        expect(config.issuer.host, host);
      }
    });

    test('rejects plain http on a remote issuer', () {
      expect(
        () => AuthConfig.fromMap({
          ...validValues(),
          'CLUBINS_ISSUER': 'http://login.clubins.de/oidc',
        }),
        throwsA(
          isA<AuthConfigException>().having(
            (e) => e.problems.join(' '),
            'problems',
            contains('https'),
          ),
        ),
      );
    });

    test('reports every missing value at once', () {
      expect(
        () => AuthConfig.fromMap(const {}),
        throwsA(
          isA<AuthConfigException>().having(
            (e) => e.problems,
            'problems',
            hasLength(5),
          ),
        ),
      );
    });

    test('rejects an empty client id', () {
      expect(
        () => AuthConfig.fromMap({
          ...validValues(),
          'CLUBINS_CLIENT_ID': '',
        }),
        throwsA(isA<AuthConfigException>()),
      );
    });

    test('rejects a redirect without a scheme', () {
      expect(
        () => AuthConfig.fromMap({
          ...validValues(),
          'CLUBINS_REDIRECT_URI': 'not-a-uri',
        }),
        throwsA(isA<AuthConfigException>()),
      );
    });
  });
}
