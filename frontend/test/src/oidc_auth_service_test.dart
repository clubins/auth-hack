import 'dart:convert';

import 'package:clubins_frontend/auth/auth_config.dart';
import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/auth/oidc_auth_service.dart';
import 'package:clubins_frontend/auth/oidc_store_adapter.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oidc/oidc.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../fakes/fake_auth.dart';

class _MockOidcPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements OidcPlatform {}

/// A canned, Logto-shaped IdP served by a MockClient — no real IdP and no
/// network in CI. Mirrors the oidc package's own test mocking pattern.
class _MockIdp {
  _MockIdp({this.issuer = 'http://localhost:3301/oidc'});

  final String issuer;

  final List<http.Request> requests = [];

  /// RFC 7515/7520 test-vector oct key; mock id_tokens are signed HS256 with
  /// it and the manager's keyStore is seeded with it (signature verification
  /// is always strict).
  static final JsonWebKey signingKey = JsonWebKey.fromJson({
    'kty': 'oct',
    'k':
        'AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow',
  })!;

  static const clientId = 'clubins-flutter';

  Map<String, dynamic> metadata() => {
        'issuer': issuer,
        'authorization_endpoint': '$issuer/auth',
        'token_endpoint': '$issuer/token',
        'revocation_endpoint': '$issuer/token/revocation',
        'jwks_uri': '$issuer/jwks',
        'grant_types_supported': [
          OidcConstants_GrantType.authorizationCode,
          OidcConstants_GrantType.refreshToken,
        ],
        'code_challenge_methods_supported': ['S256'],
        'id_token_signing_alg_values_supported': ['HS256'],
      };

  Map<String, dynamic> tokenResponse({
    Duration expiresIn = const Duration(hours: 1),
  }) =>
      {
        'access_token': clock.now().microsecondsSinceEpoch.toString(),
        'token_type': 'Bearer',
        'refresh_token': '8xLOxBtZp8',
        'expires_in': expiresIn.inSeconds,
        'id_token': _idToken(),
      };

  String _idToken() {
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = {
        'iss': issuer,
        'iat': clock.now().secondsSinceEpoch,
        'exp': clock.now().add(const Duration(hours: 1)).secondsSinceEpoch,
        'aud': clientId,
        'sub': 'user-123',
      }
      ..addRecipient(signingKey, algorithm: 'HS256');
    return builder.build().toCompactSerialization();
  }

  http.Client client() => MockClient((request) async {
        requests.add(request);
        final segments = request.url.pathSegments;
        if (segments.length == 3 &&
            segments[1] == '.well-known' &&
            segments[2] == 'openid-configuration') {
          return http.Response(jsonEncode(metadata()), 200);
        }
        if (segments.isNotEmpty && segments.last == 'token') {
          return http.Response(jsonEncode(tokenResponse()), 200);
        }
        if (segments.isNotEmpty && segments.last == 'revocation') {
          return http.Response('', 200);
        }
        if (segments.isNotEmpty && segments.last == 'jwks') {
          return http.Response(
            jsonEncode({
              'keys': [signingKey.toJson()],
            }),
            200,
          );
        }
        throw UnimplementedError('unexpected request ${request.url}');
      });

  /// Plants a cached token in the store the way the manager saves one, so
  /// init() restores the session from secure storage.
  Future<void> plantToken(
    TokenStoreOidcStore store, {
    required DateTime issuedAt,
  }) async {
    await withClock(Clock.fixed(issuedAt), () async {
      final response = tokenResponse()
        ..['expiresInReferenceDate'] = issuedAt.toIso8601String();
      await store.setMany(
        OidcStoreNamespace.secureTokens,
        values: {
          OidcConstants_Store.currentToken: jsonEncode(response),
        },
        // Must match buildOidcUserManager's manager id.
        managerId: 'clubins',
      );
    });
  }
}

