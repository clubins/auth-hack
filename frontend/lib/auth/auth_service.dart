/// The app-facing authentication surface, decoupled from the issuer SDK.
///
/// Implemented by [OidcAuthService] (oidc package + Logto); faked in widget
/// tests so no platform channel or network is involved.
library;

/// A signed-in user, reduced to what the app may rely on: the subject
/// (`sub` claim) and the full ID-token claim set.
class AuthUser {
  const AuthUser({required this.subject, required this.claims});

  /// The `sub` claim — the stable identity of the user at the issuer.
  final String subject;

  /// Every ID-token claim (aud, exp, email, ...).
  final Map<String, dynamic> claims;
}

/// Thrown when an authentication operation fails. [cause] preserves the
/// underlying error for logging and debugging.
class AuthException implements Exception {
  AuthException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'AuthException: $message (cause: $cause)';
}

abstract interface class AuthService {
  /// Restores a cached session (if any) and pins the issuer's discovery
  /// document. Call once at startup. Throws [AuthException] when the
  /// provider cannot be reached or validates wrong.
  Future<void> init();

  /// The currently signed-in user, or null when signed out.
  AuthUser? get currentUser;

  /// Replays the current user on listen, then emits every change.
  /// Null means signed out.
  Stream<AuthUser?> get authStateChanges;

  /// Opens the provider's hosted sign-in (authorization code + PKCE) and
  /// completes when the redirect lands back in the app.
  Future<void> signIn();

  /// Revokes tokens (best effort), ends the provider session, and clears
  /// local state. A no-op when already signed out.
  Future<void> signOut();

  /// An access token guaranteed fresh for at least ~30s, refreshing first
  /// when needed. Returns null when signed out; throws [AuthException] when
  /// the session cannot be refreshed silently.
  Future<String?> freshAccessToken();
}
