import 'dart:convert';

/// Builds a JWS compact token for tests — signature content is arbitrary
/// because nothing client-side verifies it.
String encodeSegment(Object? json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

String makeJwt(
  Map<String, dynamic> header,
  Map<String, dynamic> payload, {
  String signature = 'c2ln',
}) =>
    '${encodeSegment(header)}.${encodeSegment(payload)}.$signature';
