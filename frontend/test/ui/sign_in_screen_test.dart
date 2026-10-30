import 'dart:async';

import 'package:clubins_frontend/auth/auth_service.dart';
import 'package:clubins_frontend/ui/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_auth.dart';
import '../widgets.dart';

void main() {
  testWidgets('opens the hosted sign-in on tap and shows progress',
      (tester) async {
    final auth = FakeAuthService(signInGate: Completer<void>());
    await pumpScreen(tester, SignInScreen(authService: auth));

    await tester.tap(find.byKey(const Key('sign-in-button')));
    await tester.pump();

    expect(auth.signInCalls, 1);
    expect(find.text('Signing in…'), findsOneWidget);
  });

  testWidgets(
      'surfaces a sign-in failure as a SnackBar and restores the button',
      (tester) async {
    final auth = FakeAuthService(signInError: AuthException('popup blocked'));
    await pumpScreen(tester, SignInScreen(authService: auth));

    await tester.tap(find.byKey(const Key('sign-in-button')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('popup blocked'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-button')), findsOneWidget);
  });
}
