import 'dart:async';

import 'package:flutter/material.dart';

import 'api/api.dart';
import 'auth/auth.dart';
import 'ui/ui.dart';

void main() {
  final authService = OidcAuthService.fromConfig(AuthConfig.fromEnvironment());
  runApp(
    ClubinsApp(
      authService: authService,
      venuesApi: HttpVenuesApi(
        ApiClient(
          baseUrl: ApiConfig.fromEnvironment().baseUrl,
          // freshAccessToken refreshes silently when the token is stale.
          tokenProvider: authService.freshAccessToken,
        ),
      ),
    ),
  );
}

/// App shell: restores the session, then renders the sign-in entry or the
/// venues home. Screens take their collaborators by constructor — this is
/// the only wiring point.
class ClubinsApp extends StatelessWidget {
  const ClubinsApp({
    super.key,
    required this.authService,
    required this.venuesApi,
  });

  final AuthService authService;
  final VenuesApi venuesApi;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clubins',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: AuthGate(authService: authService, venuesApi: venuesApi),
    );
  }
}

/// Restores the cached session at startup, then renders one of four
/// states: initializing, init error, signed out, signed in.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authService,
    required this.venuesApi,
  });

  final AuthService authService;
  final VenuesApi venuesApi;

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
    if (oldWidget.authService != widget.authService ||
        oldWidget.venuesApi != widget.venuesApi) {
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

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _InitPhase.initializing => const LoadingView(
          label: 'Connecting to login.clubins.de…',
        ),
      _InitPhase.failed => ErrorRetryView(
          title: 'Authentication failed to start',
          message: '$_initError',
          onRetry: _retryInit,
        ),
      _InitPhase.ready => StreamBuilder<AuthUser?>(
          stream: widget.authService.authStateChanges,
          builder: (context, snapshot) {
            // The stream replays the current user on listen; fall back to
            // it while the first event is still in flight so a restored
            // session never flashes the sign-in screen for a frame.
            final user = snapshot.data ?? widget.authService.currentUser;
            if (user == null) {
              return SignInScreen(authService: widget.authService);
            }
            return HomeScreen(
              authService: widget.authService,
              venuesApi: widget.venuesApi,
              user: user,
            );
          },
        ),
    };
  }
}
