// Package grants holds the renter venue-access grant domain of the auth
// reference: time-bounded, revocable, single-venue read grants, a storage
// interface, and an in-memory implementation. Postgres arrives in a later
// task.
//
// A grant is immutable after creation except for revocation. Whether it is
// still honored is decided at use time: Resolve compares the caller's clock
// against ExpiresAt, so an expired grant is inert even before any cleanup
// removes it from storage.
package grants

import (
	"cmp"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
)

// TTL bounds for a grant's lifetime. Creation rejects anything outside
// [MinTTL, MaxTTL]; requests that omit a TTL get DefaultTTL.
const (
	// MinTTL is the shortest lifetime a grant may have.
	MinTTL = 8 * time.Hour
	// MaxTTL is the longest lifetime a grant may have.
	MaxTTL = 24 * time.Hour
	// DefaultTTL is used when a creation request does not name a TTL.
	DefaultTTL = MinTTL
)

// Grant grants one renter read access to exactly one venue until it expires
// or is revoked. Token is the opaque bearer credential the renter presents;
// it is minted with crypto/rand and never appears in log output.
type Grant struct {
	ID        string     `json:"id"`
	VenueID   string     `json:"venueId"`
	Subject   string     `json:"subject"`
	Token     string     `json:"token"`
	ExpiresAt time.Time  `json:"expiresAt"`
	CreatedAt time.Time  `json:"createdAt"`
	RevokedAt *time.Time `json:"revokedAt,omitempty"`
}

// ActiveAt reports whether the grant is honored at the given instant: not
// revoked and not yet expired.
func (g Grant) ActiveAt(now time.Time) bool {
	return g.RevokedAt == nil && !now.After(g.ExpiresAt)
}

// Sentinel errors for grant lookup and use. Callers test with errors.Is.
var (
	// ErrNotFound reports that no grant matches the requested identifier or token.
	ErrNotFound = errors.New("grant not found")
	// ErrExpired reports that a matched grant's lifetime has passed.
	ErrExpired = errors.New("grant expired")
	// ErrRevoked reports that a matched grant was revoked.
	ErrRevoked = errors.New("grant revoked")
	// ErrInvalidTTL reports that a requested grant lifetime is outside the bounds.
	ErrInvalidTTL = errors.New("grant ttl out of bounds")
)

// Store persists grants. Implementations must be safe for concurrent use.
type Store interface {
	Create(ctx context.Context, g Grant) (Grant, error)
	Get(ctx context.Context, id string) (Grant, error)
	GetByToken(ctx context.Context, token string) (Grant, error)
	ListForVenue(ctx context.Context, venueID string) ([]Grant, error)
	// Revoke stamps the grant's RevokedAt and returns it. If the grant was
	// already revoked, the first revocation timestamp is kept.
	Revoke(ctx context.Context, id string, revokedAt time.Time) (Grant, error)
}

// MemStore is the in-memory Store backing local development and tests.
type MemStore struct {
	mu      sync.RWMutex
	grants  map[string]Grant
	byToken map[string]string
}

// NewMemStore returns an empty store. Grants are minted at runtime; there is
// no seed.
func NewMemStore() *MemStore {
	return &MemStore{
		grants:  make(map[string]Grant),
		byToken: make(map[string]string),
	}
}

// Create stores a copy of g or an error wrapping ErrNotFound if the ID or
// token is already taken.
func (s *MemStore) Create(_ context.Context, g Grant) (Grant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.grants[g.ID]; ok {
		return Grant{}, fmt.Errorf("%w: id %s", ErrNotFound, g.ID)
	}
	if _, ok := s.byToken[g.Token]; ok {
		// Deliberately name no token in the message: errors from here can
		// reach the request log, and tokens must not.
		return Grant{}, fmt.Errorf("%w: token already issued", ErrNotFound)
	}
	stored := g.clone()
	s.grants[stored.ID] = stored
	s.byToken[stored.Token] = stored.ID
	return stored.clone(), nil
}

