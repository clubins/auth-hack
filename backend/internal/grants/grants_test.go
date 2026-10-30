package grants

import (
	"context"
	"errors"
	"regexp"
	"sync"
	"testing"
	"time"
)

// base is the fixed clock every service test runs on.
var base = time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC)

type stubPrincipal struct{ sub string }

func (p stubPrincipal) Subject() string { return p.sub }

func TestServiceCreateTTLBounds(t *testing.T) {
	svc := NewService(NewMemStore())

	tests := []struct {
		name    string
		ttl     time.Duration
		wantErr bool
	}{
		{name: "just under the minimum is rejected", ttl: MinTTL - time.Minute, wantErr: true},
		{name: "7h59m is rejected", ttl: 7*time.Hour + 59*time.Minute, wantErr: true},
		{name: "exactly 8h is accepted", ttl: 8 * time.Hour},
		{name: "just under the maximum is accepted", ttl: MaxTTL - time.Minute},
		{name: "exactly 24h is accepted", ttl: 24 * time.Hour},
		{name: "24h plus 1s is rejected", ttl: 24*time.Hour + time.Second, wantErr: true},
		{name: "zero ttl is rejected", ttl: 0, wantErr: true},
		{name: "negative ttl is rejected", ttl: -8 * time.Hour, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: tt.ttl}, base)
			if tt.wantErr {
				if !errors.Is(err, ErrInvalidTTL) {
					t.Fatalf("Create(ttl=%s) error = %v, want ErrInvalidTTL", tt.ttl, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("Create(ttl=%s): %v", tt.ttl, err)
			}
			if want := base.Add(tt.ttl); !g.ExpiresAt.Equal(want) {
				t.Fatalf("ExpiresAt = %s, want %s", g.ExpiresAt, want)
			}
		})
	}
}

func TestServiceCreateWithCustomBounds(t *testing.T) {
	// Test and e2e environments prove expiry in seconds by overriding the
	// bounds (GRANT_MIN_TTL); production keeps the locked defaults.
	bounds := Bounds{Min: 2 * time.Second, Max: 5 * time.Minute, Default: 2 * time.Second}
	svc := NewServiceWithBounds(NewMemStore(), bounds)

	t.Run("the locked defaults no longer apply", func(t *testing.T) {
		if _, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: 8 * time.Hour}, base); !errors.Is(err, ErrInvalidTTL) {
			t.Fatalf("Create(8h) error = %v, want ErrInvalidTTL", err)
		}
	})

	t.Run("a ttl inside the custom window is accepted", func(t *testing.T) {
		g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: 2 * time.Second}, base)
		if err != nil {
			t.Fatalf("Create(2s): %v", err)
		}
		if want := base.Add(2 * time.Second); !g.ExpiresAt.Equal(want) {
			t.Fatalf("ExpiresAt = %s, want %s", g.ExpiresAt, want)
		}
	})

	t.Run("a zero ttl is still rejected — the handler fills the default", func(t *testing.T) {
		if _, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1"}, base); !errors.Is(err, ErrInvalidTTL) {
			t.Fatalf("Create(no ttl) error = %v, want ErrInvalidTTL", err)
		}
	})
}

func TestServiceResolveExpiry(t *testing.T) {
	svc := NewService(NewMemStore())

	g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL}, base)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	t.Run("honored just before expiry", func(t *testing.T) {
		got, err := svc.Resolve(context.Background(), g.Token, g.ExpiresAt.Add(-time.Second))
		if err != nil {
			t.Fatalf("Resolve just before expiry: %v", err)
		}
		if got.ID != g.ID {
			t.Fatalf("Resolve returned grant %q, want %q", got.ID, g.ID)
		}
	})

	t.Run("not honored at the instant after expiry", func(t *testing.T) {
		// Expiry is a strict comparison: now == ExpiresAt is still honored,
		// one nanosecond later is not.
		if _, err := svc.Resolve(context.Background(), g.Token, g.ExpiresAt); err != nil {
			t.Fatalf("Resolve at expiry: %v", err)
		}
		if _, err := svc.Resolve(context.Background(), g.Token, g.ExpiresAt.Add(time.Nanosecond)); !errors.Is(err, ErrExpired) {
			t.Fatalf("Resolve after expiry error = %v, want ErrExpired", err)
		}
	})

	t.Run("unknown token is not found", func(t *testing.T) {
		if _, err := svc.Resolve(context.Background(), "nope", base); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Resolve(unknown) error = %v, want ErrNotFound", err)
		}
	})
}

