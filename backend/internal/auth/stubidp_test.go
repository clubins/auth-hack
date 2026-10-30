package auth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Test fixtures mirror the production values: the audience is the API's
// origin and the scope is config.VenueReadScope. They are re-declared here
// rather than imported so the auth package stays dependency-free of config.
const (
	testAudience = "https://api.clubins.de"
	testScope    = "https://api.clubins.de/venues:read"
)

// testRSAKey generates the test IdP's RSA keypair once per test binary.
var testRSAKey = sync.OnceValue(func() *rsa.PrivateKey {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return key
})

// testECDSAKey generates the test IdP's P-256 keypair once per test binary.
var testECDSAKey = sync.OnceValue(func() *ecdsa.PrivateKey {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	return key
})

// hmacSecret returns the public key bytes an attacker would use as an HMAC
// secret when a victim library accepts HS256 with a public key.
var hmacSecret = sync.OnceValue(func() []byte {
	der, err := x509.MarshalPKIXPublicKey(&testRSAKey().PublicKey)
	if err != nil {
		panic(err)
	}
	return der
})

// stubIdP is an in-process OIDC provider for guard tests: an issuer base
// URL, an OIDC discovery document, a JWKS endpoint whose key set tests can
// rotate or take down, and token minting under those keys. No test ever
// touches the network beyond httptest's loopback.
type stubIdP struct {
	t    *testing.T
	base string

	mu               sync.Mutex
	jwks             []map[string]string
	jwksDown         bool
	discoveryDown    bool
	discoveryIssuer  string
	discoveryJWKSURI string
}

// newStubIdP starts the stub serving the given key set.
func newStubIdP(t *testing.T, keys ...map[string]string) *stubIdP {
	t.Helper()
	idp := &stubIdP{t: t, jwks: keys}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", idp.serveDiscovery)
	mux.HandleFunc("/jwks", idp.serveJWKS)
	srv := httptest.NewServer(mux)
	idp.base = srv.URL
	t.Cleanup(srv.Close)
	return idp
}

func (idp *stubIdP) serveDiscovery(w http.ResponseWriter, _ *http.Request) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	if idp.discoveryDown {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	issuer := idp.base
	if idp.discoveryIssuer != "" {
		issuer = idp.discoveryIssuer
	}
	jwksURI := idp.base + "/jwks"
	if idp.discoveryJWKSURI != "" {
		jwksURI = idp.discoveryJWKSURI
	}
	writeTestJSON(w, map[string]string{"issuer": issuer, "jwks_uri": jwksURI})
}

func (idp *stubIdP) serveJWKS(w http.ResponseWriter, _ *http.Request) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	if idp.jwksDown {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	keys := make([]any, 0, len(idp.jwks))
	for _, k := range idp.jwks {
		keys = append(keys, k)
	}
	writeTestJSON(w, map[string]any{"keys": keys})
}

// setKeys rotates the served key set, replacing the previous one.
func (idp *stubIdP) setKeys(keys ...map[string]string) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.jwks = keys
}

// setJWKSDown toggles a JWKS endpoint outage.
func (idp *stubIdP) setJWKSDown(down bool) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.jwksDown = down
}

// setDiscoveryDown toggles a discovery endpoint outage.
func (idp *stubIdP) setDiscoveryDown(down bool) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.discoveryDown = down
}

// setDiscoveryIssuer pins a wrong issuer in the discovery document (issuer
// mix-up simulation).
func (idp *stubIdP) setDiscoveryIssuer(issuer string) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.discoveryIssuer = issuer
}

// setDiscoveryJWKSURI pins a discovery jwks_uri (e.g. an unusable scheme).
func (idp *stubIdP) setDiscoveryJWKSURI(uri string) {
	idp.mu.Lock()
	defer idp.mu.Unlock()
	idp.discoveryJWKSURI = uri
}

// tokenOptions describes one minted access token; zero-value fields fall
// back to the valid-token defaults. Tests override exactly one field at a
// time to isolate a single negative path.
type tokenOptions struct {
	alg    string
	kid    string
	issuer string
	aud    any
	sub    string
	scope  string
	// scopes emits the machine-to-machine array form, replacing "scope".
	scopes []string
	exp    time.Time
	nbf    time.Time

	omitExp   bool
	omitNbf   bool
	omitScope bool
}

