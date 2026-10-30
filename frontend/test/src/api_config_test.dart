import 'package:clubins_frontend/api/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiConfig', () {
    test('accepts the compose default (http on loopback)', () {
      final config = ApiConfig.fromMap({'CLUBINS_API_URL': 'http://localhost:8080'});
      expect(config.baseUrl.toString(), 'http://localhost:8080');
    });

    test('accepts https production URLs', () {
      final config =
          ApiConfig.fromMap({'CLUBINS_API_URL': 'https://api.clubins.de'});
      expect(config.baseUrl.toString(), 'https://api.clubins.de');
    });

    test('rejects plain http off loopback', () {
      expect(
        () => ApiConfig.fromMap({'CLUBINS_API_URL': 'http://api.clubins.de'}),
        throwsA(
          isA<ApiConfigException>().having(
            (e) => e.message,
            'message',
            contains('must be https (or http on localhost/127.0.0.1)'),
          ),
        ),
      );
    });

    test('rejects garbage URLs', () {
      expect(
        () => ApiConfig.fromMap({'CLUBINS_API_URL': 'not a url'}),
        throwsA(isA<ApiConfigException>()),
      );
    });
  });

  group('HttpVenuesApi', () {
    test('ttlFromHours renders the Go duration string', () {
      expect(ttlFromHours(8), '8h');
      expect(ttlFromHours(24), '24h');
    });

    test('createGrant guards the server window bounds client-side', () {
      final api = HttpVenuesApi(_unreachable());
      expect(
        () => api.createGrant('v-1', hours: 7),
        throwsArgumentError,
      );
      expect(
        () => api.createGrant('v-1', hours: 25),
        throwsArgumentError,
      );
    });
  });
}

/// A client whose use would fail the test — the argument guard must fire
/// before any request is built.
ApiClient _unreachable() => ApiClient(
      baseUrl: Uri.parse('http://localhost:8080'),
      tokenProvider: () async => null,
      timeout: const Duration(milliseconds: 50),
    );
