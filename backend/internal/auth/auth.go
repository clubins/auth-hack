// Package auth guards the API's protected routes with Logto-issued access
// tokens.
//
// The Guard middleware extracts a bearer token, verifies it against the
// issuer's signing keys (RS256/ES256 only — the algorithm is pinned before
// any key lookup, so "none" and HMAC tokens can never verify, including the
// HMAC-confusion trick of keying a token with a public key), and injects
// the authenticated Principal into the request context under the exported
// PrincipalContextKey. RequireScope declares, per route group, which OAuth
// scope the caller must hold.
//
// Failures follow RFC 6750: 401 with a WWW-Authenticate challenge (403 with
// error="insufficient_scope" when a valid token lacks the scope) and a JSON
// error body in the venues handler style. Challenge, body, and log reasons
// are fixed package strings — token contents, headers, and key ids are
// never echoed.
package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strings"
)

// Principal is the authenticated identity the Guard middleware injects into
// the request context. Later packages (grants) consume it to make
// per-resource decisions.
type Principal struct {
	// Subject is the token's "sub" claim: the Logto user or M2M app id.
	Subject string
	// Scopes are the granted scopes, split into individual values.
	Scopes []string
}

// HasScope reports whether the principal carries scope.
func (p Principal) HasScope(scope string) bool {
	return slices.Contains(p.Scopes, scope)
}

// principalKey is unexported so only this package can write to the context
// slot; readers go through PrincipalFromContext.
type principalKey struct{}

// PrincipalContextKey is the exported request-context key under which the
// Guard middleware stores the authenticated Principal.
var PrincipalContextKey = principalKey{}

// PrincipalFromContext returns the Principal the Guard middleware stored in
// ctx and whether one was present. Requests that did not pass the Guard
// carry no Principal.
func PrincipalFromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(PrincipalContextKey).(Principal)
	return p, ok
}

// authError is a guard rejection with its RFC 6750 response precomputed.
// Every string is a fixed package constant: nothing request-derived is ever
// echoed into a challenge, body, or log line.
type authError struct {
	status    int
	challenge string // WWW-Authenticate header value
	body      string // JSON "error" field, venues-handler style
	reason    string // fixed short string for the request log
	cause     error  // underlying error for logs only; never request data
}

// Request-shape rejections. Token-validation rejections come from
// classifyTokenError at runtime.
var (
	errNoAuthHeader = &authError{
		status:    http.StatusUnauthorized,
		challenge: "Bearer", // RFC 6750 §3.1: no error code when no auth was attempted
		body:      "unauthorized",
		reason:    "missing authorization header",
	}
	errMalformedHeader = &authError{
		status:    http.StatusUnauthorized,
		challenge: `Bearer error="invalid_request", error_description="malformed authorization header"`,
		body:      "unauthorized",
		reason:    "malformed authorization header",
	}
	errWrongScheme = &authError{
		status:    http.StatusUnauthorized,
		challenge: `Bearer error="invalid_request", error_description="bearer authorization required"`,
		body:      "unauthorized",
		reason:    "authorization scheme is not bearer",
	}
	errNoPrincipal = &authError{
		status:    http.StatusUnauthorized,
		challenge: "Bearer",
		body:      "unauthorized",
		reason:    "no principal in context (guard not chained)",
	}
)

// invalidToken rejects a token that failed verification. description is a
// fixed package string, never request data.
func invalidToken(description string) *authError {
	return &authError{
		status:    http.StatusUnauthorized,
		challenge: fmt.Sprintf(`Bearer error="invalid_token", error_description=%q`, description),
		body:      "unauthorized",
		reason:    description,
	}
}

// unavailable rejects a request because signing keys could not be fetched:
// verification is impossible, which is an API-side problem, not the
// client's.
func unavailable(err error) *authError {
	return &authError{
		status:    http.StatusServiceUnavailable,
		challenge: `Bearer error="temporarily_unavailable", error_description="token signing keys are unavailable"`,
		body:      "unavailable",
		reason:    "token signing keys are unavailable",
		cause:     err,
	}
}

