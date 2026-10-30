package server

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/clubins/auth-hack/backend/internal/auth"
	"github.com/clubins/auth-hack/backend/internal/config"
	"github.com/clubins/auth-hack/backend/internal/grants"
	"github.com/clubins/auth-hack/backend/internal/venues"
)

// grantSeedToken builds the opaque token for a seeded grant. Assigning
// token-shaped literals straight into Grant.Token trips gosec G101 even
// though these strings only exist in this test file.
func grantSeedToken(s string) string { return "grant-" + s }

// newTestGuard builds an auth.Guard backed by a throwaway RSA key and a
// JWKS endpoint serving it; mint in the returned function signs access
// tokens those endpoints verify.
func newTestGuard(t *testing.T) (*auth.Guard, func(sub, scope string) string) {
	t.Helper()
	const (
		issuer   = "https://issuer.test"
		audience = "https://api.clubins.de"
	)

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]string{{
				"kty": "RSA",
				"kid": "k1",
				"alg": "RS256",
				"use": "sig",
				"n":   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
			}},
		}); err != nil {
			t.Errorf("encode jwks: %v", err)
		}
	}))
	t.Cleanup(jwks.Close)

	verifier, err := auth.NewTokenVerifier(context.Background(), auth.VerifierConfig{
		IssuerURL:    issuer,
		Audience:     audience,
		JWKSURL:      jwks.URL, // pinned: skips OIDC discovery
		JWKSCacheTTL: time.Hour,
	})
	if err != nil {
		t.Fatalf("build verifier: %v", err)
	}
	guard, err := auth.NewGuard(auth.GuardOptions{Verifier: verifier})
	if err != nil {
		t.Fatalf("build guard: %v", err)
	}

	mint := func(sub, scope string) string {
		t.Helper()
		return signTestJWT(t, "k1", key, map[string]any{
			"iss":   issuer,
			"aud":   audience,
			"sub":   sub,
			"scope": scope,
			"exp":   time.Now().Add(5 * time.Minute).Unix(),
			"nbf":   time.Now().Add(-time.Minute).Unix(),
		})
	}
	return guard, mint
}

