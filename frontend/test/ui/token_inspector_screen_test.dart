import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/ui/token_inspector_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_auth.dart';
import '../helpers/make_jwt.dart';
import '../widgets.dart';

const _user = AuthUser(
  subject: 'user-123',
  claims: {
    'sub': 'user-123',
    'iss': 'https://login.clubins.de/oidc',
    'scope': 'openid https://api.clubins.de/venues:read',
  },
);

Future<void> _pumpInspector(
  WidgetTester tester,
  String? accessToken,
) async {
  await pumpScreen(
    tester,
    TokenInspectorScreen(
      authService: FakeAuthService(user: _user, accessToken: accessToken),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    installMockClipboard();
  });

  testWidgets('shows the raw token, the Authorization header, and both claim sets',
      (tester) async {
    final token = makeJwt(
      {'alg': 'RS256', 'kid': '2026-10-key', 'typ': 'JWT'},
      {
        'sub': 'user-123',
        'aud': 'https://api.clubins.de',
        'iss': 'https://login.clubins.de/oidc',
      },
    );
    await _pumpInspector(tester, token);

    expect(find.text('Token inspector'), findsOneWidget);
    // Sections exist…
    expect(find.text('Access token'), findsOneWidget);
    expect(find.text('Authorization header'), findsOneWidget);
    expect(find.text('Header claims (JOSE)'), findsOneWidget);
    expect(find.text('Payload claims'), findsOneWidget);
    // …and carry the real values (claims render as pretty JSON).
    expect(
      find.descendant(
        of: find.byKey(const Key('inspector-raw-token')),
        matching: find.textContaining(token),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('inspector-authorization-header')),
        matching: find.textContaining('Authorization: Bearer $token'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('RS256'), findsOneWidget);
    expect(find.textContaining('2026-10-key'), findsOneWidget);
    expect(find.textContaining('user-123'), findsOneWidget);
    expect(find.textContaining('https://api.clubins.de'), findsOneWidget);
  });

  testWidgets('copies the token and the header value on tap',
      (tester) async {
    final token = makeJwt({'alg': 'RS256'}, {'sub': 'user-123'});
    await _pumpInspector(tester, token);

    await tester.tap(find.byKey(const Key('copy-access-token')));
    await tester.pumpAndSettle();
    expect(clipboardText, token);
    expect(find.text('Access token copied to clipboard'), findsOneWidget);

    await tester.tap(find.byKey(const Key('copy-authorization-header')));
    await tester.pumpAndSettle();
    expect(clipboardText, 'Bearer $token');
    expect(
      find.text('Authorization header copied to clipboard'),
      findsOneWidget,
    );
  });

  testWidgets('explains an unreadable token instead of crashing',
      (tester) async {
    await _pumpInspector(tester, 'not-a-jwt');

    expect(find.text('Token unavailable'), findsOneWidget);
    expect(find.textContaining('dot-separated'), findsOneWidget);
    expect(find.text('Header claims (JOSE)'), findsNothing);
  });

  testWidgets('explains a missing token', (tester) async {
    await _pumpInspector(tester, null);

    expect(find.text('Token unavailable'), findsOneWidget);
    expect(find.textContaining('No access token available'), findsOneWidget);
  });
}
