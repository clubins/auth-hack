package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// allowedAlgorithms is the closed set of token signing algorithms the guard
// accepts. It is pinned on the parser before any key lookup: "none" and HMAC
// algorithms are rejected outright, which rules out algorithm-confusion
// attacks such as an HS256 token keyed with a public key.
var allowedAlgorithms = []string{"RS256", "ES256"}

const (
	// clockSkew absorbs small time drift between the IdP and this host.
	clockSkew = 30 * time.Second
	// defaultHTTPTimeout bounds discovery and JWKS fetches.
	defaultHTTPTimeout = 10 * time.Second
	// maxDocumentBytes caps how much of a discovery or JWKS document is read.
	maxDocumentBytes = 1 << 20
)

// VerifierConfig configures NewTokenVerifier.
type VerifierConfig struct {
	// IssuerURL is the OIDC issuer whose access tokens are accepted.
	IssuerURL string
	// Audience is the expected "aud" claim value.
	Audience string
	// JWKSURL optionally pins the signing-key location, skipping OIDC
	// discovery.
	JWKSURL string
	// JWKSCacheTTL bounds how long signing keys stay fresh. Required and
	// positive: config applies DefaultJWKSCacheTTL when the env omits it.
	JWKSCacheTTL time.Duration
	// HTTPClient fetches discovery and JWKS documents; nil uses a client
	// with a 10s timeout.
	HTTPClient *http.Client
}

// TokenVerifier validates access tokens against the issuer's signing keys.
type TokenVerifier struct {
	issuer string
	// audience is the expected "aud" claim; not a secret.
	audience string
	keys     *jwksCache
	parser   *jwt.Parser
}

// NewTokenVerifier builds a verifier. It discovers the issuer's JWKS
// location (unless cfg.JWKSURL overrides it), fetches the initial key set,
// and pins the accepted algorithms. It fails closed: construction errors
// mean the API should not boot.
func NewTokenVerifier(ctx context.Context, cfg VerifierConfig) (*TokenVerifier, error) {
	if cfg.IssuerURL == "" {
		return nil, errors.New("auth: verifier requires an issuer URL")
	}
	if cfg.Audience == "" {
		return nil, errors.New("auth: verifier requires an audience")
	}
	if cfg.JWKSCacheTTL <= 0 {
		return nil, errors.New("auth: verifier requires a positive JWKS cache TTL")
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: defaultHTTPTimeout}
	}

	jwksURL := cfg.JWKSURL
	if jwksURL == "" {
		discovered, err := discoverJWKSURL(ctx, client, cfg.IssuerURL)
		if err != nil {
			return nil, err
		}
		jwksURL = discovered
	}

	keys, err := newJWKSCache(jwksCacheConfig{
		URL:    jwksURL,
		Client: client,
		TTL:    cfg.JWKSCacheTTL,
	})
	if err != nil {
		return nil, err
	}

	parser := jwt.NewParser(
		jwt.WithValidMethods(allowedAlgorithms),
		jwt.WithIssuer(cfg.IssuerURL),
		jwt.WithAudience(cfg.Audience),
		jwt.WithExpirationRequired(),
		jwt.WithLeeway(clockSkew),
	)

	return &TokenVerifier{
		issuer:   cfg.IssuerURL,
		audience: cfg.Audience,
		keys:     keys,
		parser:   parser,
	}, nil
}

// tokenClaims is the access-token claim set the guard consumes. Logto puts
// scopes in "scope" (space-delimited, RFC 8693) for user access tokens and
// in "scopes" (array) for machine-to-machine tokens; both are accepted.
type tokenClaims struct {
	jwt.RegisteredClaims
	Scope  string   `json:"scope,omitempty"`
	Scopes []string `json:"scopes,omitempty"`
}

// scopeList returns the granted scopes as individual values.
func (c *tokenClaims) scopeList() []string {
	scopes := make([]string, 0, len(c.Scopes)+2)
	scopes = append(scopes, c.Scopes...)
	scopes = append(scopes, strings.Fields(c.Scope)...)
	return scopes
}

// verify parses and validates raw against the pinned algorithms and the
// issuer's keys, returning the Principal the guard injects into the request
// context.
func (v *TokenVerifier) verify(raw string) (Principal, *authError) {
	claims := &tokenClaims{}
	if _, err := v.parser.ParseWithClaims(raw, claims, v.keys.keyfunc); err != nil {
		return Principal{}, classifyTokenError(err)
	}
	return Principal{Subject: claims.Subject, Scopes: claims.scopeList()}, nil
}

// classifyTokenError maps a token-parsing error to a fixed, token-free
// rejection. The package's own sentinels (which survive the parser's error
// joining) are checked before the generic unverifiable class so unknown
// keys and key-fetch outages surface distinctly.
func classifyTokenError(err error) *authError {
	switch {
	case errors.Is(err, errKeysUnavailable):
		return unavailable(err)
	case errors.Is(err, errUnknownSigningKey):
		return invalidToken("token signing key is unknown")
	case errors.Is(err, jwt.ErrTokenMalformed):
		return invalidToken("token is malformed")
	case errors.Is(err, jwt.ErrTokenExpired):
		return invalidToken("token is expired")
	case errors.Is(err, jwt.ErrTokenNotValidYet):
		return invalidToken("token is not valid yet")
	case errors.Is(err, jwt.ErrTokenInvalidIssuer):
		return invalidToken("token issuer mismatch")
	case errors.Is(err, jwt.ErrTokenInvalidAudience):
		return invalidToken("token audience mismatch")
	case errors.Is(err, jwt.ErrTokenRequiredClaimMissing):
		return invalidToken("token is missing a required claim")
	case errors.Is(err, jwt.ErrTokenSignatureInvalid):
		// Covers both broken signatures and algorithms outside the pinned
		// set; the parser rejects the latter before key lookup.
		return invalidToken("token signature is invalid")
	default:
		return invalidToken("token is invalid")
	}
}

// discoveryDocument is the subset of the OIDC discovery document the guard
// consumes.
type discoveryDocument struct {
	Issuer  string `json:"issuer"`
	JWKSURI string `json:"jwks_uri"`
}

// discoverJWKSURL fetches the issuer's OIDC discovery document and returns
// its JWKS location. The document's issuer must match the configured issuer
// exactly: a mismatch means the URL serves a different identity provider
// (issuer mix-up) and the guard refuses to boot.
func discoverJWKSURL(ctx context.Context, client *http.Client, issuerURL string) (string, error) {
	endpoint := strings.TrimSuffix(issuerURL, "/") + "/.well-known/openid-configuration"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", fmt.Errorf("auth: discovery request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("auth: fetch %s: %w", endpoint, err)
	}
	defer func() { _ = resp.Body.Close() }() // read-only fetch; a close error cannot change the outcome
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("auth: fetch %s: unexpected status %d", endpoint, resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxDocumentBytes))
	if err != nil {
		return "", fmt.Errorf("auth: read discovery document: %w", err)
	}
	var doc discoveryDocument
	if err := json.Unmarshal(raw, &doc); err != nil {
		return "", fmt.Errorf("auth: decode discovery document: %w", err)
	}
	if doc.Issuer != issuerURL {
		return "", fmt.Errorf("auth: discovery issuer mismatch: got %q, want %q", doc.Issuer, issuerURL)
	}
	if !isHTTPURL(doc.JWKSURI) {
		return "", fmt.Errorf("auth: discovery document has no usable jwks_uri: %q", doc.JWKSURI)
	}
	return doc.JWKSURI, nil
}

// isHTTPURL reports whether raw is an http(s) URL with a host.
func isHTTPURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}
