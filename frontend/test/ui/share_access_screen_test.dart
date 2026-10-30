import 'package:clubins_frontend/api/api.dart';
import 'package:clubins_frontend/ui/share_access_screen.dart';
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

/// A grant as list responses carry it: token-redacted, subject is the
/// creating principal's server-assigned sub.
VenueGrant _grant({bool revoked = false}) => VenueGrant(
      id: 'g-1',
      venueId: 'v-001',
      subject: 'user-2kfiXKzqR7BjxM8n',
      expiresAt: DateTime.utc(2026, 10, 30, 16),
      createdAt: DateTime.utc(2026, 10, 30, 8),
      revokedAt: revoked ? DateTime.utc(2026, 10, 30, 9) : null,
    );

/// A grant as the create-201 body carries it: WITH the token — the only
/// response that ever includes it.
VenueGrant _createdGrant() => VenueGrant(
      id: 'g-new',
      venueId: 'v-001',
      subject: 'user-2kfiXKzqR7BjxM8n',
      token: 'opaque-token',
      expiresAt: DateTime.utc(2026, 10, 30, 16),
      createdAt: DateTime.utc(2026, 10, 30, 8),
    );

Future<FakeVenuesApi> _pump(
  WidgetTester tester, {
  FakeVenuesApi? api,
}) async {
  final effective = api ?? FakeVenuesApi();
  await pumpScreen(
    tester,
    ShareAccessScreen(venuesApi: effective, venue: _venue),
  );
  await tester.pumpAndSettle();
  return effective;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    installMockClipboard();
  });

  testWidgets('creates a grant in one step and shows the shareable token',
      (tester) async {
    final api = await _pump(
      tester,
      api: FakeVenuesApi(createdGrant: _createdGrant()),
    );

    expect(find.text('Access window: 8 h'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-grant-button')));
    await tester.pumpAndSettle();

    expect(api.createGrantCalls, 1);
    expect(api.lastCreateVenueId, 'v-001');
    expect(api.lastCreatedHours, 8);
    expect(find.text('Grant created — share this token'), findsOneWidget);
    expect(find.textContaining('opaque-token'), findsOneWidget);
  });

  testWidgets('the window picker is a bounded slider; the value reaches the API',
      (tester) async {
    final api = await _pump(tester, api: FakeVenuesApi());

    // Dead-center tap on an 8..24 slider is 16h — no inset math, one tap.
    await tester.tap(find.byKey(const Key('grant-window-slider')));
    await tester.pumpAndSettle();

    expect(find.text('Access window: 16 h'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-grant-button')));
    await tester.pumpAndSettle();

    expect(api.lastCreatedHours, 16);
  });

  testWidgets('server rejections surface as a SnackBar with the reason',
      (tester) async {
    final api = await _pump(
      tester,
      api: FakeVenuesApi(
        createGrantError: ApiException('ttl out of bounds', statusCode: 422),
      ),
    );

    await tester.tap(find.byKey(const Key('create-grant-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('ttl out of bounds'), findsOneWidget);
    expect(api.createGrantCalls, 1);
  });

  testWidgets('the created token copies to the clipboard with feedback',
      (tester) async {
    await _pump(
      tester,
      api: FakeVenuesApi(createdGrant: _createdGrant()),
    );

    await tester.tap(find.byKey(const Key('create-grant-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('copy-grant-token-button')));
    await tester.pumpAndSettle();

    expect(clipboardText, 'opaque-token');
    expect(find.text('Grant token copied to clipboard'), findsOneWidget);
  });

  testWidgets('lists grants with revoke actions and revokes via DELETE',
      (tester) async {
    final revoked = _grant(revoked: true);
    final api = await _pump(
      tester,
      api: FakeVenuesApi(grants: [_grant()], revokedGrant: revoked),
    );

    expect(find.text('user-2kfiXKzqR7BjxM8n'), findsOneWidget);
    expect(find.textContaining('Expires'), findsOneWidget);

    await tester.tap(find.byKey(const Key('revoke-grant-g-1')));
    await tester.pumpAndSettle();

    expect(api.revokeGrantCalls, 1);
    expect(api.lastRevokedGrantId, 'g-1');
    // The list reloads; the fake now serves the revoked grant, whose tile
    // carries the blocked icon instead of a revoke button.
    expect(find.byIcon(Icons.block), findsOneWidget);
    expect(find.byKey(const Key('revoke-grant-g-1')), findsNothing);
  });

  testWidgets('revoked grants show the blocked state without revoke actions',
      (tester) async {
    await _pump(tester, api: FakeVenuesApi(grants: [_grant(revoked: true)]));

    expect(find.byIcon(Icons.block), findsOneWidget);
    expect(find.byKey(const Key('revoke-grant-g-1')), findsNothing);
  });

  testWidgets('grant-list errors offer retry', (tester) async {
    final api = FakeVenuesApi(listGrantsError: ApiException('offline'));
    await pumpScreen(
      tester,
      ShareAccessScreen(venuesApi: api, venue: _venue),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);

    api.grants.add(_grant());
    api.listGrantsError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('user-2kfiXKzqR7BjxM8n'), findsOneWidget);
    expect(api.listGrantsCalls, 2);
  });

  testWidgets('shows the empty state when no grants exist', (tester) async {
    await _pump(tester, api: FakeVenuesApi());

    expect(find.text('No grants yet'), findsOneWidget);
  });
}
