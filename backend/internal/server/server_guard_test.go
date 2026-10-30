package server

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/clubins/auth-hack/backend/internal/auth"
	"github.com/clubins/auth-hack/backend/internal/config"
	"github.com/clubins/auth-hack/backend/internal/venues"
)

// signTestJWT builds and signs an RS256 JWT the way an issuer would; the
// server test only needs one algorithm, so the helper stays minimal.
func signTestJWT(t *testing.T, kid string, key *rsa.PrivateKey, claims map[string]any) string {
	t.Helper()
	encode := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal segment: %v", err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signingInput := encode(map[string]string{"alg": "RS256", "kid": kid, "typ": "JWT"}) + "." + encode(claims)
	sum := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// seedVenueJSON is the expected body for one seed venue, round-tripped
// through JSON the way a client sees it.
func seedVenueJSON(t *testing.T, id string) any {
	t.Helper()
	for _, v := range venues.DefaultSeed() {
		if v.ID != id {
			continue
		}
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal venue: %v", err)
		}
		var out any
		if err := json.Unmarshal(b, &out); err != nil {
			t.Fatalf("unmarshal venue: %v", err)
		}
		return out
	}
	t.Fatalf("seed has no venue %q", id)
	return nil
}

// TestGuardedRoutes runs the full stack from server.New with a guard wired:
// the health check stays public while the venues surface demands a valid,
// in-scope Logto-style access token.
func TestGuardedRoutes(t *testing.T) {
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

	srv := httptest.NewServer(New(Options{Guard: guard, Store: venues.NewMemStore(venues.DefaultSeed())}))
	t.Cleanup(srv.Close)

	// mint returns a signed access token; mutate adjusts one claim.
	mint := func(mutate func(map[string]any)) string {
		t.Helper()
		claims := map[string]any{
			"iss":   issuer,
			"aud":   audience,
			"sub":   "user-1",
			"scope": config.VenueReadScope,
			"exp":   time.Now().Add(5 * time.Minute).Unix(),
			"nbf":   time.Now().Add(-time.Minute).Unix(),
		}
		if mutate != nil {
			mutate(claims)
		}
		return signTestJWT(t, "k1", key, claims)
	}

	tests := []struct {
		name          string
		target        string
		authorization func() string // "" omits the header
		wantStatus    int
		wantBody      any // decoded against the JSON response; nil skips body check
	}{
		{
			name:          "healthz stays public without a token",
			target:        "/healthz",
			authorization: func() string { return "" },
			wantStatus:    http.StatusOK,
			wantBody:      map[string]any{"status": "ok"},
		},
		{
			name:          "venues without a token is unauthorized",
			target:        "/venues",
			authorization: func() string { return "" },
			wantStatus:    http.StatusUnauthorized,
			wantBody:      map[string]any{"error": "unauthorized"},
		},
		{
			name:   "venues with an expired token is unauthorized",
			target: "/venues",
			authorization: func() string {
				return "Bearer " + mint(func(c map[string]any) { c["exp"] = time.Now().Add(-time.Minute).Unix() })
			},
			wantStatus: http.StatusUnauthorized,
			wantBody:   map[string]any{"error": "unauthorized"},
		},
		{
			name:          "venues with a token lacking the scope is forbidden",
			target:        "/venues",
			authorization: func() string { return "Bearer " + mint(func(c map[string]any) { delete(c, "scope") }) },
			wantStatus:    http.StatusForbidden,
			wantBody:      map[string]any{"error": "forbidden"},
		},
		{
			name:          "venues list with a valid token",
			target:        "/venues",
			authorization: func() string { return "Bearer " + mint(nil) },
			wantStatus:    http.StatusOK,
			wantBody:      venuesJSON(t),
		},
		{
			name:          "single venue with a valid token",
			target:        "/venues/v-001",
			authorization: func() string { return "Bearer " + mint(nil) },
			wantStatus:    http.StatusOK,
			wantBody:      seedVenueJSON(t, "v-001"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, srv.URL+tt.target, nil)
			if err != nil {
				t.Fatalf("build request: %v", err)
			}
			if header := tt.authorization(); header != "" {
				req.Header.Set("Authorization", header)
			}

			resp, err := srv.Client().Do(req)
			if err != nil {
				t.Fatalf("do request: %v", err)
			}
			t.Cleanup(func() { _ = resp.Body.Close() })

			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tt.wantStatus)
			}
			switch tt.wantStatus {
			case http.StatusUnauthorized, http.StatusForbidden:
				if got := resp.Header.Get("WWW-Authenticate"); !strings.HasPrefix(got, "Bearer") {
					t.Fatalf("WWW-Authenticate = %q, want a Bearer challenge", got)
				}
			}
			if tt.wantBody == nil {
				return
			}
			var got any
			if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if want, err := json.Marshal(tt.wantBody); err != nil {
				t.Fatalf("marshal want body: %v", err)
			} else if have, err := json.Marshal(got); err != nil {
				t.Fatalf("marshal got body: %v", err)
			} else if string(want) != string(have) {
				t.Fatalf("body = %s, want %s", have, want)
			}
		})
	}
}
