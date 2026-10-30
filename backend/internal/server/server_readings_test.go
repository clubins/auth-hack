package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/clubins/auth-hack/backend/internal/config"
	"github.com/clubins/auth-hack/backend/internal/grants"
	"github.com/clubins/auth-hack/backend/internal/venues"
)

// doJSON sends a request against srv and returns status, raw body, and
// headers. An empty authorization omits the header.
func doJSON(t *testing.T, srv *httptest.Server, method, target, authorization, body string) (int, []byte, http.Header) {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+target, strings.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return resp.StatusCode, raw, resp.Header
}

// asJSONObject decodes a JSON-object response body.
func asJSONObject(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode body %s: %v", raw, err)
	}
	return out
}

// seedReadingsJSON is the expected readings body for one seed venue,
// round-tripped through JSON the way a client sees it.
func seedReadingsJSON(t *testing.T, venueID string) any {
	t.Helper()
	var rs []venues.Reading
	for _, r := range venues.DefaultReadingsSeed() {
		if r.VenueID == venueID {
			rs = append(rs, r)
		}
	}
	b, err := json.Marshal(rs)
	if err != nil {
		t.Fatalf("marshal readings: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal readings: %v", err)
	}
	return out
}

// TestReadingsCredentialComposition runs the composed guarded stack and
// pins the readings route's credential rules — the same dual-credential
// surface as the venue read: a grant token scoped to the venue OR a
// venue-read-scoped Logto token; no other credential gets in.
func TestReadingsCredentialComposition(t *testing.T) {
	guard, mint := newTestGuard(t)

	now := time.Now().UTC()
	revokedAt := now.Add(-time.Minute)
	seedGrants := []grants.Grant{
		{ID: "g-active", VenueID: "v-001", Subject: "renter-1", Token: grantSeedToken("active"),
			ExpiresAt: now.Add(grants.MaxTTL), CreatedAt: now},
		{ID: "g-expired", VenueID: "v-001", Subject: "renter-1", Token: grantSeedToken("expired"),
			ExpiresAt: now.Add(-time.Hour), CreatedAt: now.Add(-9 * time.Hour)},
		{ID: "g-revoked", VenueID: "v-001", Subject: "renter-1", Token: grantSeedToken("revoked"),
			ExpiresAt: now.Add(grants.MaxTTL), CreatedAt: now, RevokedAt: &revokedAt},
		{ID: "g-other", VenueID: "v-002", Subject: "renter-2", Token: grantSeedToken("other"),
			ExpiresAt: now.Add(grants.MaxTTL), CreatedAt: now},
	}
	grantStore := grants.NewMemStore()
	for _, g := range seedGrants {
		if _, err := grantStore.Create(context.Background(), g); err != nil {
			t.Fatalf("seed %s: %v", g.ID, err)
		}
	}

	srv := httptest.NewServer(New(Options{
		Guard:         guard,
		Store:         venues.NewMemStore(venues.DefaultSeed()),
		ReadingsStore: venues.NewReadingsMemStore(venues.DefaultReadingsSeed()),
		GrantStore:    grantStore,
	}))
	t.Cleanup(srv.Close)

	t.Run("a valid grant token reads its venue's readings", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+grantSeedToken("active"), "")
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body %s)", status, raw)
		}
		var got, want any
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatalf("decode body %s: %v", raw, err)
		}
		if want = seedReadingsJSON(t, "v-001"); string(mustJSON(t, got)) != string(mustJSON(t, want)) {
			t.Fatalf("body = %s, want %s", mustJSON(t, got), mustJSON(t, want))
		}
	})

	t.Run("a grant token for another venue is forbidden", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+grantSeedToken("other"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", status)
		}
		if body["error"] != "grant is not valid for this venue" {
			t.Fatalf("error = %v, want grant is not valid for this venue", body["error"])
		}
	})

	t.Run("an expired grant token is forbidden", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+grantSeedToken("expired"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", status)
		}
		if body["error"] != "grant expired" {
			t.Fatalf("error = %v, want grant expired", body["error"])
		}
	})

	t.Run("a revoked grant token is gone", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+grantSeedToken("revoked"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusGone {
			t.Fatalf("status = %d, want 410", status)
		}
		if body["error"] != "grant revoked" {
			t.Fatalf("error = %v, want grant revoked", body["error"])
		}
	})

	t.Run("no token is unauthorized by the OIDC guard", func(t *testing.T) {
		status, _, header := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "", "")
		if status != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", status)
		}
		if challenge := header.Get("WWW-Authenticate"); !strings.HasPrefix(challenge, "Bearer") {
			t.Fatalf("WWW-Authenticate = %q, want a Bearer challenge", challenge)
		}
	})

	t.Run("a venue-read-scoped OIDC token reads the readings", func(t *testing.T) {
		token := mint("user-1", config.VenueReadScope)
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+token, "")
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body %s)", status, raw)
		}
		var got any
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatalf("decode body %s: %v", raw, err)
		}
		if want := seedReadingsJSON(t, "v-001"); string(mustJSON(t, got)) != string(mustJSON(t, want)) {
			t.Fatalf("body = %s, want %s", mustJSON(t, got), mustJSON(t, want))
		}
	})

	t.Run("a venues:write-only OIDC token is forbidden — readings have no write path", func(t *testing.T) {
		token := mint("staff-1", config.VenueWriteScope)
		status, raw, header := doJSON(t, srv, http.MethodGet, "/venues/v-001/readings", "Bearer "+token, "")
		body := asJSONObject(t, raw)
		if status != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", status)
		}
		if body["error"] != "forbidden" {
			t.Fatalf("error = %v, want forbidden", body["error"])
		}
		if challenge := header.Get("WWW-Authenticate"); !strings.HasPrefix(challenge, "Bearer") {
			t.Fatalf("WWW-Authenticate = %q, want a Bearer challenge", challenge)
		}
	})

	t.Run("readings for an unknown venue are a json 404", func(t *testing.T) {
		token := mint("user-1", config.VenueReadScope)
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/nope/readings", "Bearer "+token, "")
		body := asJSONObject(t, raw)
		if status != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", status)
		}
		if body["error"] != "venue not found" {
			t.Fatalf("error = %v, want venue not found", body["error"])
		}
	})
}

// mustJSON marshals v for test comparisons.
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
