package venues

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"
)

// normalize round-trips want through JSON so comparisons match what a
// client actually receives (time.Time loses its monotonic clock on decode).
func normalize(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

func TestMemStoreGet(t *testing.T) {
	store := NewMemStore(DefaultSeed())

	for _, want := range DefaultSeed() {
		t.Run(want.ID, func(t *testing.T) {
			got, err := store.Get(context.Background(), want.ID)
			if err != nil {
				t.Fatalf("Get(%q): %v", want.ID, err)
			}
			if !reflect.DeepEqual(normalize(t, got), normalize(t, want)) {
				t.Fatalf("Get(%q) = %+v, want %+v", want.ID, got, want)
			}
		})
	}
}

func TestMemStoreGetUnknown(t *testing.T) {
	store := NewMemStore(DefaultSeed())

	_, err := store.Get(context.Background(), "nope")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(unknown) error = %v, want ErrNotFound", err)
	}
}

func TestMemStoreList(t *testing.T) {
	t.Run("returns seed sorted by id", func(t *testing.T) {
		store := NewMemStore(DefaultSeed())

		got, err := store.List(context.Background())
		if err != nil {
			t.Fatalf("List: %v", err)
		}
		if len(got) != len(DefaultSeed()) {
			t.Fatalf("List returned %d venues, want %d", len(got), len(DefaultSeed()))
		}
		for i := 1; i < len(got); i++ {
			if got[i-1].ID >= got[i].ID {
				t.Fatalf("List not sorted by id: %q before %q", got[i-1].ID, got[i].ID)
			}
		}
		if !reflect.DeepEqual(normalize(t, got), normalize(t, DefaultSeed())) {
			t.Fatalf("List = %+v, want seed", got)
		}
	})

	t.Run("empty store lists as empty slice", func(t *testing.T) {
		store := NewMemStore(nil)

		got, err := store.List(context.Background())
		if err != nil {
			t.Fatalf("List: %v", err)
		}
		if got == nil || len(got) != 0 {
			t.Fatalf("List = %#v, want non-nil empty slice", got)
		}
	})

	t.Run("seed input is copied", func(t *testing.T) {
		seed := []Venue{{ID: "v-1", Name: "before", CreatedAt: time.Now(), UpdatedAt: time.Now()}}
		store := NewMemStore(seed)

		seed[0].Name = "after"

		got, err := store.Get(context.Background(), "v-1")
		if err != nil {
			t.Fatalf("Get: %v", err)
		}
		if got.Name != "before" {
			t.Fatalf("store aliased the seed: venue name = %q, want %q", got.Name, "before")
		}
	})
}

func TestMemStoreConcurrentReads(t *testing.T) {
	store := NewMemStore(DefaultSeed())

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				if _, err := store.List(context.Background()); err != nil {
					t.Errorf("List: %v", err)
					return
				}
				if _, err := store.Get(context.Background(), "v-001"); err != nil {
					t.Errorf("Get: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
}