// Get returns one grant by ID or an error wrapping ErrNotFound.
func (s *MemStore) Get(_ context.Context, id string) (Grant, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	g, ok := s.grants[id]
	if !ok {
		return Grant{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return g.clone(), nil
}

// GetByToken returns one grant by token or an error wrapping ErrNotFound.
// The error message never echoes the token.
func (s *MemStore) GetByToken(_ context.Context, token string) (Grant, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.byToken[token]
	if !ok {
		return Grant{}, fmt.Errorf("%w: token rejected", ErrNotFound)
	}
	return s.grants[id].clone(), nil
}

// ListForVenue returns every grant for the venue ordered by ID.
func (s *MemStore) ListForVenue(_ context.Context, venueID string) ([]Grant, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Grant, 0, len(s.grants))
	for _, g := range s.grants {
		if g.VenueID == venueID {
			out = append(out, g.clone())
		}
	}
	slices.SortFunc(out, func(a, b Grant) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}

// Revoke stamps revokedAt on the grant with the given ID. Revoking an
// already-revoked grant keeps the first timestamp. Unknown IDs wrap
// ErrNotFound.
func (s *MemStore) Revoke(_ context.Context, id string, revokedAt time.Time) (Grant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g, ok := s.grants[id]
	if !ok {
		return Grant{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	if g.RevokedAt == nil {
		stamped := revokedAt
		g.RevokedAt = &stamped
		s.grants[id] = g
	}
	return s.grants[id].clone(), nil
}

// clone returns a deep copy so callers can never mutate stored grants
// through the RevokedAt pointer.
func (g Grant) clone() Grant {
	if g.RevokedAt != nil {
		t := *g.RevokedAt
		g.RevokedAt = &t
	}
	return g
}

// CreateInput names what a grant is created for. TTL is validated against
// MinTTL and MaxTTL; the timestamps come from the caller's clock.
type CreateInput struct {
	VenueID string
	Subject string
	TTL     time.Duration
}

// Service applies the grant policy on top of a Store: TTL bounds at creation
// and expiry/revocation checks at use time.
type Service struct {
	store Store
}

// NewService returns a service backed by store.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// Create validates the TTL bounds, mints a fresh token, and stores the grant.
func (s *Service) Create(ctx context.Context, in CreateInput, now time.Time) (Grant, error) {
	if in.TTL < MinTTL || in.TTL > MaxTTL {
		return Grant{}, fmt.Errorf("%w: %s (want between %s and %s)", ErrInvalidTTL, in.TTL, MinTTL, MaxTTL)
	}
	id, err := newID()
	if err != nil {
		return Grant{}, err
	}
	token, err := newToken()
	if err != nil {
		return Grant{}, err
	}
	g := Grant{
		ID:        id,
		VenueID:   in.VenueID,
		Subject:   in.Subject,
		Token:     token,
		ExpiresAt: now.Add(in.TTL),
		CreatedAt: now,
	}
	return s.store.Create(ctx, g)
}

// Resolve returns the grant a token belongs to, checked at use time: an
// expired or revoked grant is an error even though the row still exists.
// Revocation takes precedence over expiry when both apply.
func (s *Service) Resolve(ctx context.Context, token string, now time.Time) (Grant, error) {
	g, err := s.store.GetByToken(ctx, token)
	if err != nil {
		return Grant{}, err
	}
	if g.RevokedAt != nil {
		return Grant{}, fmt.Errorf("%w: %s", ErrRevoked, g.ID)
	}
	if now.After(g.ExpiresAt) {
		return Grant{}, fmt.Errorf("%w: %s at %s", ErrExpired, g.ID, g.ExpiresAt.Format(time.RFC3339))
	}
	return g, nil
}

// Revoke stamps the grant's revocation and returns it.
func (s *Service) Revoke(ctx context.Context, id string, now time.Time) (Grant, error) {
	return s.store.Revoke(ctx, id, now)
}

// ListForVenue returns every grant for the venue ordered by ID.
func (s *Service) ListForVenue(ctx context.Context, venueID string) ([]Grant, error) {
	return s.store.ListForVenue(ctx, venueID)
}

// newID mints a grant identifier from crypto/rand.
func newID() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate grant id: %w", err)
	}
	return "g-" + hex.EncodeToString(b), nil
}

// newToken mints the opaque bearer credential from crypto/rand.
func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate grant token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// Principal is the authenticated actor on whose behalf a request is made.
// The server wiring bridges the OIDC guard's principal into this contract;
// grants handlers never import auth directly.
type Principal interface {
	// Subject is the stable identity of the actor, e.g. the OIDC sub claim.
	Subject() string
}

// NewPrincipal returns a Principal carrying only a subject. The server
// wiring uses it to present an OIDC principal or a resolved grant's subject
// in the request context without this package importing auth.
func NewPrincipal(subject string) Principal { return plainPrincipal{subject} }

// plainPrincipal is NewPrincipal's value type.
type plainPrincipal struct{ subject string }

// Subject implements Principal.
func (p plainPrincipal) Subject() string { return p.subject }

type principalKey struct{}

// WithPrincipal returns a context carrying the principal.
func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey{}, p)
}

// PrincipalFrom returns the request's principal or nil when the request is
// unauthenticated.
func PrincipalFrom(ctx context.Context) Principal {
	p, _ := ctx.Value(principalKey{}).(Principal)
	return p
}
