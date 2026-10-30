import 'package:clubins_frontend/api/api.dart';
import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_auth.dart';
import 'fakes/fake_venues_api.dart';

const _user = AuthUser(
  subject: 'user-123',
  claims: {'sub': 'user-123', 'iss': 'https://login.clubins.de/oidc'},
);

final _venue = Venue(
  id: 'v-001',
  name: 'Beispielhalle Nord',
  address: 'Nordstraße 1, 10115 Berlin',
  createdAt: DateTime.utc(2026, 10, 30, 12),
  updatedAt: DateTime.utc(2026, 10, 30, 12),
);

void main() {
  testWidgets('renders the sign-in entry when signed out', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(
      ClubinsApp(authService: auth, venuesApi: FakeVenuesApi()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clubins'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sign-in-button')));
    expect(auth.signInCalls, 1);
  });

  testWidgets('shows the venues home once signed in', (tester) async {
    final auth = FakeAuthService(user: _user);
    final api = FakeVenuesApi(venues: [_venue]);
    await tester.pumpWidget(
      ClubinsApp(authService: auth, venuesApi: api),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clubins venues'), findsOneWidget);
    expect(find.text('Beispielhalle Nord'), findsOneWidget);
    expect(find.text('Nordstraße 1, 10115 Berlin'), findsOneWidget);
    expect(api.listVenuesCalls, 1);
  });

  testWidgets('signing out returns to the sign-in entry', (tester) async {
    final auth = FakeAuthService(user: _user);
    await tester.pumpWidget(
      ClubinsApp(authService: auth, venuesApi: FakeVenuesApi()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Clubins venues'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sign-out-button')));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.byKey(const Key('sign-in-button')), findsOneWidget);
  });

  testWidgets('shows an error placeholder with retry when init fails',
      (tester) async {
    final auth = FakeAuthService(initError: AuthException('IdP unreachable'));
    await tester.pumpWidget(
      ClubinsApp(authService: auth, venuesApi: FakeVenuesApi()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Authentication failed to start'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(auth.initCalls, 2);
  });

  testWidgets('follows the auth state stream to signed-in', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(
      ClubinsApp(authService: auth, venuesApi: FakeVenuesApi()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-button')), findsOneWidget);

    auth.emitUser(_user);
    await tester.pumpAndSettle();

    expect(find.text('Clubins venues'), findsOneWidget);
  });
}
