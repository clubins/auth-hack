import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/auth.dart';

void main() {
  runApp(
    ClubinsApp(
      authService: OidcAuthService.fromConfig(AuthConfig.fromEnvironment()),
    ),
  );
}

/// Placeholder app shell — real OIDC sign-in screen, token inspector and the
/// venues UI land in a later UI task.
class ClubinsApp extends StatelessWidget {
  const ClubinsApp({super.key, required this.authService});

  final AuthService authService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clubins',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: AuthGate(authService: authService),
    );
  }
}

/// Restores the cached session at startup, then renders one of four
/// placeholder states: initializing, init error, signed out, signed in.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authService});

  final AuthService authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _InitPhase { initializing, ready, failed }

class _AuthGateState extends State<AuthGate> {
  _InitPhase _phase = _InitPhase.initializing;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void didUpdateWidget(AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authService != widget.authService) {
      unawaited(_init());
    }
  }

  /// Runs init with explicit phase handling — a bare FutureBuilder can
  /// race an erroring future past its listener attachment and surface an
  /// unhandled zone error.
  Future<void> _init() async {
    if (_phase != _InitPhase.initializing) {
      setState(() => _phase = _InitPhase.initializing);
    }
    try {
      await widget.authService.init();
      if (!mounted) {
        return;
      }
      setState(() => _phase = _InitPhase.ready);
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _InitPhase.failed;
        _initError = e;
      });
    }
  }

  void _retryInit() {
    unawaited(_init());
  }

  Future<void> _handleSignIn() async {
    try {
      await widget.authService.signIn();
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _handleSignOut() async {
    try {
      await widget.authService.signOut();
    } on AuthException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _InitPhase.initializing => const _MessagePlaceholder(
          label: 'Connecting to login.clubins.de…',
        ),
      _InitPhase.failed => _ErrorPlaceholder(
          error: _initError!,
          onRetry: _retryInit,
        ),
      _InitPhase.ready => StreamBuilder<AuthUser?>(
          stream: widget.authService.authStateChanges,
          builder: (context, snapshot) {
            final user = snapshot.data;
            if (user == null) {
              return _SignedOutPlaceholder(onSignIn: _handleSignIn);
            }
            return _SignedInPlaceholder(
              user: user,
              onSignOut: _handleSignOut,
            );
          },
        ),
    };
  }
}

class _MessagePlaceholder extends StatelessWidget {
  const _MessagePlaceholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline),
              const SizedBox(height: 12),
              const Text('Authentication failed to start'),
              const SizedBox(height: 8),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedOutPlaceholder extends StatelessWidget {
  const _SignedOutPlaceholder({required this.onSignIn});

  final Future<void> Function() onSignIn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Clubins auth reference'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onSignIn,
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignedInPlaceholder extends StatelessWidget {
  const _SignedInPlaceholder({required this.user, required this.onSignOut});

  final AuthUser user;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Signed in as ${user.subject}'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
