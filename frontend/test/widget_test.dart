import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_auth.dart';

const _user = AuthUser(
  subject: 'user-123',
  claims: {'sub': 'user-123', 'iss': 'https://login.clubins.de/oidc'},
);

void main() {
  testWidgets('renders the signed-out placeholder and wires sign-in',
      (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(ClubinsApp(authService: auth));
    await tester.pumpAndSettle();

    expect(find.text('Clubins auth reference'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    expect(auth.signInCalls, 1);
  });

  testWidgets('renders the signed-in placeholder with the subject claim',
      (tester) async {
    final auth = FakeAuthService(user: _user);
    await tester.pumpWidget(ClubinsApp(authService: auth));
    await tester.pumpAndSettle();

    expect(find.text('Signed in as user-123'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.text('Clubins auth reference'), findsOneWidget);
  });

  testWidgets('shows an error placeholder with retry when init fails',
      (tester) async {
    final auth = FakeAuthService(initError: AuthException('IdP unreachable'));
    await tester.pumpWidget(ClubinsApp(authService: auth));
    await tester.pumpAndSettle();

    expect(find.text('Authentication failed to start'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(auth.initCalls, 2);
  });

  testWidgets('follows the auth state stream to signed-in', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(ClubinsApp(authService: auth));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);

    auth.emitUser(_user);
    await tester.pumpAndSettle();

    expect(find.text('Signed in as user-123'), findsOneWidget);
  });
}
