// Package server wires the API's routes and middleware.
//
// Credential composition (when Options.Guard is set), documented here
// because it spans three packages:
//
//   - GET /healthz is public.
//   - GET /venues/{id} is the dual-credential surface: it accepts either a
//     renter grant token or a Logto bearer token carrying the venue read
//     scope. Grant tokens are resolved BEFORE the OIDC guard sees the
//     request — an opaque grant token could never verify as a Logto JWT,
//     so if the guard ran first it would 401 every grant holder. Tokens
//     that resolve to no grant (Logto JWTs among them) fall through to
//     the OIDC guard.
//   - Grant management is OIDC-only: venues:write to create or revoke,
//     venue-read to list. A grant token presented to a management route
//     fails OIDC verification and gets 401.
//   - Every other route requires a Logto bearer with the venue read scope.
//
// auth.Principal and grants.Principal are bridged in withGrantsPrincipal:
// the grants package stays dependency-free and only ever reads a subject.
package server

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/clubins/auth-hack/backend/internal/auth"
	"github.com/clubins/auth-hack/backend/internal/config"
	"github.com/clubins/auth-hack/backend/internal/grants"
	"github.com/clubins/auth-hack/backend/internal/venues"
)

// Options configures New.
type Options struct {
	// Logger receives request logs; nil falls back to slog.Default.
	Logger *slog.Logger
	// Store backs the venues routes; nil falls back to an empty MemStore.
	Store venues.Store
	// GrantStore backs the grants routes; nil falls back to an empty MemStore.
	GrantStore grants.Store
	// Guard authenticates the protected routes and injects the request
	// Principal; nil leaves them unauthenticated (local development,
	// tests without an IdP).
	Guard *auth.Guard
}

// New builds the API's root handler.
func New(opts Options) http.Handler {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.Store == nil {
		opts.Store = venues.NewMemStore(nil)
	}
	if opts.GrantStore == nil {
		opts.GrantStore = grants.NewMemStore()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)

	grantHandler := grants.NewHandler(opts.GrantStore, opts.Logger)

	if opts.Guard == nil {
		// Development and tests without an IdP: the same routes, none
		// guarded. Grant creation still demands a context principal, so
		// unguarded callers get the same 401 they would behind a guard
		// that injected nothing.
		venues.NewHandler(opts.Store, opts.Logger).Register(mux)
		grantHandler.Register(mux)
		return withRequestLogging(opts.Logger, mux)
	}
	return withRequestLogging(opts.Logger, guarded(mux, opts, grantHandler))
}

// guarded composes the OIDC guard with the grants surfaces; see the
// package comment for the credential rules.
func guarded(mux *http.ServeMux, opts Options, grantHandler *grants.Handler) http.Handler {
	guard := opts.Guard

	venueMux := http.NewServeMux()
	venues.NewHandler(opts.Store, opts.Logger).Register(venueMux)

	// Dual-credential venue read: grant tokens are resolved before the
	// OIDC guard can reject a non-Logto bearer.
	oidcVenueRead := guard.Wrap(withGrantsPrincipal(
		auth.RequireScope(config.VenueReadScope, venueMux)))
	readGuard := grants.NewVenueReadGuard(grantHandler, venueMux, opts.Logger)
	mux.Handle("GET /venues/{id}", handleVenueRead(readGuard, oidcVenueRead))

	// Venue list stays OIDC-only.
	mux.Handle("GET /venues", guard.Wrap(withGrantsPrincipal(
		auth.RequireScope(config.VenueReadScope, venueMux))))

	// Grant management: venues:write to create or revoke, venue-read to
	// list. Each scope group gets its own mux so the scope check and the
	// inner dispatch agree on exactly one route.
	grantWriteMux := http.NewServeMux()
	grantHandler.RegisterCreate(grantWriteMux)
	grantHandler.RegisterRevoke(grantWriteMux)
	mux.Handle("POST /venues/{id}/grants", guard.Wrap(withGrantsPrincipal(
		auth.RequireScope(config.VenueWriteScope, grantWriteMux))))
	mux.Handle("DELETE /grants/{id}", guard.Wrap(withGrantsPrincipal(
		auth.RequireScope(config.VenueWriteScope, grantWriteMux))))

	grantListMux := http.NewServeMux()
	grantHandler.RegisterList(grantListMux)
	mux.Handle("GET /venues/{id}/grants", guard.Wrap(withGrantsPrincipal(
		auth.RequireScope(config.VenueReadScope, grantListMux))))

	return mux
}

// withGrantsPrincipal bridges the OIDC principal into the grants package's
// context slot: grants handlers read their subject through grants.Principal
// without importing auth, keeping grants dependency-free. Requests without
// an OIDC principal (grant-token reads) pass through unchanged.
func withGrantsPrincipal(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p, ok := auth.PrincipalFromContext(r.Context()); ok {
			r = r.WithContext(grants.WithPrincipal(r.Context(), grants.NewPrincipal(p.Subject)))
		}
		next.ServeHTTP(w, r)
	})
}

// handleVenueRead forks the dual-credential venue read: a request the grant
// guard handled (served, or rejected as expired/revoked/venue-mismatched)
// stops there; everything else — no bearer header, or a token that resolves
// to no grant — falls through to the OIDC path.
func handleVenueRead(g *grants.VenueReadGuard, fallback http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if g.HandleGrant(w, r) {
			return
		}
		fallback.ServeHTTP(w, r)
	})
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{"status": "ok"}); err != nil {
		slog.Default().Error("write healthz response", slog.Any("err", err))
	}
}

// withRequestLogging logs method, path, status, and duration for every
// request. It deliberately never logs headers, query strings, or bodies, so
// bearer tokens and credentials cannot reach the log.
func withRequestLogging(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		logger.LogAttrs(r.Context(), slog.LevelInfo, "request",
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
			slog.Int("status", sw.status),
			slog.Duration("duration", time.Since(start)),
		)
	})
}

// statusWriter captures the response status for the request log.
type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusWriter) WriteHeader(code int) {
	if !w.wrote {
		w.status = code
		w.wrote = true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.status = http.StatusOK
		w.wrote = true
	}
	return w.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
