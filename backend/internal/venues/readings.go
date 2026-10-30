package venues

import (
	"cmp"
	"context"
	"slices"
	"sync"
	"time"
)

// Reading is one temperature sample taken at a venue. VenueID names the
// venue the sample belongs to but stays out of the JSON payload: readings
// are served under /venues/{id}/readings, so the path already identifies
// the venue, and the wire shape is pinned by the Flutter client's contract
// (id, measuredAt, temperatureC — nothing else).
type Reading struct {
	ID           string    `json:"id"`
	VenueID      string    `json:"-"`
	MeasuredAt   time.Time `json:"measuredAt"`
	TemperatureC float64   `json:"temperatureC"`
}

// ReadingsStore persists readings. Implementations must be safe for
// concurrent use.
type ReadingsStore interface {
	// ListForVenue returns the venue's readings ordered oldest first.
	ListForVenue(ctx context.Context, venueID string) ([]Reading, error)
}

// ReadingsMemStore is the in-memory ReadingsStore backing local development
// and tests.
type ReadingsMemStore struct {
	mu       sync.RWMutex
	readings map[string][]Reading
}

// NewReadingsMemStore returns a store seeded with copies of seed, grouped by
// venue (nil seeds empty).
func NewReadingsMemStore(seed []Reading) *ReadingsMemStore {
	readings := make(map[string][]Reading)
	for _, r := range seed {
		readings[r.VenueID] = append(readings[r.VenueID], r)
	}
	return &ReadingsMemStore{readings: readings}
}

// ListForVenue returns the venue's readings ordered oldest first, ID
// breaking ties. Unknown venues list as empty — whether a venue exists is
// the venues Store's question, not the readings store's.
func (s *ReadingsMemStore) ListForVenue(_ context.Context, venueID string) ([]Reading, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := orderedReadings(s.readings[venueID])
	if out == nil {
		out = []Reading{}
	}
	return out, nil
}

// orderedReadings returns a copy of rs ordered oldest first, ID breaking
// ties, so a readings list is a stable time series however the seed or a
// later writer interleaved the samples.
func orderedReadings(rs []Reading) []Reading {
	out := slices.Clone(rs)
	slices.SortFunc(out, func(a, b Reading) int {
		if c := a.MeasuredAt.Compare(b.MeasuredAt); c != 0 {
			return c
		}
		return cmp.Compare(a.ID, b.ID)
	})
	return out
}

// DefaultReadingsSeed is the representative reading set local development
// boots with: a few samples per seed venue at fixed UTC instants, so the
// demo stack returns deterministic data. The values are clearly fictional
// placeholders, not real venues' data.
func DefaultReadingsSeed() []Reading {
	at := func(hour int) time.Time {
		return time.Date(2026, 10, 30, hour, 0, 0, 0, time.UTC)
	}
	return []Reading{
		{ID: "r-001", VenueID: "v-001", MeasuredAt: at(10), TemperatureC: 18.5},
		{ID: "r-002", VenueID: "v-001", MeasuredAt: at(11), TemperatureC: 19.0},
		{ID: "r-003", VenueID: "v-001", MeasuredAt: at(12), TemperatureC: 20.5},
		{ID: "r-004", VenueID: "v-002", MeasuredAt: at(10), TemperatureC: 17.0},
		{ID: "r-005", VenueID: "v-002", MeasuredAt: at(11), TemperatureC: 17.5},
		{ID: "r-006", VenueID: "v-002", MeasuredAt: at(12), TemperatureC: 18.0},
		{ID: "r-007", VenueID: "v-003", MeasuredAt: at(10), TemperatureC: 20.0},
		{ID: "r-008", VenueID: "v-003", MeasuredAt: at(11), TemperatureC: 20.25},
		{ID: "r-009", VenueID: "v-003", MeasuredAt: at(12), TemperatureC: 21.0},
	}
}
