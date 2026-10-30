package auth

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Sentinel errors the cache reports; the verifier maps them to responses.
var (
	// errUnknownSigningKey: the token's kid does not name a usable key.
	errUnknownSigningKey = errors.New("auth: token signing key is unknown")
	// errKeysUnavailable: signing keys could not be fetched.
	errKeysUnavailable = errors.New("auth: token signing keys are unavailable")
)

// defaultRefetchCooldown spaces out JWKS refetches triggered by unknown
// kids. Key rotation is honored within this window; a flood of junk kids
// cannot turn the issuer into a hot loop. TTL-expired caches always
// refetch.
const defaultRefetchCooldown = 30 * time.Second

// signingKey is one cached signing key.
type signingKey struct {
	key crypto.PublicKey
	// alg is the JWK's "alg" pin; empty means any allowed algorithm.
	alg string
}

// jwksCache caches the issuer's signing keys, refreshing proactively when
// stale and on demand when a token names an unknown kid. All methods are
// safe for concurrent use.
type jwksCache struct {
	url    string
	client *http.Client
	ttl    time.Duration
	// refetchCooldown spaces unknown-kid refetches; tests zero it to make
	// rotation immediate.
	refetchCooldown time.Duration

	mu          sync.RWMutex
	keys        map[string]signingKey
	fetchedAt   time.Time
	lastAttempt time.Time
	refetchMu   sync.Mutex // serializes JWKS fetches
}

type jwksCacheConfig struct {
	URL    string
	Client *http.Client
	TTL    time.Duration
}

// newJWKSCache builds the cache and fetches the initial key set. Failing
// here keeps a verifier without keys from ever serving requests.
func newJWKSCache(cfg jwksCacheConfig) (*jwksCache, error) {
	c := &jwksCache{
		url:             cfg.URL,
		client:          cfg.Client,
		ttl:             cfg.TTL,
		refetchCooldown: defaultRefetchCooldown,
	}
	if err := c.fetch(); err != nil {
		return nil, err
	}
	return c, nil
}

// get returns the signing key named by kid, refreshing the cache when the
// kid is unknown or the cache is stale.
func (c *jwksCache) get(kid string) (signingKey, error) {
	if k, ok := c.lookup(kid); ok {
		return k, nil
	}
	err := c.refresh(kid)
	if k, ok := c.lookup(kid); ok {
		return k, nil
	}
	if err == nil {
		// The cache is current (refreshed, or a cooldown refetch was
		// skipped) and does not name this kid.
		return signingKey{}, errUnknownSigningKey
	}
	// The refetch failed: a cached key still verifies signatures — better
	// than failing the request — so fall back to it when present.
	if k, ok := c.stale(kid); ok {
		return k, nil
	}
	return signingKey{}, err
}

// keyfunc adapts the cache to the jwt parser's Keyfunc contract.
func (c *jwksCache) keyfunc(tok *jwt.Token) (any, error) {
	kid, _ := tok.Header["kid"].(string)
	if kid == "" {
		return nil, errUnknownSigningKey
	}
	k, err := c.get(kid)
	if err != nil {
		return nil, err
	}
	if alg, _ := tok.Header["alg"].(string); k.alg != "" && k.alg != alg {
		return nil, fmt.Errorf("%w: key algorithm mismatch", errUnknownSigningKey)
	}
	return k.key, nil
}

// lookup returns a fresh cached key for kid.
func (c *jwksCache) lookup(kid string) (signingKey, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if time.Since(c.fetchedAt) >= c.ttl {
		return signingKey{}, false
	}
	k, ok := c.keys[kid]
	return k, ok
}

// stale returns a cached key for kid even past the TTL — the fallback when
// a refetch fails and the key is already known.
func (c *jwksCache) stale(kid string) (signingKey, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	k, ok := c.keys[kid]
	return k, ok
}

// refresh refetches the key set when kid is unknown or the cache is stale.
// It returns nil both after a successful fetch and after a skipped fetch
// (another request just refreshed, or the refetch cooldown holds); a
// non-nil error means the fetch was attempted and failed.
func (c *jwksCache) refresh(kid string) error {
	c.refetchMu.Lock()
	defer c.refetchMu.Unlock()

	if _, ok := c.lookup(kid); ok {
		return nil // another request's refresh already produced this key
	}
	if time.Since(c.fetchedAt) < c.ttl && time.Since(c.lastAttempt) < c.refetchCooldown {
		return nil // rate-limited; the caller falls back or reports unknown kid
	}
	return c.fetch()
}

