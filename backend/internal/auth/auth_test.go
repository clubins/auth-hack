package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestGuardNegativePaths walks every rejection path through a live Guard
// chained over RequireScope, and asserts the exact RFC 6750 challenge and
// the venues-style JSON body. Positive rows additionally assert the
// Principal the guard injected into the request context.
func TestGuardNegativePaths(t *testing.T) {
	idp := newStubIdP(t, rsaJWK("k1"), ecdsaJWK("ec1"))
	verifier := newTestVerifier(t, idp, nil)
	guard, err := NewGuard(GuardOptions{Verifier: verifier})
	if err != nil {
		t.Fatalf("NewGuard: %v", err)
	}

	target := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := PrincipalFromContext(r.Context())
		if !ok {
			t.Error("target reached without a principal")
			writeTestJSON(w, map[string]any{"error": "no principal"})
			return
		}
		writeTestJSON(w, map[string]any{"sub": p.Subject, "scopes": p.Scopes})
	})
	srv := httptest.NewServer(guard.Wrap(RequireScope(testScope, target)))
	t.Cleanup(srv.Close)

	invalidTokenChallenge := func(description string) string {
		return `Bearer error="invalid_token", error_description="` + description + `"`
	}

	tests := []struct {
		name          string
		authorization func() string // full header value; "" omits the header
		wantStatus    int
		wantChallenge string // exact WWW-Authenticate value
		wantBody      string // {"error": wantBody}
		wantSub       string // asserted on 200 rows
	}{
		{
			name:          "missing authorization header",
			authorization: func() string { return "" },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: "Bearer",
			wantBody:      "unauthorized",
		},
		{
			name:          "bearer without token",
			authorization: func() string { return "Bearer" },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: `Bearer error="invalid_request", error_description="malformed authorization header"`,
			wantBody:      "unauthorized",
		},
		{
			name:          "two credentials in one header",
			authorization: func() string { return "Bearer aaa.bbb.ccc ddd.eee.fff" },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: `Bearer error="invalid_request", error_description="malformed authorization header"`,
			wantBody:      "unauthorized",
		},
		{
			name:          "non-bearer scheme",
			authorization: func() string { return "Basic dXNlcjpwYXNz" },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: `Bearer error="invalid_request", error_description="bearer authorization required"`,
			wantBody:      "unauthorized",
		},
		{
			name:          "garbage token",
			authorization: func() string { return "Bearer not-a-jwt" },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token is malformed"),
			wantBody:      "unauthorized",
		},
		{
			name: "expired token",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.exp = o.exp.Add(-10 * time.Minute) })
			},
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token is expired"),
			wantBody:      "unauthorized",
		},
		{
			name: "token not yet valid",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.nbf = o.nbf.Add(10 * time.Minute) })
			},
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token is not valid yet"),
			wantBody:      "unauthorized",
		},
		{
			name: "wrong issuer",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.issuer = "https://evil.example" })
			},
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token issuer mismatch"),
			wantBody:      "unauthorized",
		},
		{
			name:          "wrong audience",
			authorization: func() string { return "Bearer " + idp.mint(func(o *tokenOptions) { o.aud = "https://other.api" }) },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token audience mismatch"),
			wantBody:      "unauthorized",
		},
		{
			name:          "unsigned none-alg token",
			authorization: func() string { return "Bearer " + idp.mint(func(o *tokenOptions) { o.alg = "none" }) },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token signature is invalid"),
			wantBody:      "unauthorized",
		},
		{
			name:          "hs256 token signed with the public key",
			authorization: func() string { return "Bearer " + idp.mint(func(o *tokenOptions) { o.alg = "HS256" }) },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token signature is invalid"),
			wantBody:      "unauthorized",
		},
		{
			name:          "tampered signature",
			authorization: func() string { return "Bearer " + tamperSignature(t, idp.mint(nil)) },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token signature is invalid"),
			wantBody:      "unauthorized",
		},
		{
			name:          "unknown kid",
			authorization: func() string { return "Bearer " + idp.mint(func(o *tokenOptions) { o.kid = "ghost" }) },
			wantStatus:    http.StatusUnauthorized,
			wantChallenge: invalidTokenChallenge("token signing key is unknown"),
			wantBody:      "unauthorized",
		},
		{
			name:          "valid token without the required scope",
			authorization: func() string { return "Bearer " + idp.mint(func(o *tokenOptions) { o.omitScope = true }) },
			wantStatus:    http.StatusForbidden,
			wantChallenge: `Bearer error="insufficient_scope", scope="` + testScope + `", error_description="the request requires scope ` + testScope + `"`,
			wantBody:      "forbidden",
		},
		{
			name: "valid token with an unrelated scope",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.scope = "https://api.clubins.de/other:scope" })
			},
			wantStatus:    http.StatusForbidden,
			wantChallenge: `Bearer error="insufficient_scope", scope="` + testScope + `", error_description="the request requires scope ` + testScope + `"`,
			wantBody:      "forbidden",
		},
		{
			name:          "valid token end to end",
			authorization: func() string { return "Bearer " + idp.mint(nil) },
			wantStatus:    http.StatusOK,
			wantSub:       "user-1",
		},
		{
			name: "valid ES256 token",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.alg = "ES256"; o.kid = "ec1"; o.sub = "ec-user" })
			},
			wantStatus: http.StatusOK,
			wantSub:    "ec-user",
		},
		{
			name: "valid token with the m2m scopes array",
			authorization: func() string {
				return "Bearer " + idp.mint(func(o *tokenOptions) { o.scopes = []string{testScope, "other:scope"} })
			},
			wantStatus: http.StatusOK,
			wantSub:    "user-1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, srv.URL, nil)
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
			if got := resp.Header.Get("WWW-Authenticate"); got != tt.wantChallenge {
				t.Fatalf("WWW-Authenticate = %q, want %q", got, tt.wantChallenge)
			}
			if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
				t.Fatalf("Content-Type = %q, want application/json", got)
			}

			var body struct {
				Error  string   `json:"error"`
				Sub    string   `json:"sub"`
				Scopes []string `json:"scopes"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
				t.Fatalf("decode body: %v", err)
			}
			if body.Error != tt.wantBody {
				t.Fatalf("error field = %q, want %q", body.Error, tt.wantBody)
			}
			if tt.wantSub != "" {
				if body.Sub != tt.wantSub {
					t.Fatalf("principal subject = %q, want %q", body.Sub, tt.wantSub)
				}
				if !slices.Contains(body.Scopes, testScope) {
					t.Fatalf("principal scopes = %v, want containing %q", body.Scopes, testScope)
				}
			}
		})
	}
}

func TestScopeList(t *testing.T) {
	tests := []struct {
		name   string
		claims tokenClaims
		want   []string
	}{
		{
			name:   "space-delimited scope claim",
			claims: tokenClaims{Scope: "venues:read grants:read"},
			want:   []string{"venues:read", "grants:read"},
		},
		{
			name:   "array scopes claim",
			claims: tokenClaims{Scopes: []string{"venues:read"}},
			want:   []string{"venues:read"},
		},
		{
			name:   "both forms combine",
			claims: tokenClaims{Scope: "a", Scopes: []string{"c"}},
			want:   []string{"c", "a"},
		},
		{
			name:   "no scopes at all",
			claims: tokenClaims{},
			want:   []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.claims.scopeList()
			if !slices.Equal(got, tt.want) {
				t.Fatalf("scopeList() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestHasScope(t *testing.T) {
	p := Principal{Subject: "user-1", Scopes: []string{testScope}}
	if !p.HasScope(testScope) {
		t.Fatal("HasScope should be true for a granted scope")
	}
	if p.HasScope("https://api.clubins.de/other:scope") {
		t.Fatal("HasScope should be false for an ungranted scope")
	}
}

func TestPrincipalFromContextWithoutGuard(t *testing.T) {
	if _, ok := PrincipalFromContext(context.Background()); ok {
		t.Fatal("a context that never passed the guard must not carry a principal")
	}
}

// TestVerifierConcurrentVerify exercises the cache under concurrent
// verification, including unknown kids that trigger refetches; run under
// the race detector it catches unsynchronized cache access.
func TestVerifierConcurrentVerify(t *testing.T) {
	idp := newStubIdP(t, rsaJWK("k1"), ecdsaJWK("ec1"))
	verifier := newTestVerifier(t, idp, nil)
	valid := idp.mint(nil)
	ghost := idp.mint(func(o *tokenOptions) { o.kid = "ghost" })

	var wg sync.WaitGroup
	for i := range 8 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			token := valid
			if i%2 == 0 {
				token = ghost // both outcomes exercised
			}
			_, _ = verifier.verify(token)
		}(i)
	}
	wg.Wait()
}
