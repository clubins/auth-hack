package grants

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

// do sends a request and decodes the JSON response body.
func do(t *testing.T, srv *httptest.Server, r *http.Request) (int, http.Header, any) {
	t.Helper()
	resp, err := srv.Client().Do(r)
	if err != nil {
		t.Fatalf("%s %s: %v", r.Method, r.URL, err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	var body any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		body = nil
	}
	return resp.StatusCode, resp.Header, body
}

// withAuthServer returns a test server whose mux injects a principal into
// every request's context server-side, the way the future OIDC guard
// middleware will. Context values do not cross the wire, so client-side
// WithPrincipal cannot reach a handler through httptest.
func withAuthServer(store Store, p Principal) *httptest.Server {
	mux := http.NewServeMux()
	NewHandler(store, nil).Register(mux)
	var h http.Handler = mux
	if p != nil {
		h = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			mux.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
		})
	}
	return httptest.NewServer(h)
}

func TestHandlerCreateGrant(t *testing.T) {
	srvs := map[bool]*httptest.Server{
		true:  withAuthServer(NewMemStore(), stubPrincipal{sub: "renter-1"}),
		false: withAuthServer(NewMemStore(), nil),
	}
	t.Cleanup(func() { srvs[true].Close(); srvs[false].Close() })

	tests := []struct {
		name        string
		body        string
		principaled bool
		wantStatus  int
		wantErr     string
	}{
		{
			name:        "creates a grant with explicit ttl",
			body:        `{"ttl":"8h"}`,
			principaled: true,
			wantStatus:  http.StatusCreated,
		},
		{
			name:        "empty body gets the default ttl",
			body:        "",
			principaled: true,
			wantStatus:  http.StatusCreated,
		},
		{
			name:       "no principal is unauthorized",
			body:       `{"ttl":"8h"}`,
			wantStatus: http.StatusUnauthorized,
			wantErr:    "authentication required",
		},
		{
			name:        "ttl below the minimum is unprocessable",
			body:        `{"ttl":"7h"}`,
			principaled: true,
			wantStatus:  http.StatusUnprocessableEntity,
			wantErr:     "ttl out of bounds",
		},
		{
			name:        "ttl above the maximum is unprocessable",
			body:        `{"ttl":"25h"}`,
			principaled: true,
			wantStatus:  http.StatusUnprocessableEntity,
			wantErr:     "ttl out of bounds",
		},
		{
			name:        "unparseable ttl is a bad request",
			body:        `{"ttl":"soon"}`,
			principaled: true,
			wantStatus:  http.StatusBadRequest,
			wantErr:     "ttl must be a duration string",
		},
		{
			name:        "unknown fields are rejected",
			body:        `{"tll":"8h"}`,
			principaled: true,
			wantStatus:  http.StatusBadRequest,
			wantErr:     "invalid request body",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPost, srvs[tt.principaled].URL+"/venues/v-001/grants", strings.NewReader(tt.body))
			if err != nil {
				t.Fatalf("build request: %v", err)
			}

			status, header, body := do(t, srvs[tt.principaled], req)
			if status != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %v)", status, tt.wantStatus, body)
			}
			if tt.wantErr != "" {
				if !strings.Contains(jsonOf(t, body), tt.wantErr) {
					t.Fatalf("error body = %v, want it to contain %q", body, tt.wantErr)
				}
				return
			}

			got, ok := body.(map[string]any)
			if !ok {
				t.Fatalf("body = %v, want a grant object", body)
			}
			if got["venueId"] != "v-001" || got["subject"] != "renter-1" {
				t.Fatalf("grant = %v, want venueId v-001 subject renter-1", got)
			}
			if token, _ := got["token"].(string); len(token) != 64 {
				t.Fatalf("token = %q, want 64 hex chars", token)
			}
			created, err := time.Parse(time.RFC3339, got["createdAt"].(string))
			if err != nil {
				t.Fatalf("parse createdAt: %v", err)
			}
			expires, err := time.Parse(time.RFC3339, got["expiresAt"].(string))
			if err != nil {
				t.Fatalf("parse expiresAt: %v", err)
			}
			if ttl := expires.Sub(created); ttl < MinTTL || ttl > MaxTTL {
				t.Fatalf("ttl = %s, want within [%s, %s]", ttl, MinTTL, MaxTTL)
			}
			if loc := header.Get("Location"); !strings.HasPrefix(loc, "/grants/g-") {
				t.Fatalf("Location = %q, want /grants/g-…", loc)
			}
		})
	}
}