// TestGrantsCredentialComposition runs the composed guarded stack and pins
// the credential rules from the server package comment: the venue read
// accepts a grant token OR a venue-read-scoped OIDC token, grant management
// demands OIDC with the right scope, and /healthz stays public.
func TestGrantsCredentialComposition(t *testing.T) {
	ctx := context.Background()
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
		if _, err := grantStore.Create(ctx, g); err != nil {
			t.Fatalf("seed %s: %v", g.ID, err)
		}
	}

	srv := httptest.NewServer(New(Options{
		Guard:      guard,
		Store:      venues.NewMemStore(venues.DefaultSeed()),
		GrantStore: grantStore,
	}))
	t.Cleanup(srv.Close)

	t.Run("venue read with a valid grant token serves the venue", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001", "Bearer "+grantSeedToken("active"), "")
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body %s)", status, raw)
		}
		want := seedVenueJSON(t, "v-001")
		have := asJSONObject(t, raw)
		if !reflect.DeepEqual(have, want) {
			t.Fatalf("body = %s, want %v", raw, want)
		}
	})

	t.Run("expired grant token is forbidden", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001", "Bearer "+grantSeedToken("expired"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", status)
		}
		if body["error"] != "grant expired" {
			t.Fatalf("error = %v, want grant expired", body["error"])
		}
	})

	t.Run("revoked grant token is gone", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001", "Bearer "+grantSeedToken("revoked"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusGone {
			t.Fatalf("status = %d, want 410", status)
		}
		if body["error"] != "grant revoked" {
			t.Fatalf("error = %v, want grant revoked", body["error"])
		}
	})

	t.Run("grant token for another venue is forbidden", func(t *testing.T) {
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001", "Bearer "+grantSeedToken("other"), "")
		body := asJSONObject(t, raw)
		if status != http.StatusForbidden {
			t.Fatalf("status = %d, want 403", status)
		}
		if body["error"] != "grant is not valid for this venue" {
			t.Fatalf("error = %v, want grant is not valid for this venue", body["error"])
		}
	})

	t.Run("venue read without any token is unauthorized by the OIDC guard", func(t *testing.T) {
		status, _, header := doJSON(t, srv, http.MethodGet, "/venues/v-001", "", "")
		if status != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", status)
		}
		if challenge := header.Get("WWW-Authenticate"); !strings.HasPrefix(challenge, "Bearer") {
			t.Fatalf("WWW-Authenticate = %q, want a Bearer challenge", challenge)
		}
	})

	t.Run("creating a grant with a venues:write token stamps the token subject", func(t *testing.T) {
		token := mint("staff-1", config.VenueWriteScope)
		status, raw, header := doJSON(t, srv, http.MethodPost, "/venues/v-001/grants", "Bearer "+token, `{}`)
		body := asJSONObject(t, raw)
		if status != http.StatusCreated {
			t.Fatalf("status = %d, want 201 (body %v)", status, body)
		}
		if body["subject"] != "staff-1" {
			t.Fatalf("subject = %v, want staff-1", body["subject"])
		}
		if location := header.Get("Location"); !strings.HasPrefix(location, "/grants/") {
			t.Fatalf("Location = %q, want a grant URL", location)
		}
		// The create response is the token's one-time delivery.
		if tok, _ := body["token"].(string); len(tok) != 64 {
			t.Fatalf("token = %q, want 64 hex chars", tok)
		}
	})

	t.Run("creating a grant without venues:write is forbidden", func(t *testing.T) {
		token := mint("staff-1", config.VenueReadScope)
		status, raw, header := doJSON(t, srv, http.MethodPost, "/venues/v-001/grants", "Bearer "+token, `{}`)
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

	t.Run("grant tokens never pass as OIDC credentials on management routes", func(t *testing.T) {
		token := grantSeedToken("active")
		for _, tc := range []struct{ method, target string }{
			{http.MethodPost, "/venues/v-001/grants"},
			{http.MethodGet, "/venues/v-001/grants"},
			{http.MethodDelete, "/grants/g-active"},
		} {
			status, raw, _ := doJSON(t, srv, tc.method, tc.target, "Bearer "+token, `{}`)
			if status != http.StatusUnauthorized {
				t.Fatalf("%s %s: status = %d, want 401 (body %s)", tc.method, tc.target, status, raw)
			}
		}
	})

	t.Run("grant list responses never carry renter tokens", func(t *testing.T) {
		token := mint("staff-1", config.VenueReadScope)
		status, raw, _ := doJSON(t, srv, http.MethodGet, "/venues/v-001/grants", "Bearer "+token, "")
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body %s)", status, raw)
		}
		if strings.Contains(string(raw), grantSeedToken("active")) {
			t.Fatalf("list leaks the grant token: %s", raw)
		}
	})

	t.Run("revoking a grant with a venues:write token stamps revocation", func(t *testing.T) {
		createToken := mint("staff-1", config.VenueWriteScope)
		status, raw, _ := doJSON(t, srv, http.MethodPost, "/venues/v-001/grants", "Bearer "+createToken, `{}`)
		body := asJSONObject(t, raw)
		if status != http.StatusCreated {
			t.Fatalf("create status = %d, want 201 (body %v)", status, body)
		}
		id, _ := body["id"].(string)
		// The create response is the only place the grant token is delivered.
		createdToken, _ := body["token"].(string)

		revokeToken := mint("staff-1", config.VenueWriteScope)
		status, raw, _ = doJSON(t, srv, http.MethodDelete, "/grants/"+id, "Bearer "+revokeToken, "")
		body = asJSONObject(t, raw)
		if status != http.StatusOK {
			t.Fatalf("revoke status = %d, want 200 (body %v)", status, body)
		}
		if body["revokedAt"] == nil {
			t.Fatal("revokedAt missing on revoked grant")
		}
		if _, hasToken := body["token"]; hasToken {
			t.Fatalf("revoke response leaks the token: %v", body)
		}

		// The revoked grant's token no longer authorizes a venue read.
		status, _, _ = doJSON(t, srv, http.MethodGet, "/venues/v-001", "Bearer "+createdToken, "")
		if status != http.StatusGone {
			t.Fatalf("revoked grant read status = %d, want 410", status)
		}
	})
}
