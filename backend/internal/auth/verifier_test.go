package auth

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestJWKSRotationOnUnknownKid covers the refresh-on-unknown-kid flow: a
// token under a key the cache has never seen triggers one refetch and is
// then accepted, while keys that vanished from the issuer stop working.
func TestJWKSRotationOnUnknownKid(t *testing.T) {
	idp := newStubIdP(t, rsaJWK("k1"))
	verifier := newTestVerifier(t, idp, nil)

	// A token signed by the boot-time key verifies.
	if _, aerr := verifier.verify(idp.mint(nil)); aerr != nil {
		t.Fatalf("verify boot-time token: %+v", aerr)
	}

	// Rotate: the issuer now serves a new key and no longer the old one.
	idp.setKeys(rsaJWK("k2"))

	// The new kid is not cached: the guard refetches and accepts.
	principal, aerr := verifier.verify(idp.mint(func(o *tokenOptions) { o.kid = "k2" }))
	if aerr != nil {
		t.Fatalf("verify rotated-key token: %+v", aerr)
	}
	if principal.Subject != "user-1" {
		t.Fatalf("subject = %q, want %q", principal.Subject, "user-1")
	}

	// The old kid vanished from the refreshed key set: tokens under it are
	// now rejected as unknown-key, not misclassified.
	if _, aerr := verifier.verify(idp.mint(nil)); aerr == nil || aerr.reason != "token signing key is unknown" {
		t.Fatalf("old key after rotation: aerr = %+v, want unknown signing key", aerr)
	}
}

// TestJWKSUnavailableReturnsUnavailable pins the failure semantics during
// an issuer outage: unknown keys surface as 503 (a temporary API problem),
// while still-cached keys keep verifying from stale cache.
func TestJWKSUnavailableReturnsUnavailable(t *testing.T) {
	idp := newStubIdP(t, rsaJWK("k1"))
	verifier := newTestVerifier(t, idp, nil)

	// Prime the cache while the issuer is up.
	if _, aerr := verifier.verify(idp.mint(nil)); aerr != nil {
		t.Fatalf("verify before outage: %+v", aerr)
	}

	// Age the cache out, then take the issuer down. With the TTL expired,
	// every lookup misses and the refetch fails — the stale fallback is
	// what keeps known keys working.
	verifier.keys.ttl = time.Nanosecond
	idp.setJWKSDown(true)

	// Unknown kid during the outage: the refetch fails, nothing is cached,
	// and the error classifies as service unavailable.
	ghost := idp.mint(func(o *tokenOptions) { o.kid = "ghost" })
	if _, aerr := verifier.verify(ghost); aerr == nil || aerr.status != http.StatusServiceUnavailable {
		t.Fatalf("unknown kid during outage: aerr = %+v, want 503", aerr)
	}

	// A known kid falls back to the stale cached key and still verifies.
	if _, aerr := verifier.verify(idp.mint(nil)); aerr != nil {
		t.Fatalf("known kid during outage: %+v", aerr)
	}
}

func TestNewTokenVerifierDiscovery(t *testing.T) {
	t.Run("issuer mismatch refuses to boot", func(t *testing.T) {
		idp := newStubIdP(t, rsaJWK("k1"))
		idp.setDiscoveryIssuer("https://evil.example")
		if _, err := NewTokenVerifier(context.Background(), VerifierConfig{
			IssuerURL:    idp.base,
			Audience:     testAudience,
			JWKSCacheTTL: time.Hour,
		}); err == nil {
			t.Fatal("discovery issuer mismatch must abort boot")
		}
	})

	t.Run("discovery outage refuses to boot", func(t *testing.T) {
		idp := newStubIdP(t, rsaJWK("k1"))
		idp.setDiscoveryDown(true)
		if _, err := NewTokenVerifier(context.Background(), VerifierConfig{
			IssuerURL:    idp.base,
			Audience:     testAudience,
			JWKSCacheTTL: time.Hour,
		}); err == nil {
			t.Fatal("unreachable discovery must abort boot")
		}
	})

	t.Run("jwks override skips discovery", func(t *testing.T) {
		// Discovery is down on purpose: constructing the verifier proves the
		// pinned JWKS URL bypasses it entirely.
		idp := newStubIdP(t, rsaJWK("k1"))
		idp.setDiscoveryDown(true)
		verifier := newTestVerifier(t, idp, func(cfg *VerifierConfig) { cfg.JWKSURL = idp.base + "/jwks" })
		if _, aerr := verifier.verify(idp.mint(nil)); aerr != nil {
			t.Fatalf("verify with pinned JWKS URL: %+v", aerr)
		}
	})

	t.Run("unusable discovery jwks_uri refuses to boot", func(t *testing.T) {
		idp := newStubIdP(t, rsaJWK("k1"))
		idp.setDiscoveryJWKSURI("ftp://keys.example/jwks")
		if _, err := NewTokenVerifier(context.Background(), VerifierConfig{
			IssuerURL:    idp.base,
			Audience:     testAudience,
			JWKSCacheTTL: time.Hour,
		}); err == nil {
			t.Fatal("discovery jwks_uri with a non-HTTP scheme must abort boot")
		}
	})
}

func TestNewTokenVerifierConfigValidation(t *testing.T) {
	tests := []struct {
		name    string
		cfg     VerifierConfig
		wantErr string
	}{
		{
			name:    "issuer url is required",
			cfg:     VerifierConfig{Audience: testAudience, JWKSCacheTTL: time.Hour},
			wantErr: "verifier requires an issuer URL",
		},
		{
			name:    "audience is required",
			cfg:     VerifierConfig{IssuerURL: "https://issuer.test", JWKSCacheTTL: time.Hour},
			wantErr: "verifier requires an audience",
		},
		{
			name:    "jwks cache ttl must be positive",
			cfg:     VerifierConfig{IssuerURL: "https://issuer.test", Audience: testAudience},
			wantErr: "verifier requires a positive JWKS cache TTL",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := NewTokenVerifier(context.Background(), tt.cfg)
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("NewTokenVerifier() error = %v, want containing %q", err, tt.wantErr)
			}
		})
	}
}

// TestVerifyWithoutKidIsRejected: kid-less tokens are refused outright —
// key selection stays explicit. An attacker cannot strip the kid to escape
// the algorithm pin, because without a kid no key is selected at all.
func TestVerifyWithoutKidIsRejected(t *testing.T) {
	idp := newStubIdP(t, rsaJWK("k1"))
	verifier := newTestVerifier(t, idp, nil)

	noKid := idp.mint(func(o *tokenOptions) { o.kid = "" })
	if _, aerr := verifier.verify(noKid); aerr == nil || aerr.reason != "token signing key is unknown" {
		t.Fatalf("verify token without kid: aerr = %+v, want unknown signing key", aerr)
	}
}
