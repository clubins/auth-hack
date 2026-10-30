import 'api_client.dart';
import 'models.dart';

/// Server-side grant window bounds in hours (the grants service rejects
/// anything else with 422). The picker and the client-side guard read
/// these constants so the app cannot produce a request the server would
/// refuse.
const int minGrantHours = 8;
const int maxGrantHours = 24;
const int defaultGrantHours = 8;

/// The wire format for a grant window: Go's `time.ParseDuration` accepts
/// `"8h"`, `"12h"`, …
String ttlFromHours(int hours) => '${hours}h';

/// The venues REST surface the app consumes. Screens depend on this
/// interface, never on the transport — tests inject a scripted fake.
abstract interface class VenuesApi {
  Future<List<Venue>> listVenues();

  /// Sensor readings for one venue. See [Reading]: the endpoint is a
  /// proposed contract until the API lands it.
  Future<List<Reading>> listReadings(String venueId);

  /// Existing access grants for one venue, newest first is the server's
  /// choice; the UI renders the list as given.
  Future<List<VenueGrant>> listGrants(String venueId);

  /// Invites [email] to read [venueId] for the next [hours] hours
  /// (bounded by [minGrantHours]/[maxGrantHours]) and returns the created
  /// grant, whose [VenueGrant.token] is shown to the owner for sharing.
  Future<VenueGrant> createGrant(
    String venueId, {
    required String email,
    required int hours,
  });

  /// Revokes a grant early; returns the revoked grant.
  Future<VenueGrant> revokeGrant(String venueId, String grantId);
}

/// [VenuesApi] over [ApiClient] — the only place that knows the routes.
class HttpVenuesApi implements VenuesApi {
  HttpVenuesApi(this._client);

  final ApiClient _client;

  @override
  Future<List<Venue>> listVenues() =>
      _map(_client.get('/venues'), (decoded) => _list(decoded, Venue.fromJson));

  @override
  Future<List<Reading>> listReadings(String venueId) => _map(
      _client.get('/venues/${_segment(venueId)}/readings'),
      (decoded) => _list(decoded, Reading.fromJson));

  @override
  Future<List<VenueGrant>> listGrants(String venueId) => _map(
      _client.get('/venues/${_segment(venueId)}/grants'),
      (decoded) => _list(decoded, VenueGrant.fromJson));

  @override
  Future<VenueGrant> createGrant(
    String venueId, {
    required String email,
    required int hours,
  }) {
    if (hours < minGrantHours || hours > maxGrantHours) {
      throw ArgumentError.value(
        hours,
        'hours',
        'must be within $minGrantHours and $maxGrantHours',
      );
    }
    return _map(
      _client.post(
        '/venues/${_segment(venueId)}/grants',
        body: {'email': email, 'ttl': ttlFromHours(hours)},
      ),
      (decoded) => _object(decoded, VenueGrant.fromJson, 'grant'),
    );
  }

  @override
  Future<VenueGrant> revokeGrant(String venueId, String grantId) => _map(
        _client.delete(
          '/venues/${_segment(venueId)}/grants/${_segment(grantId)}',
        ),
        (decoded) => _object(decoded, VenueGrant.fromJson, 'grant'),
      );

  /// Runs [parse] over the decoded body, normalizing every parsing failure
  /// to [ApiException.malformed] so screens only ever handle one error
  /// type. [ApiException]s from the transport pass through unchanged.
  Future<T> _map<T>(
    Future<Object?> send,
    T Function(Object? decoded) parse,
  ) async {
    try {
      return parse(await send);
    } on ApiException {
      rethrow;
    } on Object catch (e) {
      throw ApiException.malformed('unexpected response shape', e);
    }
  }

  List<T> _list<T>(Object? decoded, T Function(Map<String, dynamic>) fromJson) {
    if (decoded is! List) {
      throw const FormatException('expected a JSON array');
    }
    return [for (final item in decoded) _object(item, fromJson, 'list item')];
  }

  T _object<T>(
    Object? decoded,
    T Function(Map<String, dynamic>) fromJson,
    String what,
  ) {
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('expected a JSON object for $what');
    }
    return fromJson(decoded);
  }

  /// Venue and grant ids are server-generated slugs, but they end up in a
  /// URL path — encode defensively.
  String _segment(String raw) => Uri.encodeComponent(raw);
}
