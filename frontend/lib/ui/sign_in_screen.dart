import 'package:flutter/material.dart';

import '../auth/auth.dart';
import 'widgets.dart';

/// Signed-out entry: opens the Logto hosted sign-in (authorization code +
/// PKCE). Auth state flows through [AuthService.authStateChanges], so the
/// screen only triggers sign-in and surfaces failures — the gate swaps
/// this view for the venues home the moment the user lands.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _signingIn = false;

  Future<void> _signIn() async {
    setState(() => _signingIn = true);
    try {
      await widget.authService.signIn();
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      showSnackBar(context, e.message);
    } finally {
      if (mounted) {
        setState(() => _signingIn = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.storefront,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Clubins',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Venue insights for owners, staff, and renters.\n'
                'Sign in through the Clubins login to continue.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('sign-in-button'),
                onPressed: _signingIn ? null : _signIn,
                icon: _signingIn
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(_signingIn ? 'Signing in…' : 'Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