// fetch fetches and parses the JWKS document, replacing the cached keys.
func (c *jwksCache) fetch() error {
	c.lastAttempt = time.Now()
	req, err := http.NewRequest(http.MethodGet, c.url, nil)
	if err != nil {
		return fmt.Errorf("%w: %w", errKeysUnavailable, err)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %w", errKeysUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }() // read-only fetch; a close error cannot change the outcome
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: unexpected status %d", errKeysUnavailable, resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxDocumentBytes))
	if err != nil {
		return fmt.Errorf("%w: %w", errKeysUnavailable, err)
	}
	keys, err := parseJWKS(raw)
	if err != nil {
		return fmt.Errorf("%w: %w", errKeysUnavailable, err)
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	c.keys = keys
	c.fetchedAt = time.Now()
	return nil
}

// jwk is one JSON Web Key of the fetched set; only RSA (for RS256) and EC
// (for ES256) signing keys are accepted.
type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Alg string `json:"alg,omitempty"`
	N   string `json:"n,omitempty"`
	E   string `json:"e,omitempty"`
	Crv string `json:"crv,omitempty"`
	X   string `json:"x,omitempty"`
	Y   string `json:"y,omitempty"`
}

// parseJWKS decodes a JWKS document into signing keys indexed by kid.
// Parsing is strict: an unusable entry fails the whole set rather than
// silently shrinking the trusted set.
func parseJWKS(raw []byte) (map[string]signingKey, error) {
	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("decode jwks: %w", err)
	}
	keys := make(map[string]signingKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kid == "" {
			return nil, errors.New("jwks entry without kid")
		}
		pub, err := k.publicKey()
		if err != nil {
			return nil, fmt.Errorf("jwks key %q: %w", k.Kid, err)
		}
		keys[k.Kid] = signingKey{key: pub, alg: k.Alg}
	}
	if len(keys) == 0 {
		return nil, errors.New("jwks has no keys")
	}
	return keys, nil
}

// publicKey converts the JWK to a crypto public key.
func (k jwk) publicKey() (crypto.PublicKey, error) {
	switch k.Kty {
	case "RSA":
		return k.rsaPublicKey()
	case "EC":
		return k.ecPublicKey()
	default:
		return nil, fmt.Errorf("unsupported key type %q", k.Kty)
	}
}

// rsaPublicKey decodes an RSA JWK's modulus and exponent.
func (k jwk) rsaPublicKey() (crypto.PublicKey, error) {
	if k.N == "" || k.E == "" {
		return nil, errors.New("RSA key without n or e")
	}
	n, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("RSA modulus: %w", err)
	}
	modulus := new(big.Int).SetBytes(n)
	if modulus.Sign() <= 0 {
		return nil, errors.New("RSA modulus is degenerate")
	}
	e, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("RSA exponent: %w", err)
	}
	// Valid RSA exponents are odd and at least 3; a tiny or even exponent
	// cannot be a usable public key.
	exponent := new(big.Int).SetBytes(e)
	if !exponent.IsInt64() || exponent.Int64() < 3 || exponent.Int64() > math.MaxInt32 {
		return nil, errors.New("unreasonable RSA exponent")
	}
	return &rsa.PublicKey{N: modulus, E: int(exponent.Int64())}, nil
}

// ecPublicKey decodes an EC JWK's curve and coordinates.
func (k jwk) ecPublicKey() (crypto.PublicKey, error) {
	var curve elliptic.Curve
	switch k.Crv {
	case "P-256":
		curve = elliptic.P256()
	case "P-384":
		curve = elliptic.P384()
	case "P-521":
		curve = elliptic.P521()
	default:
		return nil, fmt.Errorf("unsupported curve %q", k.Crv)
	}
	x, err := base64.RawURLEncoding.DecodeString(k.X)
	if err != nil {
		return nil, fmt.Errorf("EC x coordinate: %w", err)
	}
	y, err := base64.RawURLEncoding.DecodeString(k.Y)
	if err != nil {
		return nil, fmt.Errorf("EC y coordinate: %w", err)
	}
	if len(x) == 0 || len(y) == 0 {
		return nil, errors.New("EC key without x or y coordinates")
	}
	return &ecdsa.PublicKey{Curve: curve, X: new(big.Int).SetBytes(x), Y: new(big.Int).SetBytes(y)}, nil
}
