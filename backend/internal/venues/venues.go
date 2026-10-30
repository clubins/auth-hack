// Package venues holds the representative venues domain of the auth
// reference: venue records, a storage interface, and an in-memory
// implementation. Postgres arrives in a later task.
package venues

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
)

// Venue is a monitored Clubins location.
type Venue struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Address   string    `json:"address"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// ErrNotFound reports that no venue matches the requested identifier.
var ErrNotFound = errors.New("venue not found")

// Store persists venues. Implementations must be safe for concurrent use.
type Store interface {
	List(ctx context.Context) ([]Venue, error)
	Get(ctx context.Context, id string) (Venue, error)
}

// MemStore is the in-memory Store backing local development and tests.
type MemStore struct {
	mu     sync.RWMutex
	venues map[string]Venue
}

// NewMemStore returns a store seeded with copies of seed (nil seeds empty).
func NewMemStore(seed []Venue) *MemStore {
	venues := make(map[string]Venue, len(seed))
	for _, v := range seed {
		venues[v.ID] = v
	}
	return &MemStore{venues: venues}
}

// List returns every venue ordered by ID. The context is accepted for the
// Store contract; the in-memory backing cannot block on it.
func (s *MemStore) List(_ context.Context) ([]Venue, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Venue, 0, len(s.venues))
	for _, v := range s.venues {
		out = append(out, v)
	}
	slices.SortFunc(out, func(a, b Venue) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}

// Get returns one venue or an error wrapping ErrNotFound.
func (s *MemStore) Get(_ context.Context, id string) (Venue, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.venues[id]
	if !ok {
		return Venue{}, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return v, nil
}

// DefaultSeed is the representative venue set local development boots with.
// The names are clearly fictional placeholders, not real venues.
func DefaultSeed() []Venue {
	ts := time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)
	return []Venue{
		{ID: "v-001", Name: "Beispielhalle Nord", Address: "Nordstraße 1, 10115 Berlin", CreatedAt: ts, UpdatedAt: ts},
		{ID: "v-002", Name: "Musterkulturhaus", Address: "Musterweg 12, 20095 Hamburg", CreatedAt: ts, UpdatedAt: ts},
		{ID: "v-003", Name: "Demo-Konzertsaal", Address: "Beispielplatz 3, 80331 München", CreatedAt: ts, UpdatedAt: ts},
	}
}
