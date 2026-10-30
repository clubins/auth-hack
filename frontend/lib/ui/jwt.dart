import 'dart:convert';

/// The decoded JOSE header and payload of a JWS compact token.
class DecodedJwt {
  const DecodedJwt({required this.header, required this.payload});

  final Map<String, dynamic> header;
  final Map<String, dynamic> payload;
}

/// Decodes a JWS compact serialization (JWT) into its header and payload
/// without verifying it.
///
/// Verification happens server-side on every request — the inspector is
/// a read-only window for the spike, and tokens here must never be
/// trusted for an authorization decision.
///
/// Throws [FormatException] naming the failing part when the token is
/// malformed or either JSON part is not an object.
DecodedJwt decodeJwt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) {
    throw const FormatException(
      'not a JWS compact serialization (expected 3 dot-separated parts)',
    );
  }
  return DecodedJwt(
    header: _decodePart(parts[0], 'header'),
    payload: _decodePart(parts[1], 'payload'),
  );
}

Map<String, dynamic> _decodePart(String part, String label) {
  final List<int> bytes;
  try {
    // base64Url.normalize restores stripped '==' padding, so both padded
    // and unpadded segments decode.
    bytes = base64Url.decode(base64Url.normalize(part));
  } on FormatException {
    throw FormatException('$label is not valid base64url');
  }
  final String json;
  try {
    json = utf8.decode(bytes);
  } on FormatException {
    throw FormatException('$label is not valid UTF-8');
  }
  final Object? value;
  try {
    value = jsonDecode(json);
  } on FormatException {
    throw FormatException('$label is not valid JSON');
  }
  if (value is! Map<String, dynamic>) {
    throw FormatException('$label is not a JSON object');
  }
  return value;
}