func TestServiceResolveRevocation(t *testing.T) {
	svc := NewService(NewMemStore())

	g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MaxTTL}, base)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := svc.Resolve(context.Background(), g.Token, base); err != nil {
		t.Fatalf("Resolve before revoke: %v", err)
	}

	revokedAt := base.Add(time.Hour)
	got, err := svc.Revoke(context.Background(), g.ID, revokedAt)
	if err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	if got.RevokedAt == nil || !got.RevokedAt.Equal(revokedAt) {
		t.Fatalf("Revoke stamped %v, want %s", got.RevokedAt, revokedAt)
	}

	t.Run("revoked grant is not honored", func(t *testing.T) {
		if _, err := svc.Resolve(context.Background(), g.Token, base.Add(time.Minute)); !errors.Is(err, ErrRevoked) {
			t.Fatalf("Resolve(revoked) error = %v, want ErrRevoked", err)
		}
	})

	t.Run("revocation takes precedence over expiry", func(t *testing.T) {
		if _, err := svc.Resolve(context.Background(), g.Token, g.ExpiresAt.Add(time.Hour)); !errors.Is(err, ErrRevoked) {
			t.Fatalf("Resolve(revoked and expired) error = %v, want ErrRevoked", err)
		}
	})

	t.Run("second revoke keeps the first timestamp", func(t *testing.T) {
		later := revokedAt.Add(time.Hour)
		got2, err := svc.Revoke(context.Background(), g.ID, later)
		if err != nil {
			t.Fatalf("Revoke again: %v", err)
		}
		if !got2.RevokedAt.Equal(revokedAt) {
			t.Fatalf("second Revoke stamped %s, want the first %s", got2.RevokedAt, revokedAt)
		}
	})

	t.Run("unknown grant id is not found", func(t *testing.T) {
		if _, err := svc.Revoke(context.Background(), "nope", base); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Revoke(unknown) error = %v, want ErrNotFound", err)
		}
	})
}

func TestCreateMintsUniqueTokensAndIDs(t *testing.T) {
	svc := NewService(NewMemStore())

	const n = 500
	tokens := make(map[string]bool, n)
	ids := make(map[string]bool, n)
	for i := 0; i < n; i++ {
		g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL}, base)
		if err != nil {
			t.Fatalf("Create #%d: %v", i, err)
		}
		if tokens[g.Token] {
			t.Fatalf("token #%d collides with an earlier token", i)
		}
		if ids[g.ID] {
			t.Fatalf("id #%d collides with an earlier id", i)
		}
		tokens[g.Token] = true
		ids[g.ID] = true
		if len(g.Token) != 64 {
			t.Fatalf("token #%d is %d hex chars, want 64 (32 crypto/rand bytes)", i, len(g.Token))
		}
		if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(g.Token) {
			t.Fatalf("token #%d is not lowercase hex: %q", i, g.Token)
		}
		if want := len("g-") + 16; len(g.ID) != want {
			t.Fatalf("id #%d is %d chars, want %d", i, len(g.ID), want)
		}
	}
}

func TestListForVenueScopesByVenue(t *testing.T) {
	svc := NewService(NewMemStore())
	// Two grants for venue A, one for venue B.
	for _, in := range []CreateInput{
		{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL},
		{VenueID: "v-001", Subject: "renter-2", TTL: MaxTTL},
		{VenueID: "v-002", Subject: "renter-1", TTL: MinTTL},
	} {
		if _, err := svc.Create(context.Background(), in, base); err != nil {
			t.Fatalf("Create(%+v): %v", in, err)
		}
	}

	got, err := svc.ListForVenue(context.Background(), "v-001")
	if err != nil {
		t.Fatalf("ListForVenue: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListForVenue(v-001) returned %d grants, want 2", len(got))
	}
	for _, g := range got {
		if g.VenueID != "v-001" {
			t.Fatalf("ListForVenue(v-001) leaked a grant for %q", g.VenueID)
		}
	}

	empty, err := svc.ListForVenue(context.Background(), "v-003")
	if err != nil {
		t.Fatalf("ListForVenue: %v", err)
	}
	if empty == nil || len(empty) != 0 {
		t.Fatalf("ListForVenue(v-003) = %#v, want non-nil empty slice", empty)
	}
}

func TestMemStoreReturnedGrantsAreCopies(t *testing.T) {
	svc := NewService(NewMemStore())
	g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL}, base)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Mutating a returned grant through its RevokedAt pointer must not touch
	// the stored grant (immutability except revocation).
	forged := base.Add(2 * time.Hour)
	g.RevokedAt = &forged

	stored, err := svc.Resolve(context.Background(), g.Token, base)
	if err != nil {
		t.Fatalf("Resolve after caller mutation: %v", err)
	}
	if stored.RevokedAt != nil {
		t.Fatalf("store aliased the caller's copy: RevokedAt = %v, want nil", stored.RevokedAt)
	}
}

func TestConcurrentCreateAndResolve(t *testing.T) {
	svc := NewService(NewMemStore())

	const goroutines, creates = 16, 25
	var wg sync.WaitGroup
	errs := make(chan error, goroutines)

	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < creates; j++ {
				g, err := svc.Create(context.Background(), CreateInput{VenueID: "v-001", Subject: "renter-1", TTL: MinTTL}, base)
				if err != nil {
					errs <- err
					return
				}
				if _, err := svc.Resolve(context.Background(), g.Token, base); err != nil {
					errs <- err
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent create/resolve: %v", err)
	}
}
