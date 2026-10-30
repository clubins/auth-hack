/// Typed models for the venues REST surface. Field names mirror the Go
/// structs' JSON tags exactly (backend/internal/venues, backend/internal/
/// grants): lowerCamelCase, RFC 3339 timestamps.
library;

/// A monitored Clubins location — `GET /venues` / `GET /venues/{id}`.
class Venue {
  const Venue({
    required this.id,
    required this.name,
    required this.address,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Venue.fromJson(Map<String, dynamic> json) => Venue(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        createdAt: timestamp(json['createdAt'], 'venue.createdAt'),
        updatedAt: timestamp(json['updatedAt'], 'venue.updatedAt'),
      );

  final String id;
  final String name;
  final String address;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// One sensor reading for a venue.
///
/// PROPOSED contract, not yet server-implemented: `GET /venues/{id}/readings`
/// has no backing route on origin/main or any open branch (checked
/// 2026-10-30). This is the minimal shape the UI renders — unknown extra
/// fields are ignored — and the screen degrades to its error state until
/// the API lands the endpoint.
class Reading {
  const Reading({
    required this.id,
    required this.measuredAt,
    required this.temperatureC,
  });

  factory Reading.fromJson(Map<String, dynamic> json) => Reading(
        id: json['id'] as String,
        measuredAt: timestamp(json['measuredAt'], 'reading.measuredAt'),
        temperatureC: json['temperatureC'] as num,
      );

  final String id;
  final DateTime measuredAt;
  final num temperatureC;
}

/// A temporary read-only access grant for one venue.
///
/// Rendered from the renter-grants surface (`GET /venues/{id}/grants`,
/// `POST /venues/{id}/grants`, revocation): `token` is the opaque grant
/// token the API hands back at creation time, shown once to the owner for
/// sharing.
class VenueGrant {
  const VenueGrant({
    required this.id,
    required this.venueId,
    required this.subject,
    this.token,
    required this.expiresAt,
    required this.createdAt,
    this.revokedAt,
  });

  factory VenueGrant.fromJson(Map<String, dynamic> json) => VenueGrant(
        id: json['id'] as String,
        venueId: json['venueId'] as String,
        subject: json['subject'] as String,
        token: json['token'] as String?,
        expiresAt: timestamp(json['expiresAt'], 'grant.expiresAt'),
        createdAt: timestamp(json['createdAt'], 'grant.createdAt'),
        revokedAt: json['revokedAt'] == null
            ? null
            : timestamp(json['revokedAt'], 'grant.revokedAt'),
      );

  final String id;
  final String venueId;

  /// The grant holder's identity, or the invited identity before the
  /// holder has ever signed in.
  final String subject;

  /// The bearer token for this grant — delivered exactly once, in the
  /// create-201 body. List and revoke responses redact it by design (a
  /// venue-read-scoped caller must not be able to impersonate renters),
  /// so grants parsed from those responses carry null here.
  final String? token;
  final DateTime expiresAt;
  final DateTime createdAt;

  /// When the grant was revoked early, or null while it is still valid.
  final DateTime? revokedAt;

  /// True when the grant was revoked before its expiry.
  bool get isRevoked => revokedAt != null;
}

/// Parses an RFC 3339 timestamp field, naming the field when the value is
/// not a string or not parseable — bare cast errors would lose that.
DateTime timestamp(Object? value, String field) {
  if (value is! String) {
    throw FormatException('expected an ISO-8601 string for "$field"');
  }
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw FormatException('invalid ISO-8601 timestamp for "$field": $value');
  }
}
