import 'package:clubins_frontend/api/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Parsers and route building against the exact JSON the Go structs emit.
void main() {
  group('Venue.fromJson', () {
    test('parses the venues handler shape', () {
      final venue = Venue.fromJson({
        'id': 'v-001',
        'name': 'Beispielhalle Nord',
        'address': 'Nordstraße 1, 10115 Berlin',
        'createdAt': '2026-10-30T12:00:00Z',
        'updatedAt': '2026-10-30T12:00:00Z',
      });
      expect(venue.id, 'v-001');
      expect(venue.name, 'Beispielhalle Nord');
      expect(venue.address, 'Nordstraße 1, 10115 Berlin');
      expect(venue.createdAt, DateTime.utc(2026, 10, 30, 12));
    });

    test('names the field when a timestamp is malformed', () {
      expect(
        () => Venue.fromJson({
          'id': 'v-001',
          'name': 'x',
          'address': 'y',
          'createdAt': 'not-a-date',
          'updatedAt': '2026-10-30T12:00:00Z',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('venue.createdAt'),
          ),
        ),
      );
    });
  });

  group('Reading.fromJson', () {
    test('parses the proposed readings shape and ignores extras', () {
      final reading = Reading.fromJson({
        'id': 'r-1',
        'measuredAt': '2026-10-30T12:30:00Z',
        'temperatureC': 21.5,
        'sensorExtra': 'ignored',
      });
      expect(reading.id, 'r-1');
      expect(reading.measuredAt, DateTime.utc(2026, 10, 30, 12, 30));
      expect(reading.temperatureC, 21.5);
    });
  });

  group('VenueGrant.fromJson', () {
    test('parses the create-201 shape with a token', () {
      final grant = VenueGrant.fromJson({
        'id': 'g-1',
        'venueId': 'v-001',
        'subject': 'user-123',
        'token': 'opaque-token',
        'expiresAt': '2026-10-30T16:00:00Z',
        'createdAt': '2026-10-30T08:00:00Z',
      });
      expect(grant.id, 'g-1');
      expect(grant.subject, 'user-123');
      expect(grant.token, 'opaque-token');
      expect(grant.isRevoked, isFalse);
    });

    // Regression: list and revoke responses redact the token
    // (backend/internal/grants/handler.go grantView serializes no token
    // field). A token-requiring parser threw FormatException on every
    // real list/revoke response.
    test('parses a token-less list/revoke view (redacted shape)', () {
      final grant = VenueGrant.fromJson({
        'id': 'g-1',
        'venueId': 'v-001',
        'subject': 'user-123',
        'expiresAt': '2026-10-30T16:00:00Z',
        'createdAt': '2026-10-30T08:00:00Z',
      });
      expect(grant.id, 'g-1');
      expect(grant.subject, 'user-123');
      expect(grant.token, isNull);
      expect(grant.isRevoked, isFalse);
    });

    test('parses a revoked, token-less view', () {
      final grant = VenueGrant.fromJson({
        'id': 'g-1',
        'venueId': 'v-001',
        'subject': 'user-123',
        'expiresAt': '2026-10-30T16:00:00Z',
        'createdAt': '2026-10-30T08:00:00Z',
        'revokedAt': '2026-10-30T09:00:00Z',
      });
      expect(grant.isRevoked, isTrue);
      expect(grant.revokedAt, DateTime.utc(2026, 10, 30, 9));
      expect(grant.token, isNull);
    });
  });

  group('HttpVenuesApi routes', () {
    test('listVenues GETs /venues and parses the array', () async {
      Uri? url;
      final api = HttpVenuesApi(ApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        client: MockClient((request) async {
          url = request.url;
          return http.Response(
            '[{"id":"v-001","name":"Halle","address":"Weg 1",'
            '"createdAt":"2026-10-30T12:00:00Z",'
            '"updatedAt":"2026-10-30T12:00:00Z"}]',
            200,
          );
        }),
        tokenProvider: () async => 't',
      ));

      final venues = await api.listVenues();
      expect(url!.path, '/venues');
      expect(venues.single.name, 'Halle');
    });

    test('listReadings targets the venue-scoped readings route', () async {
      Uri? url;
      final api = HttpVenuesApi(ApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        client: MockClient((request) async {
          url = request.url;
          return http.Response('[]', 200);
        }),
        tokenProvider: () async => 't',
      ));

      await api.listReadings('v-002');
      expect(url!.path, '/venues/v-002/readings');
    });

    test('createGrant posts ttl only to the grants route', () async {
      http.Request? request;
      final api = HttpVenuesApi(ApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        client: MockClient((r) async {
          request = r;
          return http.Response(
            '{"id":"g-1","venueId":"v-001","subject":"user-123",'
            '"token":"tok","expiresAt":"2026-10-30T16:00:00Z",'
            '"createdAt":"2026-10-30T08:00:00Z"}',
            201,
          );
        }),
        tokenProvider: () async => 't',
      ));

      final grant = await api.createGrant('v-001', hours: 12);
      expect(request!.method, 'POST');
      expect(request!.url.path, '/venues/v-001/grants');
      // The API decodes with DisallowUnknownFields — ttl is the only
      // field it accepts.
      expect(request!.body, '{"ttl":"12h"}');
      expect(grant.token, 'tok');
    });

    test('revokeGrant DELETEs the global /grants/{id} route', () async {
      http.Request? request;
      final api = HttpVenuesApi(ApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        client: MockClient((r) async {
          request = r;
          // The revoke response is the token-redacted view.
          return http.Response(
            '{"id":"g-1","venueId":"v-001","subject":"user-123",'
            '"expiresAt":"2026-10-30T16:00:00Z",'
            '"createdAt":"2026-10-30T08:00:00Z",'
            '"revokedAt":"2026-10-30T09:00:00Z"}',
            200,
          );
        }),
        tokenProvider: () async => 't',
      ));

      final grant = await api.revokeGrant('g-1');
      expect(request!.method, 'DELETE');
      expect(request!.url.path, '/grants/g-1');
      expect(grant.isRevoked, isTrue);
      expect(grant.token, isNull);
    });

    test('a malformed array item becomes an ApiException', () async {
      final api = HttpVenuesApi(ApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        client: MockClient((_) async => http.Response(
              '[{"id":"v-001","name":123,"address":"x",'
              '"createdAt":"2026-10-30T12:00:00Z",'
              '"updatedAt":"2026-10-30T12:00:00Z"}]',
              200,
            )),
        tokenProvider: () async => 't',
      ));

      await expectLater(
        api.listVenues(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('unexpected response shape'),
          ),
        ),
      );
    });
  });
}
