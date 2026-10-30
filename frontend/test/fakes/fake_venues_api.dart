import 'dart:async';

import 'package:clubins_frontend/api/api.dart';

/// Scriptable [VenuesApi] fake for widget tests: canned results, call
/// counters, captured arguments, injectable failures — no network.
class FakeVenuesApi implements VenuesApi {
  FakeVenuesApi({
    List<Venue> venues = const [],
    List<Reading> readings = const [],
    List<VenueGrant> grants = const [],
    this.listVenuesError,
    this.listReadingsError,
    this.listGrantsError,
    this.createGrantError,
    this.revokeGrantError,
    this.createdGrant,
    this.revokedGrant,
  })  : venues = List.of(venues),
        readings = List.of(readings),
        grants = List.of(grants);

  /// Results served, one per call (last one repeats). Mutable copies of
  /// the canned values so a test can script a recovery on retry.
  final List<Venue> venues;
  final List<Reading> readings;
  final List<VenueGrant> grants;

  Object? listVenuesError;
  Object? listReadingsError;
  Object? listGrantsError;
  Object? createGrantError;
  Object? revokeGrantError;

  /// Returned by createGrant; falls back to a synthesized grant from the
  /// captured arguments so tests can assert the shared token round-trips.
  VenueGrant? createdGrant;
  VenueGrant? revokedGrant;

  int listVenuesCalls = 0;
  int listReadingsCalls = 0;
  int listGrantsCalls = 0;
  int createGrantCalls = 0;
  int revokeGrantCalls = 0;

  String? lastCreateVenueId;
  String? lastCreatedEmail;
  int? lastCreatedHours;
  String? lastRevokeVenueId;
  String? lastRevokedGrantId;

  /// Lets a test park a call mid-flight: when non-null, the method future
  /// does not complete until the completer does — the loading-state
  /// pattern.
  Completer<void>? gate;

  Future<void> _maybeGate() async {
    if (gate != null) {
      await gate!.future;
    }
  }

  @override
  Future<List<Venue>> listVenues() async {
    listVenuesCalls++;
    await _maybeGate();
    final error = listVenuesError;
    if (error != null) {
      throw error;
    }
    return venues;
  }

  @override
  Future<List<Reading>> listReadings(String venueId) async {
    listReadingsCalls++;
    lastReadingsVenueId = venueId;
    await _maybeGate();
    final error = listReadingsError;
    if (error != null) {
      throw error;
    }
    return readings;
  }

  String? lastReadingsVenueId;

  @override
  Future<List<VenueGrant>> listGrants(String venueId) async {
    listGrantsCalls++;
    lastGrantsVenueId = venueId;
    await _maybeGate();
    final error = listGrantsError;
    if (error != null) {
      throw error;
    }
    return grants;
  }

  String? lastGrantsVenueId;

  @override
  Future<VenueGrant> createGrant(
    String venueId, {
    required String email,
    required int hours,
  }) async {
    createGrantCalls++;
    lastCreateVenueId = venueId;
    lastCreatedEmail = email;
    lastCreatedHours = hours;
    await _maybeGate();
    final error = createGrantError;
    if (error != null) {
      throw error;
    }
    return createdGrant ??
        VenueGrant(
          id: 'grant-1',
          venueId: venueId,
          subject: email,
          token: 'grant-token-for-$email',
          expiresAt: DateTime.parse('2026-10-31T08:00:00Z'),
          createdAt: DateTime.parse('2026-10-30T08:00:00Z'),
        );
  }

  @override
  Future<VenueGrant> revokeGrant(String venueId, String grantId) async {
    revokeGrantCalls++;
    lastRevokeVenueId = venueId;
    lastRevokedGrantId = grantId;
    await _maybeGate();
    final error = revokeGrantError;
    if (error != null) {
      throw error;
    }
    final revoked = revokedGrant ??
        VenueGrant(
          id: grantId,
          venueId: venueId,
          subject: 'revoked@example.de',
          token: '',
          expiresAt: DateTime.parse('2026-10-31T08:00:00Z'),
          createdAt: DateTime.parse('2026-10-30T08:00:00Z'),
          revokedAt: DateTime.parse('2026-10-30T09:00:00Z'),
        );
    // Mirror the server: the revoked grant replaces the active one so a
    // reload shows its revoked state.
    grants
      ..removeWhere((g) => g.id == grantId)
      ..add(revoked);
    return revoked;
  }
}