// jsonOf marshals a decoded body back to a string for substring checks.
func jsonOf(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

func TestHandlerListGrants(t *testing.T) {
	store := NewMemStore()
	svc := NewService(store)
	for _, in := range []CreateInput{
		{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL},
		{VenueID: "v-001", Subject: "renter-2", TTL: MinTTL},
		{VenueID: "v-002", Subject: "renter-1", TTL: MinTTL},
	} {
		if _, err := svc.Create(context.Background(), in, base); err != nil {
			t.Fatalf("Create(%+v): %v", in, err)
		}
	}

	srv := httptest.NewServer(func() http.Handler {
		mux := http.NewServeMux()
		NewHandler(store, nil).Register(mux)
		return mux
	}())
	t.Cleanup(srv.Close)

	status, _, body := do(t, srv, mustReq(t, http.MethodGet, srv.URL+"/venues/v-001/grants", ""))
	if status != http.StatusOK {
		t.Fatalf("status = %d, want %d", status, http.StatusOK)
	}
	got, ok := body.([]any)
	if !ok {
		t.Fatalf("body = %v, want a grant array", body)
	}
	if len(got) != 2 {
		t.Fatalf("listed %d grants, want the 2 for v-001", len(got))
	}
	for _, g := range got {
		if got := g.(map[string]any)["venueId"]; got != "v-001" {
			t.Fatalf("list leaked a grant for venue %v", got)
		}
	}

	// An empty list must render as [], not null.
	status, _, body = do(t, srv, mustReq(t, http.MethodGet, srv.URL+"/venues/v-003/grants", ""))
	if status != http.StatusOK {
		t.Fatalf("status = %d, want %d", status, http.StatusOK)
	}
	if got := jsonOf(t, body); got != "[]" {
		t.Fatalf("empty list body = %s, want []", got)
	}
}

func TestHandlerRevokeGrant(t *testing.T) {
	store := NewMemStore()
	svc := NewService(store)
	g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL}, base)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	srv := httptest.NewServer(func() http.Handler {
		mux := http.NewServeMux()
		NewHandler(store, nil).Register(mux)
		return mux
	}())
	t.Cleanup(srv.Close)

	t.Run("unknown id is 404", func(t *testing.T) {
		status, _, body := do(t, srv, mustReq(t, http.MethodDelete, srv.URL+"/grants/nope", ""))
		if status != http.StatusNotFound {
			t.Fatalf("status = %d, want %d", status, http.StatusNotFound)
		}
		if !reflect.DeepEqual(body, map[string]any{"error": "grant not found"}) {
			t.Fatalf("body = %v, want grant not found", body)
		}
	})

	t.Run("revoke stamps and returns the grant", func(t *testing.T) {
		status, _, body := do(t, srv, mustReq(t, http.MethodDelete, srv.URL+"/grants/"+g.ID, ""))
		if status != http.StatusOK {
			t.Fatalf("status = %d, want %d", status, http.StatusOK)
		}
		got, ok := body.(map[string]any)
		if !ok || got["revokedAt"] == nil {
			t.Fatalf("body = %v, want revokedAt set", body)
		}
	})

	t.Run("second revoke is idempotent", func(t *testing.T) {
		status, _, _ := do(t, srv, mustReq(t, http.MethodDelete, srv.URL+"/grants/"+g.ID, ""))
		if status != http.StatusOK {
			t.Fatalf("status = %d, want %d", status, http.StatusOK)
		}
	})

	t.Run("revoked grant no longer resolves", func(t *testing.T) {
		if _, err := svc.Resolve(context.Background(), g.Token, base); !errors.Is(err, ErrRevoked) {
			t.Fatalf("Resolve(revoked) error = %v, want ErrRevoked", err)
		}
	})
}

func mustReq(t *testing.T, method, target, body string) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, target, strings.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	return req
}

// seedToken builds a test token. Assigning token-shaped literals straight
// into Grant.Token trips gosec G101 even though these strings only exist in
// this test file.
func seedToken(s string) string { return "token-" + s }

