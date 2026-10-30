import 'dart:async';

import 'package:clubins_frontend/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _base = Uri.parse('http://localhost:8080');

http.Request? _captured;

ApiClient _clientWith(
  FutureOr<http.Response> Function(http.Request request) handler, {
  Future<String?> Function()? tokens,
}) {
  return ApiClient(
    baseUrl: _base,
    client: MockClient((request) async {
      _captured = request;
      return handler(_captured!);
    }),
    tokenProvider: tokens ?? () async => 'test-token',
  );
}

void main() {
  setUp(() {
    _captured = null;
  });

  test('get attaches the bearer token from the token provider', () async {
    final client = _clientWith(
      (_) => http.Response('[]', 200),
      tokens: () async => 'token-abc',
    );
    await client.get('/venues');
    expect(_captured!.url, _base.resolve('/venues'));
    expect(_captured!.headers['Authorization'], 'Bearer token-abc');
    expect(_captured!.headers['Accept'], 'application/json');
  });

  test('post encodes the JSON body with the content-type header', () async {
    final client = _clientWith((_) => http.Response('{}', 201));
    await client.post('/venues/v-1/grants', body: {'email': 'a@b.de'});
    expect(_captured!.method, 'POST');
    expect(_captured!.headers['Content-Type'], 'application/json');
    expect(_captured!.body, '{"email":"a@b.de"}');
  });

  test('a null token sends the request unauthenticated', () async {
    final client = _clientWith(
      (_) => http.Response('[]', 200),
      tokens: () async => null,
    );
    await client.get('/venues');
    expect(_captured!.headers.containsKey('Authorization'), isFalse);
  });

  test('an erroring token provider becomes an ApiException', () async {
    final client = _clientWith(
      (_) => http.Response('[]', 200),
      tokens: () async => throw StateError('session expired'),
    );
    await expectLater(
      client.get('/venues'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having(
              (e) => e.message,
              'message',
              contains('Could not obtain an access token'),
            ),
      ),
    );
  });

  test('error bodies surface the server message with the status', () async {
    final client =
        _clientWith((_) => http.Response('{"error":"ttl out of bounds"}', 422));
    await expectLater(
      client.post('/venues/v-1/grants'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => e.message, 'message', 'ttl out of bounds'),
      ),
    );
  });

  test('a non-JSON error body falls back to the status code', () async {
    final client = _clientWith((_) => http.Response('oops', 500));
    await expectLater(
      client.get('/venues'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'Request failed (HTTP 500)'),
      ),
    );
  });

  test('a non-JSON success body is malformed, not silently empty', () async {
    final client = _clientWith((_) => http.Response('<html>', 200));
    await expectLater(
      client.get('/venues'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('non-JSON body'),
        ),
      ),
    );
  });

  test('an empty success body decodes to null', () async {
    final client = _clientWith((_) => http.Response('', 204));
    expect(await client.delete('/venues/v-1/grants/g-1'), isNull);
  });

  test('transport failures normalize to a network ApiException', () async {
    final client = ApiClient(
      baseUrl: _base,
      client: MockClient((request) async => throw http.ClientException('x')),
      tokenProvider: () async => 't',
    );
    await expectLater(
      client.get('/venues'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', isNull)
            .having((e) => e.message, 'message', 'Could not reach the Clubins API'),
      ),
    );
  });
}
