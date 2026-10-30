import 'dart:async';

import 'package:clubins_frontend/api/api.dart';
import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_auth.dart';
import '../fakes/fake_venues_api.dart';
import '../helpers/make_jwt.dart';
import '../widgets.dart';

const _user = AuthUser(subject: 'user-123', claims: {'sub': 'user-123'});

final _venue1 = Venue(
  id: 'v-001',
  name: 'Beispielhalle Nord',
  address: 'Nordstraße 1, 10115 Berlin',
  createdAt: DateTime.utc(2026, 10, 30, 12),
  updatedAt: DateTime.utc(2026, 10, 30, 12),
);

final _venue2 = Venue(
  id: 'v-002',
  name: 'Musterkulturhaus',
  address: 'Musterweg 12, 20095 Hamburg',
  createdAt: DateTime.utc(2026, 10, 30, 12),
  updatedAt: DateTime.utc(2026, 10, 30, 12),
);

HomeScreen _screen(AuthService auth, VenuesApi api) => HomeScreen(
      authService: auth,
      venuesApi: api,
      user: _user,
    );

void main() {
  testWidgets('shows a loading state while venues are in flight',
      (tester) async {
    final gate = Completer<void>();
    final api = FakeVenuesApi(venues: [_venue1])..gate = gate;
    await pumpScreen(tester, _screen(FakeAuthService(user: _user), api));

    expect(find.text('Loading venues…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders venue names and addresses from the API shape',
      (tester) async {
    final api = FakeVenuesApi(venues: [_venue1, _venue2]);
    await pumpScreen(tester, _screen(FakeAuthService(user: _user), api));
    await tester.pumpAndSettle();

    expect(find.text('Beispielhalle Nord'), findsOneWidget);
    expect(find.text('Musterkulturhaus'), findsOneWidget);
    expect(find.text('Nordstraße 1, 10115 Berlin'), findsOneWidget);
  });

  testWidgets('shows an empty state when no venues are accessible',
      (tester) async {
    await pumpScreen(
      tester,
      _screen(FakeAuthService(user: _user), FakeVenuesApi()),
    );
    await tester.pumpAndSettle();

    expect(find.text('No venues yet'), findsOneWidget);
  });

  testWidgets('shows an error with retry on API failure', (tester) async {
    final api = FakeVenuesApi(listVenuesError: ApiException('boom'));
    await pumpScreen(tester, _screen(FakeAuthService(user: _user), api));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);

    // Retry recovers: clear the scripted failure before tapping Retry.
    api.listVenuesError = null;
    api.venues.add(_venue1);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Beispielhalle Nord'), findsOneWidget);
    expect(api.listVenuesCalls, 2);
  });

  testWidgets('tapping a venue opens its detail screen', (tester) async {
    final api = FakeVenuesApi(venues: [_venue1]);
    await pumpScreen(tester, _screen(FakeAuthService(user: _user), api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Beispielhalle Nord'));
    await tester.pumpAndSettle();

    // Detail screen shows the venue card and its readings section.
    expect(find.text('ID v-001'), findsOneWidget);
    expect(find.text('Readings'), findsOneWidget);
    expect(api.listReadingsCalls, 1);
  });

  testWidgets('the token inspector opens from the app bar', (tester) async {
    final jwt = makeJwt(
      {'alg': 'RS256', 'kid': 'k1', 'typ': 'JWT'},
      {'sub': 'user-123', 'scope': 'https://api.clubins.de/venues:read'},
    );
    await pumpScreen(
      tester,
      _screen(FakeAuthService(user: _user, accessToken: jwt), FakeVenuesApi()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('token-inspector-button')));
    await tester.pumpAndSettle();

    expect(find.text('Token inspector'), findsOneWidget);
    expect(find.text('Payload claims'), findsOneWidget);
  });
}