// TestVenueReadGuard pins the venue-read guard's per-request decision:
// which requests it answers (and with which status), and which it declines
// so the server's OIDC credential path handles them. The venue handler is
// a stub that records the request, making the grant-subject injection
// observable without the server wiring; the full composed stack is covered
// by the server package's integration tests.
func TestVenueReadGuard(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	store := NewMemStore()

	// Grants built at store level so their timestamps can be pinned: the
	// service rejects sub-8h TTLs, but the guard must still map expiry.
	active := Grant{ID: "g-active", VenueID: "v-001", Subject: "renter-1", Token: seedToken("active-v001"),
		ExpiresAt: now.Add(MaxTTL), CreatedAt: now}
	expired := Grant{ID: "g-expired", VenueID: "v-001", Subject: "renter-1", Token: seedToken("expired"),
		ExpiresAt: now.Add(-time.Hour), CreatedAt: now.Add(-9 * time.Hour)}
	revokedAt := now.Add(-time.Minute)
	revoked := Grant{ID: "g-revoked", VenueID: "v-001", Subject: "renter-1", Token: seedToken("revoked"),
		ExpiresAt: now.Add(MaxTTL), CreatedAt: now, RevokedAt: &revokedAt}
	for _, g := range []Grant{active, expired, revoked} {
		if _, err := store.Create(ctx, g); err != nil {
			t.Fatalf("seed %s: %v", g.ID, err)
		}
	}

	gh := NewHandler(store, nil)
	var served *http.Request
	venueRead := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served = r
		w.WriteHeader(http.StatusOK)
	})
	guard := NewVenueReadGuard(gh, venueRead, nil)

	tests := []struct {
		name        string
		target      string
		auth        string // full Authorization header value; empty means none
		wantHandled bool
		wantStatus  int    // asserted only when wantHandled
		wantSubject string // asserted on the served request when set
	}{
		{
			name:        "active grant reads its own venue with the grant subject",
			target:      "/venues/v-001",
			auth:        "Bearer " + seedToken("active-v001"),
			wantHandled: true,
			wantStatus:  http.StatusOK,
			wantSubject: "renter-1",
		},
		{
			name:        "active grant cannot read another venue",
			target:      "/venues/v-002",
			auth:        "Bearer " + seedToken("active-v001"),
			wantHandled: true,
			wantStatus:  http.StatusForbidden,
		},
		{
			name:        "expired grant is forbidden",
			target:      "/venues/v-001",
			auth:        "Bearer " + seedToken("expired"),
			wantHandled: true,
			wantStatus:  http.StatusForbidden,
		},
		{
			name:        "revoked grant is gone",
			target:      "/venues/v-001",
			auth:        "Bearer " + seedToken("revoked"),
			wantHandled: true,
			wantStatus:  http.StatusGone,
		},
		{
			name:        "unknown token is not handled so the OIDC path can own it",
			target:      "/venues/v-001",
			auth:        "Bearer token-never-issued",
			wantHandled: false,
		},
		{
			name:        "no credential is not handled",
			target:      "/venues/v-001",
			wantHandled: false,
		},
		{
			name:        "non-bearer credential is not handled",
			target:      "/venues/v-001",
			auth:        "Basic dXNlcjpwYXNz",
			wantHandled: false,
		},
		{
			name:        "grant routes are not the venue-read route",
			target:      "/venues/v-003/grants",
			auth:        "Bearer " + seedToken("active-v001"),
			wantHandled: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tt.target, nil)
			if tt.auth != "" {
				req.Header.Set("Authorization", tt.auth)
			}
			served = nil
			rr := httptest.NewRecorder()

			handled := guard.HandleGrant(rr, req)

			if handled != tt.wantHandled {
				t.Fatalf("handled = %v, want %v (status %d)", handled, tt.wantHandled, rr.Code)
			}
			if !tt.wantHandled {
				return
			}
			if rr.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", rr.Code, tt.wantStatus, rr.Body.String())
			}
			if tt.wantSubject != "" {
				if served == nil {
					t.Fatal("venue read was never served")
				}
				p := PrincipalFrom(served.Context())
				if p == nil {
					t.Fatal("served request carries no principal")
				}
				if p.Subject() != tt.wantSubject {
					t.Fatalf("principal subject = %q, want %q", p.Subject(), tt.wantSubject)
				}
			}
		})
	}
}