// insufficientScope rejects an authenticated request that lacks scope.
func insufficientScope(scope string) *authError {
	return &authError{
		status:    http.StatusForbidden,
		challenge: fmt.Sprintf(`Bearer error="insufficient_scope", scope=%q, error_description="the request requires scope %s"`, scope, scope),
		body:      "forbidden",
		reason:    "missing required scope",
	}
}

// Guard authenticates requests by verifying bearer access tokens.
type Guard struct {
	verifier *TokenVerifier
	logger   *slog.Logger
}

// GuardOptions configures NewGuard.
type GuardOptions struct {
	// Verifier validates access tokens; required.
	Verifier *TokenVerifier
	// Logger receives guard rejections; nil falls back to slog.Default.
	Logger *slog.Logger
}

// NewGuard returns a Guard backed by opts.Verifier.
func NewGuard(opts GuardOptions) (*Guard, error) {
	if opts.Verifier == nil {
		return nil, errors.New("auth: guard requires a token verifier")
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	return &Guard{verifier: opts.Verifier, logger: opts.Logger}, nil
}

// Wrap returns next wrapped with bearer-token authentication: requests
// without a valid token are rejected before next runs, and admitted
// requests carry the Principal in their context.
func (g *Guard) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		principal, aerr := g.authenticate(r)
		if aerr != nil {
			attrs := []slog.Attr{
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.String("reason", aerr.reason),
			}
			if aerr.cause != nil {
				attrs = append(attrs, slog.Any("err", aerr.cause))
			}
			g.logger.LogAttrs(r.Context(), g.logLevel(aerr), "request rejected by auth guard", attrs...)
			writeAuthError(w, aerr)
			return
		}
		ctx := context.WithValue(r.Context(), PrincipalContextKey, principal)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// authenticate verifies the request's bearer token.
func (g *Guard) authenticate(r *http.Request) (Principal, *authError) {
	raw, aerr := bearerToken(r)
	if aerr != nil {
		return Principal{}, aerr
	}
	return g.verifier.verify(raw)
}

// logLevel keeps ordinary rejections quiet (the request log already shows
// the 401) but makes key-fetch outages, which look like API outages,
// visible.
func (g *Guard) logLevel(aerr *authError) slog.Level {
	if aerr.status >= http.StatusInternalServerError {
		return slog.LevelWarn
	}
	return slog.LevelDebug
}

// RequireScope returns middleware that admits requests whose authenticated
// Principal carries scope. Chain it inside Guard.Wrap: a request that
// reached this point without a Principal means the Guard was not chained,
// which is a wiring mistake — fail closed rather than serve it.
func RequireScope(scope string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := PrincipalFromContext(r.Context())
		switch {
		case !ok:
			writeAuthError(w, errNoPrincipal)
		case !p.HasScope(scope):
			writeAuthError(w, insufficientScope(scope))
		default:
			next.ServeHTTP(w, r)
		}
	})
}

// bearerToken extracts the bearer credential from the Authorization header.
// Multiple Authorization headers, non-bearer schemes, and multiple
// credentials are rejected rather than silently picking a value.
func bearerToken(r *http.Request) (string, *authError) {
	values := r.Header.Values("Authorization")
	if len(values) == 0 {
		return "", errNoAuthHeader
	}
	if len(values) > 1 {
		return "", errMalformedHeader
	}
	value := strings.TrimSpace(values[0])
	if value == "" {
		return "", errNoAuthHeader
	}
	scheme, rest, _ := strings.Cut(value, " ")
	if !strings.EqualFold(scheme, "Bearer") {
		return "", errWrongScheme
	}
	token := strings.TrimSpace(rest)
	// A JWT never contains whitespace: any here mean two credentials.
	if token == "" || strings.ContainsAny(token, " \t") {
		return "", errMalformedHeader
	}
	return token, nil
}

// writeAuthError sends the challenge and the JSON error body in the venues
// handler style: {"error": "<body>"}.
func writeAuthError(w http.ResponseWriter, aerr *authError) {
	w.Header().Set("WWW-Authenticate", aerr.challenge)
	b, err := json.Marshal(map[string]string{"error": aerr.body})
	if err != nil {
		// Marshaling fixed strings cannot fail; if it ever does, the status
		// alone beats a corrupt body.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(aerr.status)
	// A failed write here means the client disconnected after the status was
	// committed; the request log already records the aborted exchange.
	_, _ = w.Write(b)
}
