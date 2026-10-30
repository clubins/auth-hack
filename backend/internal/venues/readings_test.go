package venues

import (
	"context"
	"encoding/json"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestReadingsMemStoreListForVenue(t *testing.T) {
	store := NewReadingsMemStore(DefaultReadingsSeed())

	for _, venueID := range []string{"v-001", "v-002", "v-003"} {
		t.Run(venueID, func(t *testing.T) {
			got, err := store.ListForVenue(context.Background(), venueID)
			if err != nil {
				t.Fatalf("ListForVenue(%q): %v", venueID, err)
			}
			if want := seedVenueReadings(venueID); !reflect.DeepEqual(normalize(t, got), normalize(t, want)) {
				t.Fatalf("ListForVenue(%q) = %+v, want %+v", venueID, got, want)
			}
			for i := 1; i < len(got); i++ {
				if !got[i-1].MeasuredAt.Before(got[i].MeasuredAt) {
					t.Fatalf("readings not oldest first: %v before %v", got[i-1].MeasuredAt, got[i].MeasuredAt)
				}
			}
		})
	}

	t.Run("unknown venue lists as empty slice", func(t *testing.T) {
		got, err := store.ListForVenue(context.Background(), "nope")
		if err != nil {
			t.Fatalf("ListForVenue: %v", err)
		}
		if got == nil || len(got) != 0 {
			t.Fatalf("ListForVenue(unknown) = %#v, want non-nil empty slice", got)
		}
	})
}

func TestReadingsMemStoreOrdersByMeasuredAt(t *testing.T) {
	ten := time.Date(2026, 10, 30, 10, 0, 0, 0, time.UTC)
	store := NewReadingsMemStore([]Reading{
		{ID: "r-late", VenueID: "v-001", MeasuredAt: ten.Add(time.Hour)},
		{ID: "r-early-b", VenueID: "v-001", MeasuredAt: ten},
		{ID: "r-early-a", VenueID: "v-001", MeasuredAt: ten},
		{ID: "r-other", VenueID: "v-002", MeasuredAt: ten},
	})

	got, err := store.ListForVenue(context.Background(), "v-001")
	if err != nil {
		t.Fatalf("ListForVenue: %v", err)
	}
	want := []string{"r-early-a", "r-early-b", "r-late"}
	if len(got) != len(want) {
		t.Fatalf("listed %d readings, want %d", len(got), len(want))
	}
	for i, id := range want {
		if got[i].ID != id {
			t.Fatalf("position %d = %q, want %q", i, got[i].ID, id)
		}
	}
}

func TestReadingsMemStoreSeedCopied(t *testing.T) {
	seed := []Reading{{ID: "r-1", VenueID: "v-1", MeasuredAt: time.Now(), TemperatureC: 1}}
	store := NewReadingsMemStore(seed)

	seed[0].TemperatureC = 999

	got, err := store.ListForVenue(context.Background(), "v-1")
	if err != nil {
		t.Fatalf("ListForVenue: %v", err)
	}
	if got[0].TemperatureC != 1 {
		t.Fatalf("store aliased the seed: temperature = %v, want 1", got[0].TemperatureC)
	}
}

func TestReadingsMemStoreConcurrentReads(t *testing.T) {
	store := NewReadingsMemStore(DefaultReadingsSeed())

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				if _, err := store.ListForVenue(context.Background(), "v-001"); err != nil {
					t.Errorf("ListForVenue: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
}

// TestReadingWireContract pins the readings payload to the Flutter client's
// contract: exactly id, measuredAt, temperatureC — lowerCamelCase, nothing
// else — with measuredAt an RFC3339 timestamp and temperatureC a number.
func TestReadingWireContract(t *testing.T) {
	b, err := json.Marshal(DefaultReadingsSeed()[0])
	if err != nil {
		t.Fatalf("marshal reading: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal reading: %v", err)
	}

	want := map[string]any{"id": "r-001", "measuredAt": "2026-10-30T10:00:00Z", "temperatureC": 18.5}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("reading JSON = %v, want %v (the payload must stay exactly the Flutter client's contract)", got, want)
	}

	measuredAt, ok := got["measuredAt"].(string)
	if !ok {
		t.Fatalf("measuredAt = %v, want an RFC3339 string", got["measuredAt"])
	}
	if _, err := time.Parse(time.RFC3339, measuredAt); err != nil {
		t.Fatalf("measuredAt %q is not RFC3339: %v", measuredAt, err)
	}
}
