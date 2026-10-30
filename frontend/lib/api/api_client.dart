import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A failure while talking to the Clubins API, normalized for the UI.
///
/// [statusCode] is null when the request never got an HTTP response
/// (transport failure, timeout, or a token that could not be refreshed) —
/// the distinction the screens use to choose retry wording.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.cause});

  final String message;

  /// HTTP status of the failed response, or null when no response arrived.
  final int? statusCode;

  /// The underlying error, preserved for debugging.
  final Object? cause;

  /// The request never completed: transport failure, timeout, or an access
  /// token that could not be obtained.
  factory ApiException.network(Object cause) =>
      ApiException('Could not reach the Clubins API', cause: cause);

  /// The server answered, but not with the shape the client expected.
  factory ApiException.malformed(String detail, [Object? cause]) =>
      ApiException('Unexpected response from the Clubins API: $detail',
          cause: cause);

  @override
  String toString() => 'ApiException(statusCode: $statusCode): $message';
}

/// The lowest-level API surface: turns a method + path (+ optional JSON
/// body) into a decoded JSON value, attaching the bearer token from the
/// injectable [tokenProvider] on the way out.
///
/// Everything is injected — [http.Client], [baseUrl], token source, and
/// timeout — so tests run against a canned client with no network.
class ApiClient {
  ApiClient({
    http.Client? client,
    required this.baseUrl,
    required this.tokenProvider,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Uri baseUrl;

  /// Resolves a fresh access token per request (usually
  /// `AuthService.freshAccessToken`, which refreshes silently when
  /// needed). Returning null sends the request unauthenticated.
  final Future<String?> Function() tokenProvider;

  final Duration timeout;

  Future<Object?> get(String path) => send('GET', path);

  Future<Object?> post(String path, {Object? body}) =>
      send('POST', path, body: body);

  Future<Object?> delete(String path) => send('DELETE', path);

  /// Sends one request and returns the decoded JSON body (null for an
  /// empty body). Every failure mode is normalized to [ApiException].
  Future<Object?> send(String method, String path, {Object? body}) async {
    final String? token;
    try {
      token = await tokenProvider();
    } on Object catch (e) {
      throw ApiException(
        'Could not obtain an access token — try signing in again',
        cause: e,
      );
    }

    final request = http.Request(method, baseUrl.resolve(path))
      ..headers['Accept'] = 'application/json';
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      throw ApiException.network('request to $path timed out');
    } on http.ClientException catch (e) {
      throw ApiException.network(e);
    }

    if (response.statusCode >= 400) {
      // Proxies and servers answer errors with non-JSON bodies (HTML pages,
      // empty payloads) — the status code is the reliable signal then, so
      // decoding the body is best-effort on this path only.
      Object? decoded;
      try {
        decoded = _decodeBody(path, response);
      } on ApiException {
        decoded = null;
      }
      throw ApiException(
        _errorMessage(decoded, response.statusCode),
        statusCode: response.statusCode,
      );
    }
    return _decodeBody(path, response);
  }

  /// Decodes the response body, tolerating an empty one. Non-JSON bodies
  /// are a contract violation and become [ApiException.malformed] instead
  /// of leaking a jsonDecode stack to the UI.
  Object? _decodeBody(String path, http.Response response) {
    if (response.body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(response.body);
    } on FormatException catch (e) {
      throw ApiException.malformed('$path returned a non-JSON body', e);
    }
  }

  /// Server error bodies are `{"error": "message"}`; anything else falls
  /// back to the status code.
  String _errorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      return decoded['error'] as String;
    }
    return 'Request failed (HTTP $statusCode)';
  }
}