AuthConfig get _testConfig => AuthConfig(
      issuer: Uri.parse('http://localhost:3301/oidc'),
      clientId: _MockIdp.clientId,
      audience: Uri.parse('https://api.clubins.de'),
      redirectUri: Uri.parse('clubins://login-callback'),
      postLogoutRedirectUri: Uri.parse('clubins://logout-callback'),
      scopes: ['openid', 'offline_access'],
    );

/// Mirrors buildOidcUserManager's wiring, but pins initMode to
/// blockingValidate so restore/refresh complete inside init() — the
/// production default (cacheFirst) defers revalidation to the background.
OidcUserManager _buildManager(
  http.Client client, {
  TokenStoreOidcStore? store,
  Uri? postLogoutRedirectUri,
}) {
  return OidcUserManager.lazy(
    discoveryDocumentUri: _testConfig.discoveryDocumentUri,
    clientCredentials:
        OidcClientAuthentication.none(clientId: _MockIdp.clientId),
    store: store ?? TokenStoreOidcStore(tokenStore: InMemoryTokenStore()),
    settings: OidcUserManagerSettings(
      redirectUri: _testConfig.redirectUri,
      postLogoutRedirectUri: postLogoutRedirectUri,
      scope: _testConfig.scopes,
      expectedIssuer: _testConfig.issuer,
      initMode: OidcInitMode.blockingValidate,
    ),
    httpClient: client,
    keyStore: JsonWebKeyStore()..addKey(_MockIdp.signingKey),
    id: 'clubins',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockOidcPlatform platform;

  setUpAll(() {
    registerFallbackValue(const OidcPlatformSpecificOptions());
    registerFallbackValue(OidcProviderMetadata.fromJson({'issuer': 'x'}));
    registerFallbackValue(const OidcEndSessionRequest());
  });

  setUp(() {
    platform = _MockOidcPlatform();
    when(platform.nativeBrowserEvents)
        .thenAnswer((_) => Stream<OidcNativeBrowserEvent>.empty());
    // logout() always consults the end-session endpoint; report "no browser
    // result" so the local cleanup path (revoke + forget) runs.
    when(() => platform.getEndSessionResponse(
          any(),
          any(),
          any(),
          any(),
        )).thenAnswer((_) async => null);
    when(() => platform.prepareForRedirectFlow(any()))
        .thenReturn(<String, dynamic>{});
    OidcPlatform.instance = platform;
  });

  group('OidcAuthService against a mocked IdP', () {
    test('init fetches discovery from the derived URI and starts signed out',
        () async {
      final idp = _MockIdp();
      final service = OidcAuthService(manager: _buildManager(idp.client()));

      await service.init();

      expect(
        idp.requests.map((r) => r.url.toString()),
        contains(
          'http://localhost:3301/oidc/.well-known/openid-configuration',
        ),
      );
      expect(service.currentUser, isNull);
    });

    test('init restores a cached session and exposes ID-token claims',
        () async {
      final idp = _MockIdp();
      final store = TokenStoreOidcStore(tokenStore: InMemoryTokenStore());
      final issuedAt = DateTime.utc(2026, 10, 30, 12);
      await idp.plantToken(store, issuedAt: issuedAt);
      final service = OidcAuthService(
        manager: _buildManager(idp.client(), store: store),
      );

      await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 1))),
        () => service.init(),
      );

      final user = service.currentUser;
      expect(user, isNotNull);
      expect(user!.subject, 'user-123');
      expect(user.claims['iss'], 'http://localhost:3301/oidc');
      expect(user.claims['aud'], _MockIdp.clientId);
      // Restore must not hit the token endpoint.
      expect(
        idp.requests.where((r) => r.url.path.endsWith('/token')),
        isEmpty,
      );
    });

    test('init silently refreshes an expired cached session', () async {
      final idp = _MockIdp();
      final store = TokenStoreOidcStore(tokenStore: InMemoryTokenStore());
      final issuedAt = DateTime.utc(2026, 10, 30, 12);
      await idp.plantToken(store, issuedAt: issuedAt);
      final service = OidcAuthService(
        manager: _buildManager(idp.client(), store: store),
      );

      // Now is 2h after issuance; the 1h token is expired.
      await withClock(
        Clock.fixed(issuedAt.add(const Duration(hours: 2))),
        () => service.init(),
      );

      expect(service.currentUser, isNotNull);
      expect(
        idp.requests.where((r) => r.url.path.endsWith('/token')),
        isNotEmpty,
        reason: 'an expired session must be refreshed during init',
      );
    });

    test('freshAccessToken returns the cached token while fresh', () async {
      final idp = _MockIdp();
      final store = TokenStoreOidcStore(tokenStore: InMemoryTokenStore());
      final issuedAt = DateTime.utc(2026, 10, 30, 12);
      await idp.plantToken(store, issuedAt: issuedAt);
      final service = OidcAuthService(
        manager: _buildManager(idp.client(), store: store),
      );

      await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 1))),
        () => service.init(),
      );
      // Also inside the fixed clock: the freshness math must be evaluated
      // against the same timeline the token was planted on.
      final token = await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 1))),
        () => service.freshAccessToken(),
      );

      expect(token, isNotNull);
      expect(
        idp.requests.where((r) => r.url.path.endsWith('/token')),
        isEmpty,
        reason: 'a fresh session must not trigger a token request',
      );
    });

    test('freshAccessToken returns null when signed out', () async {
      final idp = _MockIdp();
      final service = OidcAuthService(manager: _buildManager(idp.client()));
      await service.init();

      expect(await service.freshAccessToken(), isNull);
    });

    test('init rejects a discovery document from the wrong issuer', () async {
      final idp = _MockIdp(issuer: 'http://evil.example.com/oidc');
      final service = OidcAuthService(manager: _buildManager(idp.client()));

      await expectLater(service.init(), throwsA(isA<AuthException>()));
      expect(service.currentUser, isNull);
    });

    test('init surfaces an unreachable IdP as AuthException', () async {
      final client = MockClient((request) async => http.Response('', 500));
      final service = OidcAuthService(manager: _buildManager(client));

      await expectLater(service.init(), throwsA(isA<AuthException>()));
    });

    test('signOut clears the session and revokes tokens at the IdP',
        () async {
      final idp = _MockIdp();
      final store = TokenStoreOidcStore(tokenStore: InMemoryTokenStore());
      final issuedAt = DateTime.utc(2026, 10, 30, 12);
      await idp.plantToken(store, issuedAt: issuedAt);
      final service = OidcAuthService(
        manager: _buildManager(idp.client(), store: store),
      );
      await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 1))),
        () => service.init(),
      );
      expect(service.currentUser, isNotNull);

      await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 2))),
        () => service.signOut(),
      );

      expect(service.currentUser, isNull);
      final revoked = idp.requests
          .where((r) => r.url.path.endsWith('/revocation'))
          .toList();
      expect(
        revoked,
        hasLength(2),
        reason: 'refresh and access tokens are both revoked (RFC 7009)',
      );
    });

    test('signOut without a session clears local state only', () async {
      final idp = _MockIdp();
      final service =
          OidcAuthService(manager: _buildManager(idp.client()));
      await service.init();

      await service.signOut();

      expect(service.currentUser, isNull);
      expect(
        idp.requests.where((r) => r.url.path.endsWith('/revocation')),
        isEmpty,
      );
    });

    test('authStateChanges replays the current user on listen', () async {
      final idp = _MockIdp();
      final store = TokenStoreOidcStore(tokenStore: InMemoryTokenStore());
      final issuedAt = DateTime.utc(2026, 10, 30, 12);
      await idp.plantToken(store, issuedAt: issuedAt);
      final service = OidcAuthService(
        manager: _buildManager(idp.client(), store: store),
      );
      await withClock(
        Clock.fixed(issuedAt.add(const Duration(minutes: 1))),
        () => service.init(),
      );

      await expectLater(
        service.authStateChanges.first,
        completion(isNotNull),
      );
    });
  });
}
