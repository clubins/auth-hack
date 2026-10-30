import 'dart:async';

import 'package:clubins_frontend/api/api.dart';
import 'package:clubins_frontend/ui/venue_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_venues_api.dart';
import '../widgets.dart';

final _venue = Venue(
  id: 'v-001',
  name: 'Beispielhalle Nord',
  address: 'Nordstraße 1, 10115 Berlin',
  createdAt: DateTime.utc(2026, 10, 30, 12),
  updatedAt: DateTime.utc(2026, 10, 30, 12),
);

VenueDetailScreen _screen(FakeVenuesApi api, {Key? key}) =>
    VenueDetailScreen(
      key: key,
      venuesApi: api,
      venue: _venue,
    );

void main() {
  testWidgets('shows venue identity and a loading state while readings load',
      (tester) async {
    final api = FakeVenuesApi(readings: [])..gate = Completer<void>();
    await pumpScreen(tester, _screen(api));

    expect(find.text('Beispielhalle Nord'), findsNWidgets(2));
    expect(find.text('Nordstraße 1, 10115 Berlin'), findsOneWidget);
    expect(find.text('ID v-001'), findsOneWidget);
    expect(find.text('Readings'), findsOneWidget);
    expect(find.text('Loading readings…'), findsOneWidget);
  });

  testWidgets('renders readings and shows the empty state without them',
      (tester) async {
    final api = FakeVenuesApi(readings: [
      Reading(
        id: 'r-1',
        measuredAt: DateTime.utc(2026, 10, 30, 12, 30),
        temperatureC: 21.5,
      ),
    ]);
    await pumpScreen(tester, _screen(api));
    await tester.pumpAndSettle();
    expect(find.text('21.5 °C'), findsOneWidget);

    // Now the empty venue. A distinct key forces a fresh mount — without
    // it, pumpWidget would preserve the existing state and skip the load.
    await pumpScreen(
      tester,
      _screen(FakeVenuesApi(readings: []), key: const Key('empty-venue')),
    );
    await tester.pumpAndSettle();
    expect(find.text('No readings yet'), findsOneWidget);
  });

  testWidgets('recovers via retry when readings fail', (tester) async {
    final api = FakeVenuesApi(listReadingsError: ApiException('offline'));
    await pumpScreen(tester, _screen(api));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    api.readings.add(Reading(
      id: 'r-1',
      measuredAt: DateTime.utc(2026, 10, 30, 12, 30),
      temperatureC: 19.5,
    ));
    api.listReadingsError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('19.5 °C'), findsOneWidget);
    expect(api.listReadingsCalls, 2);
  });

  testWidgets('opens share access for an owner and lists grants',
      (tester) async {
    final api = FakeVenuesApi(grants: [
      VenueGrant(
        id: 'g-1',
        venueId: 'v-001',
        subject: 'renter@example.de',
        token: 'opaque-token',
        expiresAt: DateTime.utc(2026, 10, 30, 16),
        createdAt: DateTime.utc(2026, 10, 30, 8),
      ),
    ]);
    await pumpScreen(tester, _screen(api));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('share-access-button')));
    await tester.pumpAndSettle();

    // The share screen's section header proves the navigation landed (the
    // detail screen's share affordance is a tooltip, not a Text widget).
    expect(find.text('Grant read access'), findsOneWidget);
    expect(find.text('renter@example.de'), findsOneWidget);
    expect(api.listGrantsCalls, 1);
  });
}