// mint returns a signed access token; mutate adjusts one aspect of the
// default valid token.
func (idp *stubIdP) mint(mutate func(*tokenOptions)) string {
	idp.t.Helper()
	opts := tokenOptions{
		alg:    "RS256",
		kid:    "k1",
		issuer: idp.base,
		aud:    testAudience,
		sub:    "user-1",
		scope:  testScope,
		exp:    time.Now().Add(5 * time.Minute),
		nbf:    time.Now().Add(-time.Minute),
	}
	if mutate != nil {
		mutate(&opts)
	}

	claims := map[string]any{
		"iss": opts.issuer,
		"aud": opts.aud,
		"sub": opts.sub,
		"exp": opts.exp.Unix(),
		"nbf": opts.nbf.Unix(),
	}
	if opts.omitExp {
		delete(claims, "exp")
	}
	if opts.omitNbf {
		delete(claims, "nbf")
	}
	switch {
	case opts.scopes != nil:
		claims["scopes"] = opts.scopes
	case !opts.omitScope:
		claims["scope"] = opts.scope
	}

	header := map[string]string{"alg": opts.alg, "kid": opts.kid, "typ": "JWT"}
	signingInput := encodeSegment(idp.t, header) + "." + encodeSegment(idp.t, claims)
	switch opts.alg {
	case "RS256":
		sum := sha256.Sum256([]byte(signingInput))
		sig, err := rsa.SignPKCS1v15(rand.Reader, testRSAKey(), crypto.SHA256, sum[:])
		if err != nil {
			idp.t.Fatalf("sign RS256: %v", err)
		}
		return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	case "ES256":
		sum := sha256.Sum256([]byte(signingInput))
		r, s, err := ecdsa.Sign(rand.Reader, testECDSAKey(), sum[:])
		if err != nil {
			idp.t.Fatalf("sign ES256: %v", err)
		}
		// JWS signatures are the fixed-width r||s concatenation (RFC 7518
		// §3.4), not ASN.1 DER.
		sig := make([]byte, 64)
		r.FillBytes(sig[:32])
		s.FillBytes(sig[32:])
		return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
	case "HS256":
		mac := hmac.New(sha256.New, hmacSecret())
		mac.Write([]byte(signingInput))
		return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	case "none":
		// alg=none: structurally complete token, empty signature.
		return signingInput + "."
	default:
		idp.t.Fatalf("mint: unsupported alg %q", opts.alg)
		return ""
	}
}

// tamperSignature flips one character of the signature segment, keeping the
// token structurally valid.
func tamperSignature(t *testing.T, token string) string {
	t.Helper()
	i := strings.LastIndex(token, ".")
	if i < 0 {
		t.Fatal("tamperSignature: token has no signature segment")
	}
	sig := []byte(token[i+1:])
	if sig[0] == 'A' {
		sig[0] = 'B'
	} else {
		sig[0] = 'A'
	}
	return token[:i+1] + string(sig)
}

// rsaJWK is the JWKS entry for the test RSA key under kid.
func rsaJWK(kid string) map[string]string {
	pub := &testRSAKey().PublicKey
	return map[string]string{
		"kty": "RSA",
		"kid": kid,
		"alg": "RS256",
		"use": "sig",
		"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
	}
}

// ecdsaJWK is the JWKS entry for the test P-256 key under kid.
func ecdsaJWK(kid string) map[string]string {
	pub := &testECDSAKey().PublicKey
	return map[string]string{
		"kty": "EC",
		"kid": kid,
		"alg": "ES256",
		"use": "sig",
		"crv": "P-256",
		"x":   base64.RawURLEncoding.EncodeToString(pub.X.Bytes()),
		"y":   base64.RawURLEncoding.EncodeToString(pub.Y.Bytes()),
	}
}

// newTestVerifier builds a verifier against idp with the unknown-kid
// refetch cooldown disabled so rotation tests are immediate.
func newTestVerifier(t *testing.T, idp *stubIdP, mutate func(*VerifierConfig)) *TokenVerifier {
	t.Helper()
	cfg := VerifierConfig{
		IssuerURL:    idp.base,
		Audience:     testAudience,
		JWKSCacheTTL: time.Hour,
	}
	if mutate != nil {
		mutate(&cfg)
	}
	verifier, err := NewTokenVerifier(context.Background(), cfg)
	if err != nil {
		t.Fatalf("NewTokenVerifier: %v", err)
	}
	verifier.keys.refetchCooldown = 0
	return verifier
}

func encodeSegment(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal segment: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func writeTestJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	// A failed encode here means the test fixture wrote a bad body; the
	// assertion on the client side fails loudly either way.
	_ = json.NewEncoder(w).Encode(body)
}
